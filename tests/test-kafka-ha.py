#!/usr/bin/env python3
"""Offline migration safety and rendered Kafka topology checks."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("kafka_ha", ROOT / "scripts/configure-kafka-ha.py")
HA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HA)
CLUSTER_ID = "8ipNY9RxQtWkattTais5yQ"
TOPICS = """Topic: events TopicId: random PartitionCount: 1 ReplicationFactor: 1 Configs:
 Topic: events Partition: 0 Leader: 1 Replicas: 1 Isr: 1 Elr: LastKnownElr:
Topic: __consumer_offsets TopicId: random PartitionCount: 1 ReplicationFactor: 1 Configs:
 Topic: __consumer_offsets Partition: 0 Leader: 1 Replicas: 1 Isr: 1 Elr: LastKnownElr:
"""


class Safety(unittest.TestCase):
    def test_all_partitions_including_internal_topics(self):
        parts = HA.partitions(TOPICS)
        self.assertEqual({p["topic"] for p in parts}, {"events", "__consumer_offsets"})
        plan = HA.assignment(parts)
        self.assertEqual([p["replicas"] for p in plan["partitions"]], [[1, 2, 3], [1, 2, 3]])
        self.assertFalse(HA.full_replication(parts))
        for part in parts:
            part.update(replicas=[1, 2, 3], isr=[1, 2, 3])
        self.assertTrue(HA.full_replication(parts))
        parts[0]["isr"].pop()
        self.assertFalse(HA.full_replication(parts))
        with self.assertRaises(RuntimeError):
            HA.partitions("Unknown topic output")

    def test_observer_needs_recent_catchup(self):
        now = int(time.time() * 1000)
        header = "NodeId DirectoryId LogEndOffset Lag LastFetchTimestamp LastCaughtUpTimestamp Status\n"
        self.assertTrue(HA.caught_up(header + f"3001 abc 10 0 {now} {now} Observer", 3001))
        self.assertFalse(HA.caught_up(header + f"3001 abc 10 1 {now} {now} Observer", 3001))
        self.assertFalse(HA.caught_up(header + "3001 abc 10 0 0 0 Observer", 3001))
        self.assertFalse(HA.caught_up(header + f"3002 abc 10 0 {now} {now} Observer", 3001))

    def test_quorum_status_and_effective_configs(self):
        output = f'ClusterId: {CLUSTER_ID}\nLeaderId: 3000\nCurrentVoters: [{{"id":3000,"directoryId":"abc","endpoints":["CONTROLLER://controller:9093"]}}]\n'
        self.assertEqual(HA.voter_ids(HA.quorum_status(output)), {3000})
        self.assertEqual(HA.effective_config("min.insync.replicas=2 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:min.insync.replicas=2}", "min.insync.replicas"), "2")
        with self.assertRaises(RuntimeError):
            HA.quorum_status("CurrentVoters: []")
        with self.assertRaises(RuntimeError):
            HA.effective_config("synonyms={DYNAMIC_BROKER_CONFIG:min.insync.replicas=2}", "min.insync.replicas")

    def test_verify_needs_no_local_state_and_never_mutates(self):
        args = argparse.Namespace(action="verify", state_dir=None, timeout=30)
        migration = HA.Migration(args)
        self.assertIsNone(migration.directory)
        with patch.object(migration, "preflight", return_value="cluster-uid"), patch.object(migration, "get", return_value=None), patch.object(migration, "apply") as apply:
            with self.assertRaisesRegex(RuntimeError, "active checkpoint"):
                migration.verify()
            apply.assert_not_called()

    def test_migration_refuses_unprepared_journal_before_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(action="migrate", state_dir=directory, timeout=30)
            migration = HA.Migration(args)
            with patch.object(migration, "preflight"), patch.object(migration, "apply") as apply:
                with self.assertRaisesRegex(RuntimeError, "prepare"):
                    migration.migrate()
                apply.assert_not_called()

    def test_preflight_rejects_single_host_and_active_argocd(self):
        args = argparse.Namespace(action="verify", state_dir=None, timeout=30, maintenance=True, backup_confirmed=True)
        migration = HA.Migration(args)
        node = {"metadata": {"labels": {"node-role.kubernetes.io/control-plane": "true"}}, "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
        def single(kind, *unused, **kwargs):
            return {"metadata": {"uid": "cluster"}} if kind == "namespace" else {"items": [node]}
        with patch.object(migration, "get", side_effect=single):
            with self.assertRaisesRegex(RuntimeError, "Three Ready"):
                migration.preflight(True)
        def multiple(kind, *unused, **kwargs):
            if kind == "namespace":
                return {"metadata": {"uid": "cluster"}}
            if kind == "nodes":
                return {"items": [node, node, node]}
            return {"items": [{"spec": {"syncPolicy": {"automated": {}}}}]}
        with patch.object(migration, "get", side_effect=multiple):
            with self.assertRaisesRegex(RuntimeError, "Pause automatic sync"):
                migration.preflight(True)

    def test_fresh_refuses_retained_pvcs(self):
        with tempfile.TemporaryDirectory() as directory:
            migration = HA.Migration(argparse.Namespace(action="fresh", state_dir=directory, timeout=30))
            def get(kind, *unused, **kwargs):
                return {"items": [{"metadata": {"name": "kafka-data-kafka-0"}}]} if kind == "persistentvolumeclaims" else None
            with patch.object(migration, "preflight", return_value="cluster"), patch.object(migration, "get", side_effect=get), patch.object(migration, "apply") as apply:
                with self.assertRaisesRegex(RuntimeError, "retained Kafka PVCs"):
                    migration.fresh()
                apply.assert_not_called()

    def test_feature_upgrade_precedes_removal_of_static_configuration(self):
        migration = HA.Migration(argparse.Namespace(action="verify", state_dir=None, timeout=30))
        migration.state = {"phase": "prepared", "clusterId": CLUSTER_ID}
        calls = []
        def admin(program, *args):
            calls.append((program, *args))
            return "Feature: kraft.version SupportedMinVersion: 0 SupportedMaxVersion: 1 FinalizedVersionLevel: 1" if len(calls) > 1 else "Feature: kraft.version FinalizedVersionLevel: 0"
        with patch.object(migration, "preflight"), patch.object(migration, "legacy_identity"), patch.object(migration, "status", return_value={"ClusterId": CLUSTER_ID}), patch.object(migration, "publish"), patch.object(migration, "admin", side_effect=admin), patch.object(migration, "apply_profile", side_effect=lambda unused: calls.append(("apply",))), patch.object(migration, "expand"), patch.object(migration, "render", return_value=[]), patch.object(migration, "checkpoint"):
            migration.migrate()
        upgrade = calls.index(("kafka-features", "upgrade", "--feature", "kraft.version=1"))
        self.assertLess(upgrade, calls.index(("apply",)))

    def test_argo_inventory_explicitly_uses_all_namespaces(self):
        migration = HA.Migration(argparse.Namespace(action="verify", state_dir=None, timeout=30))
        with patch.object(migration, "kube", return_value='{"items": []}') as kube:
            migration.get("applications.argoproj.io", namespace=None, all_namespaces=True)
            self.assertIn("-A", kube.call_args.args)
            migration.get("nodes", namespace=None)
            self.assertNotIn("-A", kube.call_args.args)

    def test_checkpoint_rejects_stale_or_foreign_journal(self):
        migration = HA.Migration(argparse.Namespace(action="verify", state_dir=None, timeout=30))
        migration.state = {"phase": "dynamic", "migrationId": "ours", "kubernetesUid": "cluster", "clusterId": CLUSTER_ID}
        current = {"metadata": {"resourceVersion": "1"}, "data": {"phase": "expanded", "migrationId": "ours", "kubernetesUid": "cluster", "kafkaHa": json.dumps(HA.profile(CLUSTER_ID, "expanded"))}}
        with patch.object(migration, "get", return_value=current):
            with self.assertRaisesRegex(RuntimeError, "stale"):
                migration.checkpoint()
            current["data"]["phase"] = "dynamic"
            current["data"]["migrationId"] = "another"
            with self.assertRaisesRegex(RuntimeError, "another migration"):
                migration.checkpoint()

    def test_interrupted_write_preserves_previous_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            migration = HA.Migration(argparse.Namespace(action="verify", state_dir=directory, timeout=30))
            migration.write("state.json", {"phase": "dynamic"})
            with patch.object(HA.os, "replace", side_effect=OSError("fixture interruption")):
                with self.assertRaises(OSError):
                    migration.write("state.json", {"phase": "expanded"})
            self.assertEqual(json.loads((Path(directory) / "state.json").read_text()), {"phase": "dynamic"})
            self.assertEqual(list(Path(directory).glob(".checkpoint-*")), [])

    def test_activating_resume_does_not_rewind_to_expanded(self):
        migration = HA.Migration(argparse.Namespace(action="verify", state_dir=None, timeout=30))
        migration.state = {"phase": "activating", "clusterId": CLUSTER_ID}
        with patch.object(migration, "finish_active") as finish, patch.object(migration, "publish") as publish:
            migration.expand()
            finish.assert_called_once()
            publish.assert_not_called()

    def test_failed_replication_never_enforces_new_write_policy(self):
        migration = HA.Migration(argparse.Namespace(action="verify", state_dir=None, timeout=30))
        migration.state = {"phase": "expanded", "clusterId": CLUSTER_ID}
        with patch.object(migration, "ready_pods"), patch.object(migration, "publish"), patch.object(migration, "topics", return_value=HA.partitions(TOPICS)), patch.object(migration, "write"), patch.object(migration, "tool"), patch.object(migration, "broker", return_value="kafka-0"), patch.object(migration, "admin") as admin, patch.object(migration, "wait", side_effect=RuntimeError("incomplete ISR")):
            with self.assertRaisesRegex(RuntimeError, "incomplete ISR"):
                migration.expand()
            self.assertFalse(any(call.args[0] == "kafka-configs" for call in admin.call_args_list))


    def test_concurrent_journal_writer_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(action="migrate", state_dir=directory, timeout=30)
            first = HA.Migration(args)
            with self.assertRaisesRegex(RuntimeError, "Another process"):
                HA.Migration(args)
            first.lock.close()

    def test_unknown_resume_phase_fails_before_mutation(self):
        migration = HA.Migration(argparse.Namespace(action="verify", state_dir=None, timeout=30))
        migration.state = {"phase": "mysterious"}
        with patch.object(migration, "preflight"), patch.object(migration, "apply") as apply:
            with self.assertRaisesRegex(RuntimeError, "recognized migration checkpoint"):
                migration.migrate()
            apply.assert_not_called()

    def test_argo_patch_changes_only_the_owned_kafka_map(self):
        migration = HA.Migration(argparse.Namespace(action="verify", state_dir=None, timeout=30))
        app = {"metadata": {"name": "bm-cluster", "namespace": "infra"}, "spec": {"source": {"helm": {"valuesObject": {"postgresHa": {"enabled": True}}}}}}
        ha = HA.profile(CLUSTER_ID, "active")
        with patch.object(migration, "render", return_value=[]), patch.object(migration, "validate_images"), patch.object(migration, "checkpoint"), patch.object(migration, "get", return_value={"items": [app]}), patch.object(migration, "kube") as kube:
            migration.apply_profile(ha)
            mutation = next(call.args for call in kube.call_args_list if call.args[0] == "patch")
            body = json.loads(mutation[-1])
            self.assertEqual(body, {"spec": {"source": {"helm": {"valuesObject": {"kafkaHa": ha}}}}})


    def test_elr_write_policy_has_no_per_broker_minimum_isr(self):
        commands = HA.write_policy_commands(True)
        self.assertEqual(len(commands), 4)
        self.assertIn("--entity-default", commands[0])
        self.assertEqual(commands[0][-1], "min.insync.replicas=2,unclean.leader.election.enable=false")
        for command in commands[1:]:
            self.assertIn("--delete-config", command)
            self.assertEqual(command[-1], "unclean.leader.election.enable")
        for command in HA.write_policy_commands(False)[1:]:
            self.assertEqual(command[-1], "unclean.leader.election.enable,min.insync.replicas")



class Render(unittest.TestCase):
    def render(self, phase=None):
        command = ["helm", "template", "bm-cluster", str(ROOT / "k8s"), "--set", "publicDomain=example.com,internalDnsZone=internal.example.com,gitopsRepositoryURL=https://example.com/repo.git,cloudflareAccessTeamName=example"]
        if phase:
            command += ["--set", f"kafkaHa.enabled=true,kafkaHa.phase={phase},kafkaHa.clusterId={CLUSTER_ID},kafkaHa.bootstrap=false"]
        return [doc for doc in yaml.safe_load_all(subprocess.check_output(command)) if doc]

    def test_default_keeps_original_statefulsets_and_identity(self):
        documents = self.render()
        sts = [d for d in documents if d["kind"] == "StatefulSet" and d["metadata"]["name"] in {"kafka", "kafka-controller"}]
        self.assertEqual(len(sts), 2)
        for resource in sts:
            self.assertEqual(resource["spec"]["replicas"], 1)
            self.assertIn("KAFKA_CONTROLLER_QUORUM_VOTERS", {v["name"] for v in resource["spec"]["template"]["spec"]["containers"][0]["env"]})
        self.assertFalse(any(d["metadata"]["name"] == "kafka-ha-startup" for d in documents))

    def test_native_quorum_and_writer_policy_are_staged(self):
        for phase, replicas, minimum in [("dynamic", 1, "1"), ("expanded", 3, "1"), ("active", 3, "2")]:
            docs = self.render(phase)
            sts = [d for d in docs if d["kind"] == "StatefulSet" and d["metadata"]["name"] in {"kafka", "kafka-controller"}]
            for resource in sts:
                self.assertEqual(resource["spec"]["replicas"], replicas)
                spec = resource["spec"]["template"]["spec"]
                env = {v["name"]: v.get("value") for v in spec["containers"][0]["env"]}
                self.assertNotIn("KAFKA_CONTROLLER_QUORUM_VOTERS", env)
                self.assertEqual(env["CLUSTER_ID"], CLUSTER_ID)
                self.assertEqual(env["BM_KAFKA_ALLOW_INITIAL_FORMAT"], "false")
                self.assertEqual(env["KAFKA_CONTROLLER_QUORUM_AUTO_JOIN_ENABLE"], "false")
                self.assertEqual(spec["affinity"]["podAntiAffinity"]["requiredDuringSchedulingIgnoredDuringExecution"][0]["topologyKey"], "kubernetes.io/hostname")
                self.assertTrue(spec["containers"][0]["securityContext"]["readOnlyRootFilesystem"])
                if resource["metadata"]["name"] == "kafka":
                    self.assertEqual(env["KAFKA_MIN_INSYNC_REPLICAS"], minimum)
                    self.assertEqual(env["KAFKA_DEFAULT_REPLICATION_FACTOR"], str(replicas))
                    self.assertEqual(resource["spec"]["volumeClaimTemplates"][0]["metadata"]["name"], "kafka-data")
            budgets = [d for d in docs if d["kind"] == "PodDisruptionBudget" and d["metadata"]["name"] in {"kafka", "kafka-controller"}]
            self.assertEqual(len(budgets), 2 if phase == "active" else 0)


if __name__ == "__main__":
    unittest.main()
