#!/usr/bin/env python3
"""Explicit, resumable native KRaft expansion; never deletes/reformats existing PVCs."""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import weakref

import yaml

ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = "infra"
CONTROLLERS = {3000, 3001, 3002}
BROKERS = {1, 2, 3}
PHASES = {name: index for index, name in enumerate(["prepared", "fresh-started", "dynamic-started", "dynamic", "expanded-started", "expanded", "replicating", "activating", "active"])}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def profile(cluster_id, phase, bootstrap=False):
    require(bool(re.fullmatch(r"[A-Za-z0-9_-]{22}", cluster_id)), "Invalid Kafka cluster UUID")
    require(phase in {"dynamic", "expanded", "active"}, "Invalid Kafka migration phase")
    return {"enabled": True, "phase": phase, "clusterId": cluster_id, "bootstrap": bootstrap}


def quorum_status(output):
    result = {}
    for line in output.splitlines():
        key, separator, value = line.partition(":")
        if separator and key.strip() in {"ClusterId", "CurrentVoters", "LeaderId"}:
            result[key.strip()] = value.strip()
    require(set(result) == {"ClusterId", "CurrentVoters", "LeaderId"}, "Incomplete Kafka quorum status")
    result["CurrentVoters"] = json.loads(result["CurrentVoters"])
    result["LeaderId"] = int(result["LeaderId"])
    return result


def voter_ids(status):
    return {int(voter["id"]) for voter in status["CurrentVoters"]}


def partitions(output):
    result = []
    for line in output.splitlines():
        match = re.search(r"Topic:\s+(\S+)\s+Partition:\s+(\d+)\s+Leader:\s+(-?\d+)\s+Replicas:\s+([\d,]+)\s+Isr:\s*([\d,]*)", line, re.I)
        if match:
            result.append({"topic": match[1], "partition": int(match[2]), "leader": int(match[3]),
                           "replicas": [int(x) for x in match[4].split(",")],
                           "isr": [int(x) for x in match[5].split(",") if x]})
    require(not output.strip() or result, "Topic output was not understood; refusing an incomplete inventory")
    require(len({(p["topic"], p["partition"]) for p in result}) == len(result), "Duplicate partition inventory")
    return result


def full_replication(parts):
    return all(set(p["replicas"]) == BROKERS and len(p["replicas"]) == 3 and
               set(p["isr"]) == BROKERS and p["leader"] in BROKERS for p in parts)


def assignment(parts):
    # Preserve the existing preferred leader when possible, balance new partitions.
    result = []
    for part in parts:
        leader = part["replicas"][0]
        require(leader in BROKERS, "Unexpected original broker in partition assignment")
        replicas = [leader, *[node for node in sorted(BROKERS) if node != leader]]
        result.append({"topic": part["topic"], "partition": part["partition"], "replicas": replicas})
    return {"version": 1, "partitions": result}


def caught_up(output, node_id):
    lines = [line.split() for line in output.splitlines() if line.strip()]
    header = next((line for line in lines if "NodeId" in line and "Lag" in line), None)
    require(header is not None, "Unrecognized metadata replication table")
    for line in lines:
        if len(line) == len(header) and line[0] == str(node_id):
            row = dict(zip(header, line))
            # A zero log lag alone can be stale; insist on a recent successful fetch.
            return (row["Lag"] == "0" and row.get("Status") in {"Observer", "Follower", "Leader"}
                    and row.get("LastCaughtUpTimestamp", "-1").isdigit()
                    and time.time() * 1000 - int(row["LastCaughtUpTimestamp"]) < 30000)
    return False


def effective_config(output, key):
    match = re.search(r"(?:^|\s)" + re.escape(key) + r"=([^\s]+)", output)
    require(match is not None, "Kafka did not report effective " + key)
    return match[1]


