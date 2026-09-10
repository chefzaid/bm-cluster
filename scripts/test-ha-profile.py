#!/usr/bin/env python3
"""HA reconciliation must never reactivate the original writable database."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ha_profile", ROOT / "scripts/resolve-ha-profile.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
PG = {"enabled": True, "active": True, "bootstrapOwner": "admin", "bootstrapDatabase": "appdb",
      "storageSize": "2Gi", "image": "example/immutable-image@sha256:" + "1" * 64}
STATE = {"phase": "active", "postgresHa": json.dumps(PG)}
KAFKA = {"enabled": True, "phase": "active", "clusterId": "fixture", "bootstrap": False}
KAFKA_STATE = {"phase": "active", "kafkaHa": json.dumps(KAFKA)}


class ProfileTest(unittest.TestCase):
    def test_normal_render_provides_complete_values_for_staged_migrations(self):
        with tempfile.TemporaryDirectory(prefix="bm-normal-profile-test.") as directory:
            env = {**os.environ, "HIGH_AVAILABILITY_ENABLED": "false", "PLATFORM_HA_VALUES_FILE": "", "SECURITY_IMAGES_ENABLED": "false"}
            subprocess.run([str(ROOT / "scripts/render-cluster-config.sh"), "--output", directory,
                "--domain", "example.test", "--internal-domain", "internal.example.test",
                "--gitops-repository", "https://example.test/platform.git", "--cloudflare-access-team", "fixture"],
                env=env, check=True, capture_output=True, text=True)
            values = yaml.safe_load((Path(directory) / "k8s/values.yaml").read_text())
            self.assertEqual(values['publicDomain'], 'example.test')
            self.assertEqual(values['internalDnsZone'], 'internal.example.test')
            self.assertEqual(values['gitopsRepositoryURL'], 'https://example.test/platform.git')
            self.assertEqual(values['cloudflareAccessTeamName'], 'fixture')
            self.assertFalse(values['highAvailabilityEnabled'])

    def test_single_server_default(self):
        self.assertEqual(profile.resolve({}, {}, ""), {"highAvailabilityEnabled": False})

    def test_postgres_cutover_is_preserved_before_ingress_ha_activation(self):
        result = profile.resolve({}, STATE, "", kafka=KAFKA_STATE)
        self.assertEqual(result["postgresHa"], PG)
        self.assertFalse(result["highAvailabilityEnabled"])

    def test_inherit_existing_ha_on_surviving_control_plane(self):
        result = profile.resolve({"highAvailabilityEnabled": "true"}, STATE, "", kafka=KAFKA_STATE)
        self.assertTrue(result["highAvailabilityEnabled"])
        self.assertEqual(result["postgresHa"], PG)

    def test_cannot_enable_ha_with_singleton_postgres(self):
        with self.assertRaisesRegex(ValueError, "PostgreSQL HA"):
            profile.resolve({}, {}, "true")

    def test_partial_cutover_blocks_installer_including_default_mode(self):
        for mode in ("", "false", "true"):
            with self.assertRaisesRegex(ValueError, "unfinished"):
                profile.resolve({}, {"phase": "cutover-started"}, mode)

    def test_reject_downgrade_and_different_database_identity(self):
        with self.assertRaisesRegex(ValueError, "downgrade"):
            profile.resolve({"highAvailabilityEnabled": "true"}, STATE, "false")
        with self.assertRaisesRegex(ValueError, "differs"):
            profile.resolve({}, STATE, "true", {"postgresHa": {**PG, "bootstrapOwner": "other"}})

    def test_reject_invalid_mode_even_if_it_looks_truthy(self):
        for mode in ("yes", "1", "TRUE"):
            with self.assertRaises(ValueError):
                profile.resolve({}, {}, mode)

    def test_kafka_cutover_is_preserved_before_global_ha(self):
        result = profile.resolve({}, {}, "", kafka=KAFKA_STATE)
        self.assertEqual(result["kafkaHa"], KAFKA)
        self.assertFalse(result["highAvailabilityEnabled"])

    def test_kafka_quorum_and_finished_migration_are_required(self):
        for state in ({}, {"phase": "expanded"},
                      {"phase": "active", "kafkaHa": json.dumps({**KAFKA, "bootstrap": True})}):
            with self.subTest(state=state), self.assertRaisesRegex(ValueError, "Kafka"):
                profile.resolve({}, STATE, "true", kafka=state)

    def test_fencing_inventory_survives_reruns_and_requires_explicit_opt_in(self):
        fencing = {"enabled": True, "inventorySecret": "node-fencing-inventory", "nodeNames": ["node-a"]}
        result = profile.resolve({}, STATE, "true", kafka=KAFKA_STATE, previous={"nodeFencing": fencing})
        self.assertEqual(result["nodeFencing"], fencing)
        disabled = profile.resolve({}, STATE, "true", {"nodeFencing": {"enabled": False}},
                                   kafka=KAFKA_STATE, previous={"nodeFencing": fencing})
        self.assertEqual(disabled["nodeFencing"], {"enabled": False})
        with self.assertRaisesRegex(ValueError, "explicit nodeNames"):
            profile.resolve({}, STATE, "true", {"nodeFencing": {"enabled": True}}, kafka=KAFKA_STATE)

    def test_install_and_gitops_render_the_same_migrated_services_and_profiles(self):
        fencing = {"enabled": True, "inventorySecret": "fixture-inventory", "nodeNames": ["fixture-node"]}
        desired = {"postgresHa": PG, "kafkaHa": {**KAFKA, "clusterId": "MkU3OEVBNTcwNTJENDM2Qk"},
                   "nodeFencing": fencing}
        for enabled in (False, True):
            with self.subTest(ha=enabled), tempfile.TemporaryDirectory(prefix="bm-ha-profile-test.") as directory:
                directory = Path(directory)
                values = directory / "profile.json"
                values.write_text(json.dumps(desired))
                rendered = directory / "rendered"
                env = {**os.environ, "HIGH_AVAILABILITY_ENABLED": str(enabled).lower(),
                       "PLATFORM_HA_VALUES_FILE": str(values), "SECURITY_IMAGES_ENABLED": "false"}
                subprocess.run([str(ROOT / "scripts/render-cluster-config.sh"), "--output", str(rendered),
                    "--domain", "example.test", "--internal-domain", "internal.example.test",
                    "--gitops-repository", "https://example.test/platform.git", "--cloudflare-access-team", "fixture"],
                    env=env, check=True, capture_output=True, text=True)
                def documents(path):
                    return {(d["kind"], d["metadata"]["name"]): d for d in yaml.safe_load_all(path.read_text()) if d}
                pg = documents(rendered / "k8s/datastores/postgres.yaml")
                self.assertEqual(pg["Deployment", "postgres"]["spec"]["replicas"], 0)
                self.assertEqual(pg["Service", "postgres"]["spec"]["selector"]["cnpg.io/cluster"], "postgres-ha")
                kafka = documents(rendered / "k8s/datastores/kafka.yaml")
                for name in ("kafka-controller", "kafka"):
                    self.assertEqual(kafka["StatefulSet", name]["spec"]["replicas"], 3)
                app = documents(rendered / "k8s/addons/bm-cluster-application.yaml")["Application", "bm-cluster"]
                self.assertEqual(app["spec"]["source"]["helm"]["valuesObject"],
                                 {**desired, "highAvailabilityEnabled": enabled})
                extra = documents(rendered / "k8s/ha/platform.yaml")
                self.assertEqual(("StatefulSet", "shared-redis-ha-server") in extra, enabled)
                self.assertEqual(("MutatingAdmissionPolicy", "bm-coredns-availability") in extra, enabled)
                self.assertEqual(("CronJob", "node-fencing") in extra, enabled)
                self.assertIn(("ConfigMap", "kafka-ha-startup"), extra)
                self.assertIn(("PodDisruptionBudget", "kafka"), extra)
                self.assertIn(("Cluster", "postgres-ha"), extra)
                self.assertFalse(any((d["metadata"].get("annotations") or {}).get("helm.sh/hook", "").startswith("test") for d in extra.values()))
                if enabled:
                    for key, namespace in ((('StatefulSet', 'shared-redis-ha-server'), 'infra'),
                                           (('PodDisruptionBudget', 'coredns'), 'kube-system'),
                                           (('Role', 'bm-node-fencing-leases'), 'kube-node-lease')):
                        self.assertEqual(extra[key]['metadata']['namespace'], namespace)


if __name__ == "__main__":
    unittest.main()
