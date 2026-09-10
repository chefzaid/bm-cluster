#!/usr/bin/env python3
"""Read-only platform checks before a planned host-failure exercise; never enables HA."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(command):
    result = subprocess.run(command, text=True, capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError("Read-only check failed: " + " ".join(command[:4]))
    return result.stdout.strip()


def get(kind, namespace=None, name=None):
    command = ["kubectl", "--request-timeout=30s", "get", kind]
    if namespace:
        command += ["-n", namespace]
    if name:
        command += [name]
    return json.loads(run([*command, "-o", "json"]))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def ready(resource):
    return not resource["metadata"].get("deletionTimestamp") and any(
        c["type"] == "Ready" and c["status"] == "True"
        for c in resource.get("status", {}).get("conditions", []))


def distinct_ready_pods(pods, labels, count, description):
    selected = [p for p in pods if all(p["metadata"].get("labels", {}).get(k) == v for k, v in labels.items()) and ready(p)]
    nodes = {p["spec"].get("nodeName") for p in selected} - {None, ""}
    require(len(nodes) >= count, f"{description}: need {count} Ready pods on distinct hosts; found {len(nodes)}")
    return selected


def verify_storage(volumes, replicas, engines):
    for volume in volumes:
        if volume["metadata"].get("deletionTimestamp"):
            continue
        name = volume["metadata"]["name"]
        require(volume["spec"]["numberOfReplicas"] >= 3, f"Longhorn {name}: fewer than three requested copies")
        attached = volume.get("status", {}).get("state") == "attached"
        active = {replica_name for engine in engines if engine["spec"].get("volumeName") == name
                  and engine.get("status", {}).get("currentState") == "running"
                  for replica_name, mode in engine["status"].get("replicaModeMap", {}).items() if mode == "RW"}
        hosts = {r["spec"].get("nodeID") for r in replicas
                 if r["spec"].get("volumeName") == name and r["spec"].get("healthyAt")
                 and not r["spec"].get("failedAt") and not r["metadata"].get("deletionTimestamp")
                 and (not attached or r["metadata"]["name"] in active)}
        hosts -= {None, ""}
        require(len(hosts) >= 3, f"Longhorn {name}: fewer than three healthy copies on distinct hosts")
        if attached:
            require(volume["status"].get("robustness") == "healthy", f"Longhorn {name}: attached volume is not healthy")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-fencing", action="store_true", help="Also require configured automatic recovery for storage hosts")
    args = parser.parse_args()
    topology = get("configmap", "infra", "bm-cluster-topology")["data"]
    require(topology.get("highAvailabilityEnabled") == "true", "HA is not enabled. Add servers and follow docs/high-availability.md first.")
    nodes = get("nodes")["items"]
    controls = [n for n in nodes if "node-role.kubernetes.io/control-plane" in n["metadata"].get("labels", {})]
    require(len(controls) >= 3 and all(ready(n) for n in controls), "All control planes must be Ready, with at least three members")
    require(all("node-role.kubernetes.io/etcd" in n["metadata"].get("labels", {}) for n in controls), "Every control plane must be an embedded-etcd member")
    require(all(n["metadata"].get("annotations", {}).get("node.bm-cluster.io/fenced-detach-policy") == "verified" for n in controls),
            "Control-plane storage detach safety has not been verified on every host")
    private_ips = {a["address"] for n in controls for a in n["status"].get("addresses", []) if a["type"] == "InternalIP"}
    slices = get("endpointslices", "default")["items"]
    api_ips = {a for s in slices if s["metadata"].get("labels", {}).get("kubernetes.io/service-name") == "kubernetes"
               for e in s.get("endpoints", []) if e.get("conditions", {}).get("ready", True) for a in e["addresses"]}
    require(private_ips <= api_ips, "The Kubernetes Service must advertise every private control-plane endpoint")
    print("PASS: Ready embedded-etcd control planes and private API endpoints")

    ingress = get("configmap", "infra", "bm-cluster-public-ingress")["data"]
    require(ingress.get("mode") == "tunnel" and ingress.get("tunnelID") and
            ingress.get("publishedTunnelID") == ingress["tunnelID"],
            "Public DNS publication has not been verified for the prepared ingress tunnel")
    run(["python3", str(ROOT / "scripts/configure-cloudflare-tunnel.py"), "--verify-origins", "--domain", ingress["domain"]])
    print("PASS: published tunnel identity and current origin TLS listeners")

    infra = get("pods", "infra")["items"]
    for kind, name, count, namespace in [
        ("daemonset", "ingress-nginx-controller", 3, "infra"),
        ("deployment", "coredns", 3, "kube-system"),
        ("deployment", "cloudnative-pg", 3, "cnpg-system"),
        ("statefulset", "shared-redis-ha-server", 3, "infra"),
        ("deployment", "shared-redis-ha-haproxy", 3, "infra"),
        ("deployment", "keycloak", 2, "infra"),
        *[("deployment", name, 2, "infra") for name in
          ("external-secrets", "external-secrets-webhook", "external-secrets-cert-controller",
           "argocd-server", "argocd-repo-server", "argocd-applicationset-controller", "argocd-redis-ha-haproxy")],
        ("statefulset", "argocd-redis-ha-server", 3, "infra")]:
        workload = get(kind, namespace, name)
        pods = infra if namespace == "infra" else get("pods", namespace)["items"]
        selected = distinct_ready_pods(pods, workload["spec"]["selector"]["matchLabels"], count, name)
        if name == "ingress-nginx-controller":
            require(all(any(c["name"] == "cloudflared" and c.get("ready") for c in p["status"].get("containerStatuses", [])) for p in selected),
                    "Every ingress pod must have a Ready tunnel connector")
    print("PASS: ingress, DNS, identity, secrets and delivery replicas occupy separate hosts")

    cluster = get("clusters.postgresql.cnpg.io", "infra", "postgres-ha")
    distinct_ready_pods(infra, {"cnpg.io/cluster": "postgres-ha", "cnpg.io/podRole": "instance"}, 3, "PostgreSQL")
    primary = cluster["status"]["currentPrimary"]
    sql = "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'; SHOW synchronous_commit; SHOW synchronous_standby_names;"
    result = run(["kubectl", "-n", "infra", "exec", primary, "-c", "postgres", "--", "psql", "-U", "postgres", "-d", "postgres", "-Atc", sql]).splitlines()
    require(len(result) == 3 and result[:2] == ["2", "on"] and result[2].startswith("ANY 1"), "PostgreSQL synchronous standbys are not healthy")
    run(["bash", str(ROOT / "scripts/configure-vault-ha.sh"), "--verify"])
    run(["python3", str(ROOT / "scripts/configure-kafka-ha.py"), "verify"])
    redis = run(["kubectl", "-n", "infra", "exec", "shared-redis-ha-server-0", "-c", "sentinel", "--",
                 "redis-cli", "-p", "26379", "SENTINEL", "CKQUORUM", "mymaster"])
    require(redis.startswith("OK"), "Shared Redis Sentinel cannot reach a failover quorum")
    print("PASS: PostgreSQL synchronous replication, Vault voters, Kafka replication and Redis quorum")

    volumes = get("volumes.longhorn.io", "longhorn-system")["items"]
    require(get("settings.longhorn.io", "longhorn-system", "node-down-pod-deletion-policy")["value"] == "do-nothing",
            "Longhorn must leave unreachable-node pod deletion to verified fencing")
    verify_storage(volumes, get("replicas.longhorn.io", "longhorn-system")["items"],
                   get("engines.longhorn.io", "longhorn-system")["items"])
    print("PASS: every retained Longhorn volume has three healthy copies on distinct hosts")
    if args.require_fencing:
        app = get("application", "infra", "bm-cluster")
        fencing = app["spec"]["source"]["helm"]["valuesObject"].get("nodeFencing", {})
        require(fencing.get("enabled") is True, "Automatic singleton recovery requires a verified fencing inventory")
        eligible = {n["metadata"]["name"] for n in nodes if not any(t["effect"] in ("NoSchedule", "NoExecute") for t in n.get("spec", {}).get("taints", []))}
        require(eligible <= set(fencing["nodeNames"]), "Fencing inventory does not cover every workload host")
        job = get("cronjob", "infra", "node-fencing")
        require(not job["spec"].get("suspend", False) and job.get("status", {}).get("lastSuccessfulTime"),
                "Fencing controller has not completed its inventory/cluster checks successfully")
        last_success = datetime.datetime.fromisoformat(job["status"]["lastSuccessfulTime"].replace("Z", "+00:00"))
        age = (datetime.datetime.now(datetime.timezone.utc) - last_success).total_seconds()
        require(0 <= age < 180, "Fencing controller has no recent successful inventory/cluster check")
        print("PASS: automatic fencing covers every workload host; confirm BMC power control during acceptance")
    else:
        print("NOTE: singleton recovery is not certified; use --require-fencing after configuring power control.")
    print("Platform readiness checks passed. A controlled loss-of-one-host exercise is still required; see docs/high-availability.md.")
    print("Application readiness and failover checks belong to each application's deployment workflow.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        sys.exit(1)