def write_policy_commands(elr_enabled):
    # ELR requires min ISR at cluster/topic level and rejects even DELETE at
    # broker level. With ELR disabled, remove any overriding broker minimum.
    config = "min.insync.replicas=2,unclean.leader.election.enable=false"
    commands = [("kafka-configs", "--entity-type", "brokers", "--entity-default", "--alter", "--add-config", config)]
    for broker in sorted(BROKERS):
        commands.append(("kafka-configs", "--entity-type", "brokers", "--entity-name", str(broker),
                         "--alter", "--delete-config", "unclean.leader.election.enable" +
                         ("" if elr_enabled else ",min.insync.replicas")))
    return commands


class Migration:
    def __init__(self, args):
        self.args = args
        self.kubectl = shlex.split(os.environ.get("KUBECTL", "kubectl"))
        self.directory = None
        self.state = {}
        if args.state_dir:
            self.directory = Path(args.state_dir).absolute()
            require(all(not item.is_symlink() for item in [self.directory, *self.directory.parents]),
                    "State directory ancestry must not contain symlinks")
            self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            info = self.directory.stat()
            require(info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o700,
                    "State directory must belong to the current user with permissions 0700")
            state = self.directory / "state.json"
            require(not state.is_symlink(), "State file cannot be a symlink")
            if args.action != "verify":
                descriptor = os.open(self.directory / ".migration.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                self.lock = os.fdopen(descriptor, "w")
                self._lock_cleanup = weakref.finalize(self, self.lock.close)
                try:
                    fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    raise RuntimeError("Another process is using this migration journal") from error
            if state.exists():
                self.state = json.loads(state.read_text())
        require(args.action == "verify" or self.directory is not None, "--state-dir is required for migration actions")

    def write(self, name, value):
        require(self.directory is not None, "A private state directory is required")
        path = self.directory / name
        require(path.parent == self.directory and not path.is_symlink(), "Unsafe journal filename")
        data = value if isinstance(value, bytes) else json.dumps(value, indent=2).encode() + b"\n"
        fd, temporary = tempfile.mkstemp(prefix=".checkpoint-", dir=self.directory)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
            directory_fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return path

    def run(self, command, data=None):
        result = subprocess.run(command, input=data, capture_output=True, timeout=self.args.timeout)
        if result.returncode:
            if self.directory:
                self.write("command-error.log", result.stderr + b"\n" + result.stdout)
            raise RuntimeError("Kafka/Kubernetes command failed; inspect the private command-error.log if available. No rollback was attempted.")
        return result.stdout.decode()

    def kube(self, *args, data=None):
        return self.run([*self.kubectl, *args], data=data)

    def get(self, kind, name=None, namespace=NAMESPACE, all_namespaces=False):
        output = self.kube("get", kind, *([name] if name else []), "-o", "json", "--ignore-not-found",
                           *(["-A"] if all_namespaces else ["-n", namespace] if namespace else []))
        return json.loads(output) if output.strip() else None

    def apply(self, resource):
        self.kube("apply", "-f", "-", data=json.dumps(resource).encode())

    def record(self, **changes):
        self.state.update(changes)
        self.write("state.json", self.state)

    def checkpoint(self):
        current = self.get("configmap", "kafka-ha-state")
        require(self.state.get("migrationId"), "Migration journal identity is missing")
        if current:
            data = current["data"]
            require(data.get("migrationId") == self.state["migrationId"] and
                    data.get("kubernetesUid") == self.state["kubernetesUid"],
                    "Published Kafka checkpoint belongs to another migration journal")
            require(data.get("phase") in PHASES and self.state.get("phase") in PHASES,
                    "Unrecognized Kafka migration checkpoint")
            require(PHASES[data["phase"]] <= PHASES[self.state["phase"]],
                    "Local journal is stale; resume from the latest original journal, never move Kafka backward")
            require(json.loads(data["kafkaHa"])["clusterId"] == self.state["clusterId"], "Published Kafka cluster identity differs")
        else:
            require(self.state.get("phase") in {"prepared", "dynamic-started", "fresh-started"},
                    "Published Kafka checkpoint disappeared; recover it before resuming")
        return current

    def publish(self, phase, ha):
        current = self.checkpoint()
        require(phase in PHASES and PHASES[phase] >= PHASES[self.state["phase"]], "Kafka checkpoint cannot move backward")
        self.record(phase=phase, kafkaHa=ha)
        resource = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "kafka-ha-state", "namespace": NAMESPACE},
                    "data": {"phase": phase, "kafkaHa": json.dumps(ha, sort_keys=True),
                             "migrationId": self.state["migrationId"], "kubernetesUid": self.state["kubernetesUid"]}}
        if current:
            resource["metadata"]["resourceVersion"] = current["metadata"]["resourceVersion"]
        # Create binds the first journal exclusively. Resource-version replacement
        # prevents silently overwriting a checkpoint changed by another operator.
        self.kube("replace" if current else "create", "-f", "-", data=json.dumps(resource).encode())

    def tool(self, pod, command, data=None):
        container = "kafka-controller" if pod.startswith("kafka-controller-") else "kafka"
        return self.kube("exec", "-i", "-n", NAMESPACE, pod, "-c", container, "--",
                         "env", "KAFKA_HEAP_OPTS=-Xms32m -Xmx256m", *command, data=data)

    def ready_pods(self, role, count):
        pods = [p for p in self.get("pods")["items"] if p["metadata"].get("labels", {}).get("app") == role
                and not p["metadata"].get("deletionTimestamp")]
        require(len(pods) == count and all(any(c["type"] == "Ready" and c["status"] == "True"
                    for c in p.get("status", {}).get("conditions", [])) for p in pods),
                f"All {count} {role} pods must be Ready")
        require(len({p["spec"].get("nodeName") for p in pods}) == count, f"{role} pods must occupy distinct hosts")
        return pods

    def broker(self):
        pods = self.get("pods")["items"]
        for pod in sorted(pods, key=lambda p: p["metadata"]["name"]):
            if (pod["metadata"].get("labels", {}).get("app") == "kafka" and
                    not pod["metadata"].get("deletionTimestamp") and
                    any(c["type"] == "Ready" and c["status"] == "True" for c in pod.get("status", {}).get("conditions", []))):
                return pod["metadata"]["name"]
        raise RuntimeError("No Ready Kafka broker")

    def admin(self, program, *args):
        return self.tool(self.broker(), [program, "--bootstrap-server", "localhost:9092", *args])

    def status(self):
        return quorum_status(self.admin("kafka-metadata-quorum", "describe", "--status"))

    def topics(self):
        return partitions(self.admin("kafka-topics", "--describe"))

    def wait(self, check, message):
        deadline = time.monotonic() + self.args.timeout
        last = None
        while time.monotonic() < deadline:
            try:
                if check():
                    return
            except RuntimeError as error:
                last = error
            time.sleep(3)
        raise RuntimeError(message + (": " + str(last) if last else ""))

    def preflight(self, mutation=False):
        cluster_uid = self.get("namespace", "kube-system", namespace=None)["metadata"]["uid"]
        require(not self.state.get("kubernetesUid") or cluster_uid == self.state["kubernetesUid"], "State directory belongs to a different Kubernetes cluster")
        nodes = self.get("nodes", namespace=None)["items"]
        ready = [node for node in nodes if not node.get("spec", {}).get("unschedulable") and
                 any(c["type"] == "Ready" and c["status"] == "True" for c in node.get("status", {}).get("conditions", []))]
        control_planes = [n for n in ready if "node-role.kubernetes.io/control-plane" in n["metadata"].get("labels", {})]
        schedulable = [n for n in ready if not any(t["effect"] in {"NoSchedule", "NoExecute"} for t in n.get("spec", {}).get("taints", []))]
        require(len(control_planes) >= 3 and len(schedulable) >= 3, "Three Ready control planes and three schedulable hosts are required")
        if mutation:
            require(self.args.maintenance and self.args.backup_confirmed,
                    "--maintenance and --backup-confirmed are required: stop clients and verify a recoverable data backup")
            for app in self.get("applications.argoproj.io", namespace=None, all_namespaces=True)["items"]:
                automated = app["spec"].get("syncPolicy", {}).get("automated")
                require(automated is None or automated.get("enabled") is False, "Pause automatic sync on all Argo Applications")
                require(not app.get("operation") and app.get("status", {}).get("operationState", {}).get("phase") not in {"Running", "Terminating"},
                        "Wait for all Argo operations to finish")
        return cluster_uid

    def legacy_identity(self):
        ids = {}
        for role, claim, node_id, directory in [("kafka-controller", "controller-data", 3000, "controller"),
                                               ("kafka", "kafka-data", 1, "kafka-logs")]:
            sts = self.get("statefulset", role)
            pvc = self.get("pvc", f"{claim}-{role}-0")
            require(sts and pvc, "Original Kafka StatefulSets and PVCs must exist")
            if not self.state.get("kafkaHa"):
                require(sts["spec"]["replicas"] == 1, "Initial migration requires the original one-controller, one-broker deployment")
            properties = self.tool(f"{role}-0", ["cat", f"/var/lib/kafka/data/{directory}/meta.properties"])
            props = dict(line.split("=", 1) for line in properties.splitlines() if "=" in line and not line.startswith("#"))
            require(props.get("node.id") == str(node_id), "Original Kafka node identity differs")
            ids[role] = {"statefulSetUid": sts["metadata"]["uid"], "pvcUid": pvc["metadata"]["uid"], "clusterId": props.get("cluster.id")}
        require(ids["kafka"]["clusterId"] == ids["kafka-controller"]["clusterId"], "Original Kafka storage cluster identities differ")
        require(not self.state.get("original") or ids == self.state["original"], "Original Kafka resources or PVC identities changed")
        return ids

    def prepare(self):
        cluster_uid = self.preflight()
        require(not self.state, "Use the existing migration journal; prepare never overwrites it")
        current = self.get("configmap", "kafka-ha-state")
        require(not current, "Kafka HA state already exists; use its original private migration journal")
        original = self.legacy_identity()
        status = self.status()
        require(voter_ids(status) == {3000} and status["ClusterId"] == original["kafka"]["clusterId"], "Expected the original singleton Kafka quorum")
        require(all(set(p["replicas"]) == {1} and set(p["isr"]) == {1} for p in self.topics()), "Original partitions must be healthy on broker 1")
        self.write("original-resources.json", {kind: self.get(kind) for kind in ["statefulsets", "services", "persistentvolumeclaims"]})
        self.write("original-applications.json", self.get("applications.argoproj.io", namespace=None, all_namespaces=True))
        self.write("original-topics.json", self.topics())
        self.write("original-features.txt", self.admin("kafka-features", "describe").encode())
        self.record(kubernetesUid=cluster_uid, migrationId=str(uuid.uuid4()), original=original, clusterId=status["ClusterId"], phase="prepared")
        self.validate_images(self.render(profile(status["ClusterId"], "active"), "review-active-manifests.yaml"))

    def desired_values(self, ha):
        require(self.args.desired_values, "--desired-values must reference reviewed rendered installation values")
        try:
            values = yaml.safe_load(Path(self.args.desired_values).read_text())
        except yaml.YAMLError as error:
            raise RuntimeError("Desired values are invalid YAML; inspect the private input file") from error
        require(isinstance(values, dict), "Expected a Helm values mapping")
        values["kafkaHa"] = ha
        return values

    def render(self, ha, filename):
        values = self.write("render-values.json", self.desired_values(ha))
        output = self.run(["helm", "template", "bm-cluster", str(ROOT / "k8s"), "-n", NAMESPACE, "-f", str(values)])
        names = {("StatefulSet", "kafka"), ("StatefulSet", "kafka-controller"), ("Service", "kafka"),
                 ("Service", "kafka-controller"), ("ConfigMap", "kafka-ha-startup"),
                 ("PodDisruptionBudget", "kafka"), ("PodDisruptionBudget", "kafka-controller")}
        resources = [doc for doc in yaml.safe_load_all(output) if doc and (doc["kind"], doc["metadata"]["name"]) in names]
        require(len(resources) == (7 if ha["phase"] == "active" else 5), "Kafka chart resources are incomplete")
        self.write(filename, yaml.safe_dump_all(resources).encode())
        return resources

    def validate_images(self, resources):
        for resource in resources:
            if resource["kind"] == "StatefulSet":
                old = self.get("statefulset", resource["metadata"]["name"])
                if old:
                    require(old["spec"]["template"]["spec"]["containers"][0]["image"] == resource["spec"]["template"]["spec"]["containers"][0]["image"],
                            "Upgrade Kafka images separately before changing quorum topology")
    def apply_profile(self, ha):
        resources = self.render(ha, "phase-manifests.yaml")
        self.validate_images(resources)
        self.checkpoint()
        # Merge only this service's map. Preserve PostgreSQL, fencing, source path,
        # sync policy and every unrelated Argo field, including existing HA mode.
        for app in self.get("applications.argoproj.io", namespace=None, all_namespaces=True)["items"]:
            if app["metadata"]["name"] == "bm-cluster" and app["metadata"]["namespace"] == NAMESPACE:
                self.kube("patch", "application.argoproj.io", "bm-cluster", "-n", app["metadata"]["namespace"], "--type", "merge",
                          "-p", json.dumps({"spec": {"source": {"helm": {"valuesObject": {"kafkaHa": ha}}}}}))
        resources.sort(key=lambda r: {"ConfigMap": 0, "Service": 1, "StatefulSet": 2, "PodDisruptionBudget": 3}[r["kind"]])
        for resource in resources:
            self.apply(resource)
        for role in ["kafka-controller", "kafka"]:
            self.kube("rollout", "status", "statefulset/" + role, "-n", NAMESPACE, "--timeout=" + str(self.args.timeout) + "s")

    def migrate(self):
        self.preflight(mutation=True)
        require(self.state.get("phase") in {"prepared", "dynamic-started", "dynamic", "expanded-started", "expanded", "replicating", "activating", "active"},
                "Run prepare first and use a recognized migration checkpoint, or resume fresh with the fresh action")
        self.checkpoint()
        self.legacy_identity()
        cluster_id = self.state["clusterId"]
        require(self.status()["ClusterId"] == cluster_id, "Kafka quorum cluster identity changed")
        if self.state["phase"] == "active":
            self.verify()
            return
        self.validate_images(self.render(profile(cluster_id, "active"), "review-active-manifests.yaml"))
        # Publish the block before the first irreversible native feature change.
        if self.state["phase"] in {"prepared", "dynamic-started"}:
            self.publish("dynamic-started", profile(cluster_id, "dynamic"))
            features = self.admin("kafka-features", "describe")
            if not re.search(r"Feature:\s+kraft.version\s+.*FinalizedVersionLevel:\s+1\b", features):
                self.admin("kafka-features", "upgrade", "--feature", "kraft.version=1")
            require(re.search(r"Feature:\s+kraft.version\s+.*FinalizedVersionLevel:\s+1\b", self.admin("kafka-features", "describe")),
                    "Native KRaft feature upgrade did not complete")
            self.apply_profile(profile(cluster_id, "dynamic"))
            self.publish("dynamic", profile(cluster_id, "dynamic"))
        self.expand()

    def expand(self):
        cluster_id = self.state["clusterId"]
        if self.state["phase"] in {"dynamic", "expanded-started"}:
            self.publish("expanded-started", profile(cluster_id, "expanded"))
            self.apply_profile(profile(cluster_id, "expanded"))
            for ordinal in [1, 2]:
                node_id = 3000 + ordinal
                if node_id not in voter_ids(self.status()):
                    self.wait(lambda: caught_up(self.admin("kafka-metadata-quorum", "describe", "--replication"), node_id),
                              "New controller did not catch up as an observer")
                    self.tool(f"kafka-controller-{ordinal}", ["kafka-metadata-quorum", "--command-config", "/etc/kafka/kafka.properties",
                              "--bootstrap-controller", "kafka-controller-0.kafka-controller.infra.svc.cluster.local:9093", "add-controller"])
                    self.wait(lambda: node_id in voter_ids(self.status()), "New controller was not admitted to the voter set")
            require(voter_ids(self.status()) == CONTROLLERS, "Unexpected controller membership")
            self.publish("expanded", profile(cluster_id, "expanded"))
        if self.state["phase"] == "activating":
            self.finish_active()
            return
        if self.state["phase"] in {"expanded", "replicating"}:
            self.ready_pods("kafka", 3)
            self.ready_pods("kafka-controller", 3)
            self.publish("replicating", profile(cluster_id, "expanded"))
            # Clients must remain stopped. Re-read inventory so internal topics and
            # any topic created before the maintenance pause are included.
            parts = self.topics()
            if not full_replication(parts):
                plan = assignment(parts)
                self.write("reassignment.json", plan)
                self.tool(self.broker(), ["sh", "-ceu", "cat > /tmp/bm-kafka-ha-reassignment.json"], json.dumps(plan).encode())
                self.admin("kafka-reassign-partitions", "--reassignment-json-file", "/tmp/bm-kafka-ha-reassignment.json", "--execute")
                self.wait(lambda: full_replication(self.topics()), "Partition replication did not reach RF=3/full ISR; write policy remains unchanged")
            # Enforce broker overrides as well as rendered defaults, so a prior
            # dynamic setting cannot silently defeat the final durability policy.
            config = "min.insync.replicas=2,unclean.leader.election.enable=false"
            features = self.admin("kafka-features", "describe")
            elr_enabled = bool(re.search(r"Feature:\s+eligible.leader.replicas.version\s+.*FinalizedVersionLevel:\s+1\b", features))
            for command in write_policy_commands(elr_enabled):
                self.admin(*command)
            for topic in sorted({p["topic"] for p in self.topics()}):
                self.admin("kafka-configs", "--entity-type", "topics", "--entity-name", topic, "--alter", "--add-config", config)
            self.publish("activating", profile(cluster_id, "active"))
            self.finish_active()

    def finish_active(self):
        ha = profile(self.state["clusterId"], "active")
        self.apply_profile(ha)
        self.verify(expected=ha)
        self.write("active-values.yaml", yaml.safe_dump({"kafkaHa": ha}).encode())
        self.publish("active", ha)

    def fresh(self):
        cluster_uid = self.preflight(mutation=True)
        if not self.state:
            require(not self.get("configmap", "kafka-ha-state"), "Existing Kafka HA checkpoint prevents fresh initialization")
            require(all(not self.get("statefulset", name) for name in ["kafka", "kafka-controller"]), "Fresh bootstrap requires no Kafka StatefulSets")
            claims = self.get("persistentvolumeclaims")["items"]
            require(not any(p["metadata"]["name"].startswith(("kafka-data-kafka-", "controller-data-kafka-controller-")) for p in claims),
                    "Fresh bootstrap requires no original or retained Kafka PVCs")
            cluster_id = base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip("=")
            self.record(kubernetesUid=cluster_uid, migrationId=str(uuid.uuid4()), clusterId=cluster_id, phase="fresh-started")
        require(self.state["phase"] in {"fresh-started", "dynamic", "expanded-started", "expanded", "replicating", "activating", "active"},
                "This journal belongs to an existing-data migration")
        self.checkpoint()
        if self.state["phase"] == "fresh-started":
            ha = profile(self.state["clusterId"], "dynamic", bootstrap=True)
            self.publish("fresh-started", ha)
            self.apply_profile(ha)
            require(self.status()["ClusterId"] == self.state["clusterId"], "Fresh cluster identity mismatch")
            self.apply_profile(profile(self.state["clusterId"], "dynamic"))
            self.publish("dynamic", profile(self.state["clusterId"], "dynamic"))
        if self.state["phase"] == "active":
            self.verify()
        else:
            self.expand()

    def verify(self, expected=None):
        uid = self.preflight()
        if expected is None:
            stored = self.get("configmap", "kafka-ha-state")
            require(stored and stored["data"].get("phase") == "active", "Kafka migration has no active checkpoint")
            require(stored["data"].get("kubernetesUid") == uid, "Kafka checkpoint belongs to another cluster")
            expected = json.loads(stored["data"]["kafkaHa"])
        require(expected == profile(expected.get("clusterId", ""), "active"), "Kafka active profile is incomplete or permits formatting")
        for role in ["kafka", "kafka-controller"]:
            pods = self.ready_pods(role, 3)
            for pod in pods:
                container = pod["spec"]["containers"][0]
                values = {v["name"]: v.get("value") for v in container.get("env", [])}
                require(values.get("CLUSTER_ID") == expected["clusterId"] and values.get("BM_KAFKA_ALLOW_INITIAL_FORMAT") == "false"
                        and "KAFKA_CONTROLLER_QUORUM_VOTERS" not in values, "Kafka pod does not use the safe dynamic profile")
                if role == "kafka":
                    for key, value in {"KAFKA_DEFAULT_REPLICATION_FACTOR": "3", "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR": "3",
                                       "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR": "3", "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR": "2"}.items():
                        require(values.get(key) == value, "Kafka future-topic/transaction replication policy differs")
        current = self.status()
        require(current["ClusterId"] == expected["clusterId"] and voter_ids(current) == CONTROLLERS and current["LeaderId"] in CONTROLLERS,
                "Kafka does not have the expected three-member controller quorum")
        versions = self.admin("kafka-broker-api-versions")
        ids = {int(match) for match in re.findall(r"\(id:\s*(\d+)\s+rack:[^\n)]*\bisFenced:\s*false\)\s*->\s*\(", versions)}
        require(ids == BROKERS, "Kafka does not report the expected three live, unfenced brokers")
        replication = self.admin("kafka-metadata-quorum", "describe", "--replication")
        require(all(caught_up(replication, node) for node in CONTROLLERS), "All three controllers must have recent zero-lag metadata replication")
        parts = self.topics()
        require(full_replication(parts), "Every Kafka partition must have exactly three replicas and a full ISR")
        for kind, entities in [("brokers", sorted(BROKERS)), ("topics", sorted({p["topic"] for p in parts}))]:
            for entity in entities:
                configs = self.admin("kafka-configs", "--entity-type", kind, "--entity-name", str(entity), "--describe", "--all")
                require(effective_config(configs, "min.insync.replicas") == "2" and
                        effective_config(configs, "unclean.leader.election.enable") == "false", "Kafka effective write/election policy differs")
        print("Kafka HA verified: three controllers and brokers on distinct hosts, full topic replication, min ISR 2.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "migrate", "fresh", "verify"])
    parser.add_argument("--state-dir", help="Private durable directory, mode 0700; unnecessary for read-only verify")
    parser.add_argument("--desired-values", help="Reviewed rendered platform Helm values used for Kafka resources")
    parser.add_argument("--maintenance", action="store_true", help="Acknowledge client downtime; stop producers/consumers and pause all Argo autosync")
    parser.add_argument("--backup-confirmed", action="store_true", help="Confirm tested recoverable Kafka record/metadata backups exist outside these PVCs")
    parser.add_argument("--timeout", type=int, default=600, help="Maximum seconds per command/readiness stage")
    args = parser.parse_args()
    require(30 <= args.timeout <= 3600, "Timeout must be between 30 and 3600 seconds")
    migration = Migration(args)
    getattr(migration, args.action)()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.TimeoutExpired) as error:
        print("Kafka HA: " + str(error), file=sys.stderr)
        sys.exit(1)
