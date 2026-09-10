#!/usr/bin/env python3
"""Readiness must measure actual host redundancy, including storage rebuilds."""
import copy
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("readiness", Path(__file__).with_name("verify-high-availability.py"))
readiness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(readiness)


class ReadinessTests(unittest.TestCase):
    def test_platform_readiness_does_not_require_application_access(self):
        """Application namespace permissions and lifecycle cannot block the platform."""
        condition = {"conditions": [{"type": "Ready", "status": "True"}]}
        nodes = [{"metadata": {"name": f"cp-{i}", "labels": {
                    "node-role.kubernetes.io/control-plane": "true",
                    "node-role.kubernetes.io/etcd": "true"}, "annotations": {
                    "node.bm-cluster.io/fenced-detach-policy": "verified"}},
                  "status": {**condition, "addresses": [{"type": "InternalIP", "address": f"10.40.0.{i}"}]}}
                 for i in range(1, 4)]
        pods = [{"metadata": {"name": f"platform-fixture-{i}", "labels": {"component": "platform-fixture",
                     "cnpg.io/cluster": "postgres-ha", "cnpg.io/podRole": "instance"}},
                 "spec": {"nodeName": f"cp-{i}"}, "status": {
                     **condition, "containerStatuses": [{"name": "cloudflared", "ready": True}]}}
                for i in range(1, 4)]
        resources = {
            ("configmap", "infra", "bm-cluster-topology"): {"data": {"highAvailabilityEnabled": "true"}},
            ("configmap", "infra", "bm-cluster-public-ingress"): {"data": {
                "mode": "tunnel", "tunnelID": "fixture-tunnel", "publishedTunnelID": "fixture-tunnel", "domain": "example.com"}},
            ("nodes", None, None): {"items": nodes},
            ("endpointslices", "default", None): {"items": [{"metadata": {"labels": {
                "kubernetes.io/service-name": "kubernetes"}}, "endpoints": [
                    {"addresses": [f"10.40.0.{i}"]} for i in range(1, 4)]}]},
            ("clusters.postgresql.cnpg.io", "infra", "postgres-ha"): {"status": {"currentPrimary": "database-1"}},
            ("settings.longhorn.io", "longhorn-system", "node-down-pod-deletion-policy"): {"value": "do-nothing"},
            ("volumes.longhorn.io", "longhorn-system", None): {"items": [{"metadata": {"name": "volume"},
                "spec": {"numberOfReplicas": 3}, "status": {"state": "attached", "robustness": "healthy"}}]},
            ("replicas.longhorn.io", "longhorn-system", None): {"items": [
                {"metadata": {"name": f"r{i}"}, "spec": {"nodeID": f"cp-{i}", "volumeName": "volume", "healthyAt": "healthy"}}
                for i in range(1, 4)]},
            ("engines.longhorn.io", "longhorn-system", None): {"items": [{"spec": {"volumeName": "volume"},
                "status": {"currentState": "running", "replicaModeMap": {f"r{i}": "RW" for i in range(1, 4)}}}]},
        }

        def get_resource(kind, namespace=None, name=None):
            if namespace == "apps":
                raise PermissionError("Application resources are outside platform readiness access")
            if kind == "namespaces":
                return {"items": [{"metadata": {"name": "apps"}}]}
            if kind == "pods" and namespace in ("infra", "kube-system", "cnpg-system"):
                return {"items": pods}
            if kind in ("deployment", "daemonset", "statefulset"):
                return {"spec": {"selector": {"matchLabels": {"component": "platform-fixture"}}}}
            return resources[(kind, namespace, name)]

        def run_command(command):
            if "psql" in command:
                return "2\non\nANY 1 (database-2, database-3)"
            if "redis-cli" in command:
                return "OK 3 usable Sentinels"
            self.assertIn(Path(command[1]).name, (
                "configure-cloudflare-tunnel.py", "configure-vault-ha.sh", "configure-kafka-ha.py"))
            return ""

        output = io.StringIO()
        with patch.object(readiness, "get", side_effect=get_resource) as get, \
             patch.object(readiness, "run", side_effect=run_command) as run, \
             patch("sys.argv", ["verify-high-availability.py"]), contextlib.redirect_stdout(output):
            readiness.main()
        self.assertIn("Platform readiness checks passed", output.getvalue())
        self.assertFalse(any(call.args[0] == "namespaces" or "apps" in call.args for call in get.call_args_list))
        self.assertEqual(len(run.call_args_list), 5)
        queried = {call.args + (None,) * (3 - len(call.args)) for call in get.call_args_list}
        self.assertTrue(resources.keys() <= queried)

    def test_ready_replicas_on_one_host_are_not_ha(self):
        pods = [{"metadata": {"labels": {"app": "fixture"}}, "spec": {"nodeName": "same"},
                 "status": {"conditions": [{"type": "Ready", "status": "True"}]}} for _ in range(3)]
        with self.assertRaisesRegex(RuntimeError, "distinct hosts"):
            readiness.distinct_ready_pods(pods, {"app": "fixture"}, 3, "fixture")
        for i, pod in enumerate(pods):
            pod["spec"]["nodeName"] = str(i)
        readiness.distinct_ready_pods(pods, {"app": "fixture"}, 3, "fixture")
        pods[0]["metadata"]["deletionTimestamp"] = "deleting"
        with self.assertRaises(RuntimeError):
            readiness.distinct_ready_pods(pods, {"app": "fixture"}, 3, "fixture")

    def test_replica_count_does_not_certify_storage_before_rebuild_finishes(self):
        volumes = [{"metadata": {"name": "volume"}, "spec": {"numberOfReplicas": 3},
                    "status": {"state": "attached", "robustness": "healthy"}}]
        replicas = [{"metadata": {"name": "r" + str(i)}, "spec": {"nodeID": str(i),
                     "volumeName": "volume", "healthyAt": "previously", "failedAt": ""}} for i in range(3)]
        engines = [{"spec": {"volumeName": "volume"}, "status": {"currentState": "running",
                    "replicaModeMap": {"r0": "RW", "r1": "RW", "r2": "RW"}}}]
        readiness.verify_storage(volumes, replicas, engines)
        for broken in ("copying", "failed", "colocated", "detached-engine"):
            candidate, engine = copy.deepcopy(replicas), copy.deepcopy(engines)
            if broken == "copying":
                engine[0]["status"]["replicaModeMap"]["r2"] = "WO"
            elif broken == "failed":
                candidate[2]["spec"]["failedAt"] = "now"
            elif broken == "colocated":
                candidate[2]["spec"]["nodeID"] = "1"
            else:
                engine[0]["status"]["currentState"] = "stopped"
            with self.subTest(broken=broken), self.assertRaises(RuntimeError):
                readiness.verify_storage(volumes, candidate, engine)
        volumes[0]["status"]["state"] = "detached"
        readiness.verify_storage(volumes, replicas, [])


if __name__ == "__main__":
    unittest.main()
