#!/usr/bin/env python3
"""Offline guards against registering a platform/wrong target or leaking app access."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from lib.deployment_environments import environment_context, load_inventory, validate_inventory

spec = importlib.util.spec_from_file_location("registration", ROOT / "scripts/configure-deployment-environments.py")
registration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registration)


class ApplicationClusterSafety(unittest.TestCase):
    def setUp(self):
        self.inventory = load_inventory(ROOT / "config/deployment-environments.example.yaml")
        self.context = environment_context(self.inventory, "int")
        self.platform = {"uid": "platform-uid", "caHash": "platform-ca"}
        self.target = {"uid": "int-uid", "caHash": "int-ca", "caData": "public-ca"}

    def test_central_cluster_and_cloned_ca_are_refused(self):
        for target in (self.platform, {**self.target, "caHash": "platform-ca"}):
            with self.assertRaises(ValueError):
                registration.identity_guard(self.platform, target, "int", {})

    def test_one_cluster_cannot_be_two_environments(self):
        for duplicate in ({**self.target, "caHash": "different-ca"}, {**self.target, "uid": "different-uid"}):
            with self.assertRaises(ValueError):
                registration.identity_guard(self.platform, self.target, "int", {"prod": duplicate})

    def test_registered_identity_cannot_be_replaced(self):
        with self.assertRaises(ValueError):
            registration.identity_guard(self.platform, self.target, "int", {"int": {"uid": "old-uid", "caHash": "old-ca"}})
        registration.identity_guard(self.platform, self.target, "int", {"int": self.target})

    def test_vault_grants_only_selected_environment_and_registry(self):
        for environment in ("int", "uat", "prod"):
            policy = registration.vault_policy(environment)
            self.assertIn(f'secret/data/apps/+/{environment}/*', policy)
            self.assertIn('secret/data/apps/+/registry', policy)
            self.assertNotIn('infra/', policy)
            self.assertNotIn('"write"', policy)
            for other in {"int", "uat", "prod"} - {environment}:
                self.assertNotIn(f'/{other}/', policy)

    def test_remote_vault_tokens_are_scoped_and_rotatable(self):
        resources = registration.vault_foundation(self.context, self.inventory["platform"]["services"])
        store = resources[1]["spec"]
        self.assertEqual(store["conditions"], [{"namespaces": ["apps"]}])
        auth = store["provider"]["vault"]["auth"]["kubernetes"]
        self.assertEqual(auth["mountPath"], "kubernetes-int")
        self.assertEqual(auth["serviceAccountRef"]["audiences"], ["vault", registration.API_AUDIENCE])
        self.assertNotIn("secretRef", auth)

    def test_failed_inventory_publication_resumes_old_token_revocation(self):
        platform, target = Mock(), Mock()
        old = {"metadata": {"annotations": {registration.TOKEN_SECRET_ANNOTATION: "platform-argocd-token"}}}
        active, pending = registration.token_rotation_state(old, rotate=True)
        document = registration.cluster_registration(self.context, self.target, "replacement")
        current = {"metadata": {"resourceVersion": "10"}}
        updated = registration.publish_inventory(None, self.inventory, "int")
        platform.call.side_effect = RuntimeError("concurrent inventory update")
        with self.assertRaisesRegex(RuntimeError, "concurrent inventory"):
            registration.publish_registration(platform, target, document, current, updated, active, pending)
        target.call.assert_not_called()
        persisted = platform.apply.call_args.args[0]
        resumed_active, resumed_pending = registration.token_rotation_state(persisted)
        self.assertEqual(resumed_active, active)
        self.assertEqual(resumed_pending, ["platform-argocd-token"])
        platform.call.side_effect = None
        target.get.return_value = {"type": "kubernetes.io/service-account-token", "metadata": {
            "annotations": {"kubernetes.io/service-account.name": "platform-argocd"}}}
        registration.publish_registration(platform, target, document, current, updated, resumed_active, resumed_pending)
        target.call.assert_called_once_with("delete", "secret", "platform-argocd-token", "-n", "infra", "--ignore-not-found")
        operations = json.loads(platform.call.call_args.args[-1])
        self.assertEqual(operations[0]["value"], active)
        self.assertEqual(operations[-1]["value"], "[]")

    def test_repeated_rotation_preserves_outstanding_revocations(self):
        old = {"metadata": {"annotations": {
            registration.TOKEN_SECRET_ANNOTATION: "platform-argocd-token-12345678",
            registration.PENDING_TOKENS_ANNOTATION: '["platform-argocd-token"]'}}}
        active, pending = registration.token_rotation_state(old, rotate=True)
        self.assertEqual(pending, ["platform-argocd-token", "platform-argocd-token-12345678"])
        self.assertNotIn(active, pending)
        old["metadata"]["annotations"][registration.PENDING_TOKENS_ANNOTATION] = '["platform-argocd-token-12345678"]'
        with self.assertRaisesRegex(ValueError, "active Argo credential"):
            registration.token_rotation_state(old)

    def test_failed_revocation_keeps_journal_for_retry(self):
        platform, target = Mock(), Mock()
        target.get.return_value = {"type": "kubernetes.io/service-account-token", "metadata": {
            "annotations": {"kubernetes.io/service-account.name": "platform-argocd"}}}
        target.call.side_effect = RuntimeError("temporary target outage")
        document = registration.cluster_registration(self.context, self.target, "replacement")
        updated = registration.publish_inventory(None, self.inventory, "int")
        with self.assertRaisesRegex(RuntimeError, "target outage"):
            registration.publish_registration(platform, target, document, None, updated, "platform-argocd-token-12345678", ["platform-argocd-token"])
        self.assertEqual(platform.call.call_count, 1)
        self.assertEqual(registration.token_rotation_state(platform.apply.call_args.args[0])[1], ["platform-argocd-token"])

    def test_argo_app_principal_cannot_manage_foundation(self):
        resources = registration.argo_rbac()
        role = next(resource for resource in resources if resource["kind"] == "Role")
        self.assertEqual(role["metadata"]["namespace"], "apps")
        self.assertTrue(any(rule["apiGroups"] == ["traefik.io"] and rule["resources"] == ["middlewares", "serverstransports"]
                            for rule in role["rules"]))
        for rule in role["rules"]:
            self.assertNotIn("rbac.authorization.k8s.io", rule["apiGroups"])
            self.assertNotIn("serviceaccounts/token", rule["resources"])
            self.assertNotIn("clustersecretstores", rule["resources"])
            self.assertNotIn("*", rule["resources"])
        cluster_role = next(resource for resource in resources if resource["kind"] == "ClusterRole")
        for rule in cluster_role["rules"]:
            self.assertLessEqual(set(rule["verbs"]), {"get", "list", "watch"})

    def test_argo_registration_keeps_tokens_out_of_public_inventory(self):
        secret = registration.cluster_registration(self.context, self.target, "sensitive-test-value")
        config = json.loads(secret["stringData"]["config"])
        self.assertFalse(config["tlsClientConfig"]["insecure"])
        self.assertEqual(secret["stringData"]["namespaces"], "apps")
        self.assertEqual(secret["stringData"]["clusterResources"], "false")
        self.assertEqual(secret["stringData"]["project"], "applications-int")
        project = registration.argo_project(self.context, "example.com", "internal.example.com")["spec"]
        self.assertIn("http://gitlab.internal.example.com/*", project["sourceRepos"])
        self.assertEqual(project["destinations"], [{"server": self.context["server"], "namespace": "apps"}])
        self.assertEqual(project["clusterResourceWhitelist"], [])
        public = registration.publish_inventory(None, self.inventory, "int")
        self.assertNotIn("sensitive-test-value", json.dumps(public))
        self.assertNotIn("uid", public["environments"]["int"])

    def test_publish_only_ready_selected_targets_and_preserve_peers(self):
        initial = registration.publish_inventory(None, self.inventory, "int")
        self.assertEqual(set(initial["environments"]), {"int"})
        second = registration.publish_inventory(initial, self.inventory, "uat")
        self.assertEqual(set(second["environments"]), {"int", "uat"})
        self.assertEqual(second["environments"]["int"], initial["environments"]["int"])
        changed = copy.deepcopy(self.inventory)
        changed["platform"]["services"]["registry"]["mirrorEndpoint"] = "http://100.100.0.10:30501"
        with self.assertRaises(ValueError):
            registration.publish_inventory(initial, changed, "prod")

    def test_node_allocations_cannot_cross_environment_boundaries(self):
        for source in (self.inventory["environments"]["prod"]["nodeCIDRs"], self.inventory["platform"]["gateway"]["nodeCIDRs"], ["100.64.0.0/10"]):
            changed = copy.deepcopy(self.inventory)
            changed["environments"]["int"]["nodeCIDRs"] = source
            with self.assertRaises(ValueError):
                validate_inventory(changed)

    def test_gateway_preserves_source_and_denies_unallocated_clients(self):
        resources = registration.gateway_resources(self.inventory, "platform-gateway")
        config = resources[0]["data"]["nginx.conf"]
        self.assertNotIn("allow all", config)
        self.assertNotIn("0.0.0.0/0", config)
        for target in self.inventory["environments"].values():
            for cidr in target["nodeCIDRs"]:
                self.assertIn("allow " + cidr + ";", config)
        services = [resource for resource in resources if resource["kind"] == "Service"]
        self.assertTrue(services)
        self.assertTrue(all(service["spec"]["externalTrafficPolicy"] == "Local" for service in services))
        self.assertIn("kafka-0.kafka.infra.svc.cluster.local:9094", config)
        self.assertNotIn("kafka.infra.svc.cluster.local:9092", config)

    def test_gateway_ports_and_plaintext_listener_contract_fail_closed(self):
        changed = copy.deepcopy(self.inventory)
        changed["platform"]["services"]["redis"]["port"] = changed["platform"]["services"]["postgres"]["port"]
        with self.assertRaises(ValueError):
            registration.gateway_routes(changed)
        changed["platform"]["services"]["redis"]["port"] = 6379
        with self.assertRaises(ValueError):
            registration.gateway_routes(changed)

    def test_gateway_can_select_private_secondary_interface_node(self):
        self.inventory["platform"]["gateway"]["nodeName"] = "platform-cp-01"
        self.assertEqual(validate_inventory(self.inventory)["platform"]["gateway"]["nodeName"], "platform-cp-01")
        self.inventory["platform"]["gateway"]["nodeName"] = "../../other"
        with self.assertRaises(ValueError):
            validate_inventory(self.inventory)

    def test_unconfigured_tls_datastore_modes_are_rejected(self):
        for service in ("postgres", "redis", "kafka"):
            changed = copy.deepcopy(self.inventory)
            if service == "kafka":
                changed["platform"]["services"][service]["securityProtocol"] = "SASL_SSL"
            else:
                changed["platform"]["services"][service]["tls"] = True
            with self.assertRaises(ValueError):
                validate_inventory(changed)


if __name__ == "__main__":
    unittest.main()
