#!/usr/bin/env python3
"""Offline guards against registering a platform/wrong target or leaking app access."""
import copy
import importlib.util
import json
import re
from pathlib import Path
import sys
import subprocess
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from lib.deployment_environments import application_hostname, effective_services, environment_context, load_inventory, uses_central_tls, validate_inventory

spec = importlib.util.spec_from_file_location("registration", ROOT / "scripts/configure-deployment-environments.py")
registration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registration)


class ApplicationClusterSafety(unittest.TestCase):
    def setUp(self):
        self.inventory = load_inventory(ROOT / "config/deployment-environments.remote.example.yaml")
        self.context = environment_context(self.inventory, "int")
        self.platform = {"uid": "platform-uid", "caHash": "platform-ca"}
        self.target = {"uid": "int-uid", "caHash": "int-ca", "caData": "public-ca"}

    def local_inventory(self):
        inventory = copy.deepcopy(self.inventory)
        inventory["platform"].pop("gateway")
        services = inventory["platform"]["services"]
        services["postgres"] = {"host": "postgres.infra.svc.cluster.local", "port": 5432}
        services["redis"] = {"host": "redis.infra.svc.cluster.local", "port": 6379}
        services["kafka"] = {"bootstrapServers": "kafka-0.kafka.infra.svc.cluster.local:9094", "securityProtocol": "SASL_PLAINTEXT",
            "brokers": [{"id": 0, "host": "kafka-0.kafka.infra.svc.cluster.local", "port": 9094}]}
        services["vault"] = {"url": "http://vault.infra.svc.cluster.local:8200"}
        services["registry"]["mirrorEndpoint"] = "http://gitlab-registry.infra.svc.cluster.local:5050"
        inventory["environments"] = {env: {"mode": "local", "ingressAddress": "203.0.113.10", "podCIDR": "10.42.0.0/16"} for env in ("int", "uat", "prod")}
        return validate_inventory(inventory)

    def test_local_targets_share_platform_identity_but_never_namespace(self):
        inventory = self.local_inventory()
        for env, target in inventory["environments"].items():
            self.assertEqual(target["server"], "https://kubernetes.default.svc")
            self.assertEqual(target["namespace"], "apps-" + env)
            self.assertEqual(target["secretStoreName"], "vault-backend-" + env)
            registration.identity_guard(self.platform, self.platform, env, {"prod": self.platform}, mode="local")
        with self.assertRaises(ValueError):
            registration.identity_guard(self.platform, self.target, "int", {}, mode="local")
        inventory["environments"]["uat"]["namespace"] = "apps-int"
        with self.assertRaisesRegex(ValueError, "distinct namespaces"):
            validate_inventory(inventory)

    def test_local_foundation_never_manages_platform_namespace_or_global_store(self):
        inventory = self.local_inventory()
        context = environment_context(inventory, "int")
        resources = registration.namespace_foundation(context)
        self.assertEqual([r["metadata"]["name"] for r in resources if r["kind"] == "Namespace"], ["apps-int"])
        self.assertFalse(any(r["metadata"].get("namespace") == "infra" for r in resources))
        self.assertTrue(any(r["kind"] == "ResourceQuota" for r in resources))
        self.assertTrue(any(r["kind"] == "LimitRange" for r in resources))
        deny = next(r for r in resources if r["kind"] == "NetworkPolicy" and r["metadata"]["name"] == "default-deny")
        self.assertEqual(deny["spec"]["policyTypes"], ["Ingress", "Egress"])
        stores = registration.vault_foundation(context, effective_services(inventory, "int"))
        store = next(r for r in stores if r["kind"] == "ClusterSecretStore")
        self.assertEqual(store["metadata"]["name"], "vault-backend-int")
        self.assertEqual(store["spec"]["conditions"], [{"namespaces": ["apps-int"]}])
        self.assertEqual(store["spec"]["provider"]["vault"]["auth"]["kubernetes"]["serviceAccountRef"]["name"], "external-secrets-int")

    def test_local_operator_credential_cannot_replace_argocd_platform_registration(self):
        context = environment_context(self.local_inventory(), "int")
        secret = registration.cluster_registration(context, {**self.platform, "caData": "ca", "server": "https://127.0.0.1:6443"}, "private")
        self.assertNotIn("argocd.argoproj.io/secret-type", secret["metadata"]["labels"])
        self.assertEqual(secret["stringData"]["apiServer"], "https://127.0.0.1:6443")
        self.assertEqual(secret["stringData"]["namespaces"], "apps-int")
        project = registration.argo_project(context, "example.com")["spec"]
        self.assertEqual(project["destinations"], [{"server": "https://kubernetes.default.svc", "namespace": "apps-int"}])
        self.assertTrue({"group": "networking.k8s.io", "kind": "NetworkPolicy"} in project["namespaceResourceBlacklist"])
        self.assertTrue({"group": "", "kind": "ResourceQuota"} in project["namespaceResourceBlacklist"])
        role = next(r for r in registration.argo_rbac(context) if r["kind"] == "Role")
        self.assertFalse(any("networkpolicies" in rule["resources"] for rule in role["rules"]))

    def test_mixed_inventory_requires_consistent_kafka_advertisement(self):
        local = self.local_inventory()
        mixed = copy.deepcopy(self.inventory)
        mixed["environments"]["int"] = local["environments"]["int"]
        with self.assertRaisesRegex(ValueError, "local target.services"):
            validate_inventory(mixed)
        mixed["environments"]["int"]["services"] = local["platform"]["services"]
        with self.assertRaisesRegex(ValueError, "advertised Kafka"):
            validate_inventory(mixed)
        mixed["environments"]["int"]["services"]["kafka"] = mixed["platform"]["services"]["kafka"]
        self.assertEqual(effective_services(validate_inventory(mixed), "int")["postgres"]["port"], 5432)

    def test_local_tokens_are_separate_and_rotation_does_not_revoke_peers(self):
        names = [registration.token_rotation_state(None, environment=env)[0] for env in ("int", "uat", "prod")]
        self.assertEqual(len(set(names)), 3)
        self.assertEqual(names[0], "platform-argocd-int-token")

    def test_local_namespace_names_cannot_claim_foundation(self):
        for namespace in ("infra", "apps", "kube-system", "corp", "gitlab-runners", "default"):
            inventory = self.local_inventory()
            inventory["environments"]["int"]["namespace"] = namespace
            with self.assertRaises(ValueError):
                validate_inventory(inventory)

    def test_environment_ingress_and_service_policies_fail_closed(self):
        context = environment_context(self.local_inventory(), "prod")
        ingress = registration.ingress_boundary(context)
        self.assertEqual(ingress[0]["spec"]["failurePolicy"], "Fail")
        expression = ingress[0]["spec"]["validations"][0]["expression"]
        self.assertIn("gitlab.example.com", expression)
        self.assertIn("!has(object.spec.defaultBackend)", expression)
        self.assertEqual(ingress[1]["spec"]["matchResources"]["namespaceSelector"]["matchLabels"], {"kubernetes.io/metadata.name": "apps-prod"})
        service = registration.service_boundary(context)
        self.assertIn("object.spec.type == 'ClusterIP'", service[0]["spec"]["validations"][0]["expression"])

    def test_local_bootstrap_refuses_before_remote_tools_or_host_mutations(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/install-application-cluster.sh"), "--config",
            str(ROOT / "config/deployment-environments.example.yaml"), "--environment", "int"],
            text=True, capture_output=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Local environments reuse the installed platform", result.stderr)
        self.assertNotIn("sudo", result.stderr)

    def test_local_registration_reuses_controllers_and_publishes_after_verification(self):
        inventory = self.local_inventory()
        context = environment_context(inventory, "int")
        args = SimpleNamespace(environment="int", config="inventory.yaml", tls_cert="existing.pem", tls_key="existing.key",
            vault_ca=None, vault_token_file="private-token", rotate_argocd_token=False)
        platform, target = Mock(), Mock()
        platform.path = target.path = "/private/platform.yaml"
        platform.get.return_value = None
        def target_get(kind, name=None, namespace=None, **kwargs):
            if kind == "nodes":
                return {"items": [{"spec": {"podCIDRs": ["10.42.0.0/24"]}, "status": {"conditions": [{"type": "Ready", "status": "True"}]}}]}
            if kind == "secret":
                return {"data": {"token": "c2NvcGVkLXRva2Vu"}}
            return {}
        target.get.side_effect = target_get
        identity = {**self.platform, "server": "https://127.0.0.1:6443", "caData": "Y2E="}
        with patch.object(registration, "run"), patch.object(registration, "private_token_file", return_value="private"), \
                patch.object(registration, "configure_vault"), patch.object(registration, "tls_secret"), \
                patch.object(registration, "probe") as probe, patch.object(registration, "helm_foundation") as helm, \
                patch.object(registration, "publish_registration") as publish, patch.object(Path, "read_text", return_value="certificate"):
            # The ingress policy loads public hostname defaults from the real repository.
            with patch.object(registration, "ingress_boundary", return_value=[]):
                registration.register_local(args, inventory, context, platform, target, identity)
            helm.assert_not_called()
            self.assertEqual(probe.call_count, 3)
            self.assertEqual(publish.call_count, 1)
            self.assertEqual(publish.call_args.args[4]["environments"]["int"]["namespace"], "apps-int")
        applied = [resource for call in target.apply.call_args_list for resource in (call.args[0] if isinstance(call.args[0], list) else [call.args[0]])]
        self.assertFalse(any(r["kind"] == "Namespace" and r["metadata"]["name"] == "infra" for r in applied))
        self.assertFalse(any(r["kind"] == "ClusterSecretStore" and r["metadata"]["name"] == "vault-backend" for r in applied))
        self.assertTrue(any(r["kind"] == "RoleBinding" and r["metadata"]["name"] == "application-observability-reader" for r in applied))

    def test_suffix_hostnames_preserve_one_wildcard_certificate_and_environment_boundaries(self):
        inventory = load_inventory(ROOT / "config/deployment-environments.example.yaml")
        expected = {"int": "devapp-int.example.com", "uat": "devapp-uat.example.com", "prod": "devapp.example.com"}
        for env, target in inventory["environments"].items():
            self.assertEqual(application_hostname(target, "devapp"), expected[env])
            self.assertEqual(application_hostname(target, "@"), "example.com" if env == "prod" else env + ".example.com")
            self.assertEqual(target["tlsSecretName"], "example-com-tls")
            policy = registration.ingress_boundary(environment_context(inventory, env))[0]["spec"]["validations"][0]["expression"]
            pattern = json.JSONDecoder().raw_decode(policy.split(".matches(", 1)[1])[0]
            self.assertIsNotNone(re.fullmatch(pattern, expected[env]))
            self.assertIsNotNone(re.fullmatch(pattern, application_hostname(target, "@")))
            if env != "prod":
                for hostname in ("devapp.example.com", "gitlab.example.com", "devapp.int.example.com"):
                    self.assertIsNone(re.fullmatch(pattern, hostname))
            else:
                self.assertIn('!r.host.endsWith("-int.example.com")', policy)
        target = inventory["environments"]["int"]
        with self.assertRaisesRegex(ValueError, "one DNS label"):
            application_hostname(target, "x" * 63)

    def test_partial_mixed_publication_keeps_shared_endpoint_contract(self):
        mixed = copy.deepcopy(self.inventory)
        local = self.local_inventory()
        mixed["environments"]["int"] = local["environments"]["int"]
        mixed["environments"]["int"]["services"] = local["platform"]["services"]
        mixed["environments"]["int"]["services"]["kafka"] = mixed["platform"]["services"]["kafka"]
        partial = registration.publish_inventory(None, validate_inventory(mixed), "int")
        self.assertEqual(set(partial["environments"]), {"int"})
        self.assertEqual(effective_services(partial, "int")["postgres"]["port"], 5432)

    def test_suffix_tls_uses_platform_store_without_exposing_shared_key_to_app_namespaces(self):
        inventory = load_inventory(ROOT / "config/deployment-environments.example.yaml")
        for env in inventory["environments"]:
            context = environment_context(inventory, env)
            self.assertTrue(context["centralTLS"])
            self.assertTrue(uses_central_tls(context))
            tls_rule = registration.ingress_boundary(context)[0]["spec"]["validations"][1]["expression"]
            self.assertIn("!has(t.secretName)", tls_rule)
            self.assertNotIn("t.secretName ==", tls_rule)
        self.assertFalse(uses_central_tls(self.context))
        context = environment_context(inventory, "int")
        target = Mock()
        target.get.return_value = {"data": {"tls.crt": "Y2VydGlmaWNhdGU=", "tls.key": "Y2VydGlmaWNhdGU="}}
        with patch.object(Path, "read_bytes", return_value=b"certificate"), patch.object(registration, "run", return_value="public-key"):
            registration.tls_secret(target, context, "certificate.pem", "key.pem")
        target.get.assert_called_once_with("secret", "example-com-tls", "infra", optional=True)
        target.apply.assert_not_called()

    def test_mixed_gateway_admits_local_pods_only_to_authenticated_kafka(self):
        mixed = copy.deepcopy(self.inventory)
        local = self.local_inventory()
        mixed["environments"]["int"] = local["environments"]["int"]
        mixed["environments"]["int"]["services"] = local["platform"]["services"]
        mixed["environments"]["int"]["services"]["kafka"] = mixed["platform"]["services"]["kafka"]
        mixed = validate_inventory(mixed)
        resources = registration.gateway_resources(mixed, "platform")
        config = resources[0]["data"]["nginx.conf"]
        postgres_listener = config.split("server { listen 10432;", 1)[1].split("  }", 1)[0]
        kafka_listener = config.split("server { listen 10940;", 1)[1].split("  }", 1)[0]
        self.assertNotIn("allow 10.42.0.0/16;", postgres_listener)
        self.assertIn("allow 10.42.0.0/16;", kafka_listener)
        policy = next(r for r in resources if r["kind"] == "NetworkPolicy")
        local_rule = policy["spec"]["ingress"][-1]
        self.assertEqual(local_rule["ports"], [{"protocol": "TCP", "port": 10940}])
        self.assertEqual(local_rule["from"][0]["namespaceSelector"]["matchExpressions"][0]["values"], ["apps-int"])
        context = environment_context(mixed, "int")
        context.update(gatewayAddress="100.100.0.10", gatewayPorts=[30940])
        foundation = registration.namespace_foundation(context)
        egress = next(r for r in foundation if r["metadata"]["name"] == "application-connectivity")["spec"]["egress"]
        self.assertEqual(egress[-1]["ports"], [{"protocol": "TCP", "port": 10940}])
        platform = Mock()
        nodes = [{"metadata": {"name": "platform", "labels": {"kubernetes.io/hostname": "platform"}},
            "status": {"addresses": [{"address": "100.100.0.10", "type": "InternalIP"}]}}]
        with patch.object(registration, "probe") as probe:
            registration.prepare_mixed_gateway(platform, mixed, nodes)
        self.assertEqual(probe.call_count, 1)
        self.assertEqual(probe.call_args.args[3]["localAddress"], "100.100.0.10")
        platform.call.assert_called_with("rollout", "status", "deployment/application-service-gateway", "-n", "infra", "--timeout=180s")

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
        store = next(resource for resource in resources if resource["kind"] == "ClusterSecretStore")["spec"]
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
        self.assertIn("http://gitlab.internal.example.com/**", project["sourceRepos"])
        self.assertIn("https://gitlab.example.com/**", project["sourceRepos"])
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
