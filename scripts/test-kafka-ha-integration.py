#!/usr/bin/env python3
"""Disposable Docker Kafka migration canary; never connects to Kubernetes."""
import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import time

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("kafka_ha", ROOT / "scripts/configure-kafka-ha.py")
HA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HA)
CLUSTER_ID = "8ipNY9RxQtWkattTais5yQ"


class Canary:
    def __init__(self, directory):
        self.directory = Path(directory).absolute()
        HA.require(not self.directory.exists(), "Use a new private output directory")
        self.directory.mkdir(mode=0o700, parents=True)
        self.network = "bm-kafka-ha-test-" + str(os.getpid())
        self.names = {}
        self.volumes = set()
        self.resources = {}
        self.results = {}
        self.log = (self.directory / "commands.log").open("wb")
        base = ["helm", "template", "bm-cluster", str(ROOT / "k8s"), "--set",
                "publicDomain=example.com,internalDnsZone=internal.example.com,gitopsRepositoryURL=https://example.com/repo.git,cloudflareAccessTeamName=example"]
        for phase in ["legacy", "dynamic", "expanded", "active"]:
            args = [] if phase == "legacy" else ["--set", f"kafkaHa.enabled=true,kafkaHa.phase={phase},kafkaHa.clusterId={CLUSTER_ID},kafkaHa.bootstrap=false"]
            docs = yaml.safe_load_all(self.run(base + args).stdout)
            self.resources[phase] = {d["metadata"]["name"]: d for d in docs if d and d["kind"] == "StatefulSet" and d["metadata"]["name"] in {"kafka", "kafka-controller"}}

    def run(self, args, data=None, check=True, timeout=100):
        result = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
        self.log.write(result.stdout + result.stderr)
        self.log.flush()
        if check:
            HA.require(result.returncode == 0, "Disposable command failed; inspect " + str(self.directory / "commands.log"))
        return result

    def start(self, role, ordinal, phase):
        pod = f"{role}-{ordinal}"
        name = self.network + "-" + pod
        self.names[(role, ordinal)] = name
        volume = name + "-data"
        if volume not in self.volumes:
            self.run(["docker", "volume", "create", volume])
            self.volumes.add(volume)
        container = self.resources[phase][role]["spec"]["template"]["spec"]["containers"][0]
        env = {item["name"]: item.get("value", pod if item["name"] == "POD_NAME" else "infra") for item in container["env"]}
        # Bounded fixture-only sizing; production uses the rendered JVM budgets.
        env.update(KAFKA_HEAP_OPTS="-Xms32m -Xmx128m", KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS="3",
                   KAFKA_LOG_RETENTION_HOURS="1", KAFKA_LOG_CLEANER_DEDUPE_BUFFER_SIZE="8388608", LOG_DIR="/tmp/kafka-runtime")
        args = ["docker", "run", "-d", "--name", name, "--network", self.network, "--user", "1000:1000",
                "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--memory", "768m", "--cpus", "0.5",
                "--tmpfs", "/tmp:rw,nosuid,nodev,size=128m,uid=1000,gid=1000",
                "--tmpfs", "/etc/kafka:rw,nosuid,nodev,size=64m,uid=1000,gid=1000",
                "-v", volume + ":/var/lib/kafka/data", "-v", str(ROOT / "k8s/ha") + ":/opt/bm-cluster:ro"]
        for alias in [f"{pod}.{role}.infra.svc.cluster.local", f"{pod}.{role}.internal.example.com"] + (
                ["kafka.infra.svc.cluster.local", "kafka.internal.example.com"] if role == "kafka" else []):
            args += ["--network-alias", alias]
        for key, value in env.items():
            args += ["-e", key + "=" + value]
        command = container.get("command", [])
        if command:
            args += ["--entrypoint", command[0]]
        self.run([*args, container["image"], *command[1:], *container.get("args", [])])

    def stop(self, role, ordinal):
        name = self.names[(role, ordinal)]
        self.run(["docker", "stop", "--timeout", "30", name])
        self.run(["docker", "rm", "-v", name])

    def tool(self, role, ordinal, command, data=None, check=True):
        return self.run(["docker", "exec", "-i", "-e", "KAFKA_HEAP_OPTS=-Xms32m -Xmx128m", self.names[(role, ordinal)], *command], data, check)

    def wait(self, role, ordinal, command, predicate=lambda r: r.returncode == 0):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            result = self.tool(role, ordinal, command, check=False)
            if predicate(result):
                return result
            time.sleep(2)
        raise RuntimeError("Disposable Kafka readiness failed: " + command[0])

    def test(self):
        broker = ["--bootstrap-server", "kafka.infra.svc.cluster.local:9092"]
        self.run(["docker", "network", "create", "--internal", self.network])
        # Refusal runs against empty fixture storage before any cluster exists.
        self.start("kafka-controller", 0, "dynamic")
        result = self.run(["docker", "wait", self.names[("kafka-controller", 0)]])
        HA.require(result.stdout.strip() == b"1", "Unformatted original controller unexpectedly started")
        result = self.run(["docker", "logs", self.names[("kafka-controller", 0)]])
        logs = result.stdout + result.stderr
        HA.require(b"Original Kafka PVC is unformatted" in logs, "Expected explicit original-storage refusal")
        self.run(["docker", "rm", "-v", self.names[("kafka-controller", 0)]])
        self.results["refusedEmptyOriginalStorage"] = True
        self.start("kafka-controller", 0, "legacy")
        self.start("kafka", 0, "legacy")
        self.wait("kafka", 0, ["kafka-topics", *broker, "--list"])
        features = self.tool("kafka", 0, ["kafka-features", *broker, "describe"]).stdout
        (self.directory / "features-before.txt").write_bytes(features)
        self.tool("kafka", 0, ["kafka-topics", *broker, "--create", "--topic", "fixture-events", "--partitions", "2", "--replication-factor", "1"])
        self.tool("kafka", 0, ["kafka-console-producer", *broker, "--topic", "fixture-events", "--producer-property", "acks=all"], b"first\nsecond\nthird\n")
        consume = ["kafka-console-consumer", *broker, "--topic", "fixture-events", "--from-beginning", "--max-messages", "3", "--timeout-ms", "20000"]
        before = self.tool("kafka", 0, consume).stdout
        HA.require(sorted(before.splitlines()) == [b"first", b"second", b"third"], "Fixture records were not acknowledged/read")
        self.tool("kafka", 0, ["kafka-features", *broker, "upgrade", "--feature", "kraft.version=1"])
        (self.directory / "features-upgraded.txt").write_bytes(self.tool("kafka", 0, ["kafka-features", *broker, "describe"]).stdout)
        self.stop("kafka", 0)
        self.stop("kafka-controller", 0)
        self.start("kafka-controller", 0, "dynamic")
        self.start("kafka", 0, "dynamic")
        self.wait("kafka", 0, ["kafka-topics", *broker, "--list"])
        self.results["preservedStaticDataThroughDynamicUpgrade"] = True
        for ordinal in [1, 2]:
            self.start("kafka-controller", ordinal, "expanded")
            self.start("kafka", ordinal, "expanded")
            replication = self.wait("kafka-controller", 0,
                ["kafka-metadata-quorum", "--bootstrap-controller", "localhost:9093", "describe", "--replication"],
                lambda r: r.returncode == 0 and HA.caught_up(r.stdout.decode(), 3000 + ordinal))
            (self.directory / f"observer-{ordinal}.txt").write_bytes(replication.stdout)
            self.tool("kafka-controller", ordinal, ["kafka-metadata-quorum", "--command-config", "/etc/kafka/kafka.properties",
                "--bootstrap-controller", "kafka-controller-0.kafka-controller.infra.svc.cluster.local:9093", "add-controller"])
        status = self.tool("kafka-controller", 0, ["kafka-metadata-quorum", "--bootstrap-controller", "localhost:9093", "describe", "--status"]).stdout
        (self.directory / "quorum-three.txt").write_bytes(status)
        HA.require(HA.voter_ids(HA.quorum_status(status.decode())) == HA.CONTROLLERS, "Expected three native voters")
        self.results["admittedCaughtUpObservers"] = True
        topics = HA.partitions(self.tool("kafka", 0, ["kafka-topics", *broker, "--describe"]).stdout.decode())
        HA.require("__consumer_offsets" in {p["topic"] for p in topics}, "Internal topic fixture is missing")
        plan = HA.assignment(topics)
        self.tool("kafka", 0, ["sh", "-c", "cat > /tmp/reassignment.json"], json.dumps(plan).encode())
        self.tool("kafka", 0, ["kafka-reassign-partitions", *broker, "--reassignment-json-file", "/tmp/reassignment.json", "--execute"])
        self.wait("kafka", 0, ["kafka-topics", *broker, "--describe"], lambda r: r.returncode == 0 and HA.full_replication(HA.partitions(r.stdout.decode())))
        features = self.tool("kafka", 0, ["kafka-features", *broker, "describe"]).stdout.decode()
        elr_enabled = bool(re.search(r"Feature:\s+eligible.leader.replicas.version\s+.*FinalizedVersionLevel:\s+1\b", features))
        for command in HA.write_policy_commands(elr_enabled):
            self.tool("kafka", 0, [command[0], *broker, *command[1:]])
        for topic in sorted({p["topic"] for p in topics}):
            self.tool("kafka", 0, ["kafka-configs", *broker, "--entity-type", "topics", "--entity-name", topic,
                      "--alter", "--add-config", "min.insync.replicas=2,unclean.leader.election.enable=false"])
        self.results["replicatedPartitionsIncludingInternal"] = len(topics)
        for role in ["kafka-controller", "kafka"]:
            for ordinal in [2, 1, 0]:
                self.stop(role, ordinal)
                self.start(role, ordinal, "active")
                self.wait("kafka", ordinal if role == "kafka" else 1, ["kafka-topics", *broker, "--list"])
        self.wait("kafka", 1, ["kafka-topics", *broker, "--describe"], lambda r: r.returncode == 0 and HA.full_replication(HA.partitions(r.stdout.decode())))
        for ordinal in [0, 1, 2]:
            configs = self.tool("kafka", ordinal, ["kafka-configs", "--bootstrap-server", "localhost:9092", "--entity-type", "brokers", "--entity-name", str(ordinal + 1), "--describe", "--all"]).stdout.decode()
            HA.require(HA.effective_config(configs, "min.insync.replicas") == "2" and HA.effective_config(configs, "unclean.leader.election.enable") == "false", "Effective active broker policy differs")
        # A paired controller+broker loss simulates processes co-located on the
        # original host. Docker cannot validate physical host/storage placement.
        for role in ["kafka", "kafka-controller"]:
            self.run(["docker", "kill", "--signal", "KILL", self.names[(role, 0)]])
            self.run(["docker", "rm", "-v", self.names[(role, 0)]])
        self.wait("kafka", 1, ["kafka-topics", *broker, "--list"])
        self.tool("kafka", 1, ["kafka-console-producer", *broker, "--topic", "fixture-events", "--producer-property", "acks=all"], b"after-failure\n")
        consume[consume.index("3")] = "4"
        after = self.tool("kafka", 1, consume).stdout
        HA.require(sorted(after.splitlines()) == [b"after-failure", b"first", b"second", b"third"], "Records were not preserved through original-node process loss")
        self.results["continuedAcknowledgedWritesAfterOriginalProcessLoss"] = True

    def cleanup(self):
        for name in self.names.values():
            logs = self.run(["docker", "logs", "--tail", "100", name], check=False)
            (self.directory / (name + ".log")).write_bytes(logs.stdout + logs.stderr)
            self.run(["docker", "rm", "-f", "-v", name], check=False)
        for volume in self.volumes:
            self.run(["docker", "volume", "rm", volume], check=False)
        self.run(["docker", "network", "rm", self.network], check=False)
        (self.directory / "result.json").write_text(json.dumps(self.results, indent=2) + "\n")
        print(json.dumps(self.results))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, help="New private evidence directory outside the repository")
    args = parser.parse_args()
    canary = Canary(args.output_dir)
    try:
        canary.test()
    except Exception as error:
        canary.results["error"] = str(error)
        raise
    finally:
        canary.cleanup()


if __name__ == "__main__":
    main()
