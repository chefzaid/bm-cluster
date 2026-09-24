#!/usr/bin/env python3
"""Prevent cross-environment onboarding, pointer verification and DNS certificate mistakes."""
import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
from deployment_environments import load_inventory, validate_inventory, environment_context
from environment_onboarding import EnvironmentOnboarding, EnvironmentServices, repository_permitted
from repository_onboarding import OnboardingError
from onboarding_services import ServiceError
from application_delivery import ApplicationDelivery
spec = importlib.util.spec_from_file_location("application_dns", ROOT / "scripts/configure-application-dns.py")
dns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dns)

INVENTORY = load_inventory(ROOT / "config/deployment-environments.remote.example.yaml")
CONTEXT = {"PUBLIC_DOMAIN":"example.com", "INTERNAL_DNS_ZONE":"internal.example.com", "KEYCLOAK_REALM":"example",
           "APPLICATION_NAME":"devapp", "APP_SUBDOMAIN":"portal", "APP_HOST":"portal.example.com",
           "GITLAB_REPOSITORY_URL":"http://gitlab.internal.example.com/team/devapp.git",
           "GITLAB_PROJECT_ID":"7", "GITLAB_PROJECT_PATH":"team/devapp"}
CONTRACT = {"application":"infra/argocd/application.yaml", "deployment":{"inventory":"infra/deployment-environments.json",
            "settingsDirectory":"infra/environments", "defaultEnvironment":"int"}}
TEMPLATE = {"apiVersion":"argoproj.io/v1alpha1", "kind":"Application", "metadata":{"name":"devapp","namespace":"infra"},
            "spec":{"project":"applications", "destination":{"server":"https://kubernetes.default.svc","namespace":"apps"},
                    "source":{"repoURL":CONTEXT["GITLAB_REPOSITORY_URL"],"path":"infra/k8s","targetRevision":"main"}}}

def local_inventory(hostname_style="nested"):
    inventory = copy.deepcopy(INVENTORY)
    inventory["platform"].pop("gateway", None)
    inventory["platform"]["hostnameStyle"] = hostname_style
    services = inventory["platform"]["services"]
    services["postgres"] = {"host": "postgres.infra.svc.cluster.local", "port": 5432}
    services["redis"] = {"host": "redis.infra.svc.cluster.local", "port": 6379}
    services["kafka"] = {"bootstrapServers": "kafka-0.kafka.infra.svc.cluster.local:9094",
                         "securityProtocol": "SASL_PLAINTEXT", "brokers": [{"id": 0, "host": "kafka-0.kafka.infra.svc.cluster.local", "port": 9094}]}
    services["vault"] = {"url": "http://vault.infra.svc.cluster.local:8200"}
    for env in inventory["environments"]:
        inventory["environments"][env] = {"mode": "local", "ingressAddress": "203.0.113.10", "podCIDR": "10.42.0.0/16"}
    return validate_inventory(inventory)


class Platform:
    api = object()
    def __init__(self):
        self.inventory = copy.deepcopy(INVENTORY)
        self.insecure = False
        self.registration_type = None
        self.api_server = "https://127.0.0.1:6443"
    def kubectl(self, *args):
        if args[:2] == ("config", "view"):
            return {"clusters": [{"cluster": {"server": "https://127.0.0.1:6443"}}]}
        if args[1] == "configmap":
            return {"data":{"environments.json":json.dumps(self.inventory)}}
        env = args[2].removeprefix("application-cluster-")
        target = self.inventory["environments"][env]
        data = {"name":target["clusterName"],"server":target["server"],"namespaces":target["namespace"],"clusterResources":"false",
                "project":"applications-"+env,"config":json.dumps({"bearerToken":"fixture-token",
                 "tlsClientConfig":{"insecure":self.insecure,"caData":"Zml4dHVyZS1jYQ=="}})}
        labels = {"bm-cluster.io/application-environment": env}
        if target.get("mode", "remote") == "local":
            data["apiServer"] = self.api_server
        else:
            labels["argocd.argoproj.io/secret-type"] = "cluster"
        if self.registration_type:
            labels["argocd.argoproj.io/secret-type"] = self.registration_type
        return {"metadata":{"labels":labels}, "data":{k:base64.b64encode(v.encode()).decode() for k,v in data.items()}}

class Checkout:
    def __init__(self, root): self.root = root
    def git(self, *args):
        if args[0] == "show": return yaml.safe_dump(self.pointer)
        if args[:2] == ("merge-base", "--is-ancestor"): return ""
        raise AssertionError(args)

class OnboardingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "infra/argocd").mkdir(parents=True)
        (self.root / CONTRACT["application"]).write_text(yaml.safe_dump(TEMPLATE))
        self.checkout, self.platform = Checkout(self.root), Platform()
    def manager(self):
        with patch.dict(os.environ, {"ONBOARDING_DEPLOYMENT_ENVIRONMENT":"int"}):
            return EnvironmentOnboarding(self.platform, self.checkout, CONTRACT, CONTEXT)
    def test_repository_rules_match_argocd_slash_globs_and_denials(self):
        repository = "http://gitlab.internal.example.com/team/devapp.git"
        self.assertFalse(repository_permitted(["http://gitlab.internal.example.com/*"], repository))
        self.assertTrue(repository_permitted(["http://gitlab.internal.example.com/**"], repository))
        self.assertTrue(repository_permitted(["http://gitlab.internal.example.com/*/*"], repository))
        self.assertTrue(repository_permitted([repository.removesuffix(".git").upper()], repository))
        nested = "http://gitlab.internal.example.com/team/subgroup/devapp.git"
        self.assertTrue(repository_permitted(["http://gitlab.internal.example.com/**"], nested))
        self.assertFalse(repository_permitted(["http://gitlab.internal.example.com/*/*"], nested))
        self.assertFalse(repository_permitted(["http://gitlab.internal.example.com/**", "!http://gitlab.internal.example.com/team/**"], nested))
        self.assertFalse(repository_permitted(["https://gitlab.example.com/**"], repository))
        self.assertFalse(repository_permitted(["http://gitlab.internal.example.com/**"], "http://gitlab.internal.example.com.attacker.test/team/devapp.git"))
        self.assertTrue(repository_permitted(["*"], repository))

    def test_public_inventory_never_contains_registration_credentials(self):
        manager = self.manager()
        for path in manager.paths:
            self.assertNotIn("fixture-token", (self.root/path).read_text())
        for env in ("int","uat","prod"):
            settings = json.loads((self.root/f"infra/environments/{env}/settings.json").read_text())
            self.assertEqual(settings["appSubdomain"],"portal")
            self.assertEqual(settings["trustedProxyCIDRs"],INVENTORY["environments"][env]["podCIDR"])
        with manager.target_kubeconfig("uat") as path:
            config = json.loads(Path(path).read_text())
            self.assertEqual(Path(path).stat().st_mode & 0o777,0o600)
            self.assertEqual(config["clusters"][0]["cluster"]["server"],INVENTORY["environments"]["uat"]["server"])
        self.assertFalse(Path(path).exists())
    def test_local_targets_keep_separate_namespaces_and_scoped_operator_credentials(self):
        self.platform.inventory = local_inventory()
        manager = self.manager()
        self.assertEqual(manager.application(TEMPLATE)["spec"]["destination"], {"name": "in-cluster", "namespace": "apps-int"})
        for env in ("int", "uat", "prod"):
            with manager.target_kubeconfig(env) as path:
                config = json.loads(Path(path).read_text())
            self.assertEqual(config["contexts"][0]["context"]["namespace"], "apps-" + env)
            self.assertEqual(config["clusters"][0]["cluster"]["server"], "https://127.0.0.1:6443")
            self.assertEqual(config["users"][0]["user"], {"token": "fixture-token"})
        self.platform.registration_type = "cluster"
        with self.assertRaisesRegex(OnboardingError, "built-in"):
            self.manager()
        self.platform.registration_type = None
        self.platform.api_server = "https://another.example.com:6443"
        with self.assertRaisesRegex(OnboardingError, "another platform endpoint"):
            self.manager()

    def test_registration_requires_verified_tls_and_stable_saved_targets(self):
        self.manager()
        self.platform.insecure=True
        with self.assertRaises(OnboardingError): self.manager()
        self.platform.insecure=False
        self.platform.inventory["environments"]["int"]["server"]="https://100.100.10.20:6443"
        with self.assertRaises(OnboardingError): self.manager()
    def test_nonselected_environment_blocks_shared_hostname_change_before_writes(self):
        settings = self.root / "infra/environments/prod/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"appSubdomain": "existing-prod"}))
        before = {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        with self.assertRaisesRegex(OnboardingError, "prod.*explicit hostname migration"):
            self.manager()
        self.assertEqual(before, {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()})
    def test_same_label_rerun_preserves_existing_target_settings(self):
        self.manager()
        path = self.root / "infra/environments/prod/settings.json"
        settings = json.loads(path.read_text())
        settings.update(trustedProxyCIDRs="10.60.0.0/16", highAvailability=True, databaseName="devappdb")
        path.write_text(json.dumps(settings))
        self.manager()
        self.assertEqual(settings, json.loads(path.read_text()))
    def test_only_selected_pointer_and_ancestor_runtime_revision_are_accepted(self):
        manager=self.manager()
        pointer=manager.application(TEMPLATE)
        pointer["spec"]["source"]["targetRevision"]="a"*40
        self.checkout.pointer=pointer
        actual=manager.release_application(self.checkout,"b"*40)
        self.assertEqual(actual["spec"]["source"]["targetRevision"],"a"*40)
        self.checkout.pointer["spec"]["destination"]["name"]="apps-prod"
        with self.assertRaises(OnboardingError): manager.release_application(self.checkout,"b"*40)
    def test_keycloak_clients_share_realm_with_distinct_audiences_and_callbacks(self):
        original={"clientId":"devapp-web","rootUrl":"https://portal.example.com","redirectUris":["https://portal.example.com/*"],
                  "webOrigins":["https://portal.example.com"],"attributes":{"post.logout.redirect.uris":"+"},
                  "protocolMappers":[{"protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"devapp-web"}}]}
        manager=self.manager()
        for env,target in manager.targets.items():
            with patch("onboarding_services.Services._client",return_value=("example",copy.deepcopy(original))):
                service=EnvironmentServices(object(),self.platform.kubectl,CONTEXT,target=target)
                realm,client=service._client({},self.root)
            self.assertEqual(realm,"example")
            self.assertEqual(client["clientId"],"devapp-"+env+"-web")
            self.assertEqual(client["protocolMappers"][0]["config"]["included.client.audience"],client["clientId"])
            self.assertEqual(client["webOrigins"],["https://portal."+target["domain"]])
        suffix = local_inventory("suffix")
        for env in ("int", "uat", "prod"):
            target = environment_context(suffix, env)
            with patch("onboarding_services.Services._client", return_value=("example", copy.deepcopy(original))):
                service = EnvironmentServices(object(), self.platform.kubectl, CONTEXT, target=target)
                _, client = service._client({}, self.root)
            expected = "https://portal" + ("" if env == "prod" else "-" + env) + ".example.com"
            self.assertEqual(client["webOrigins"], [expected])
            self.assertEqual(client["redirectUris"], [expected + "/*"])

class CertificateTests(unittest.TestCase):
    def test_valid_public_origin_certificate_is_preserved(self):
        commands = []
        def openssl(arguments, **_kwargs):
            commands.append(arguments)
            if "-CAfile" in arguments:
                raise ServiceError("Not a Cloudflare-origin certificate")
            return "public-key" if "-pubkey" in arguments or "-pubout" in arguments else ""
        with patch.object(dns, "run", side_effect=openssl):
            self.assertTrue(dns.certificate_valid(Path("/fixture"), "int.example.com"))
        self.assertTrue(any("-untrusted" in command for command in commands))

    def test_certificate_preparation_does_not_move_or_require_existing_dns(self):
        calls = []
        class API:
            def request(self, method, path, data):
                calls.append((method, path))
                if path.startswith("/zones?"):
                    return {"success": True, "result": [{"id": "zone"}]}
                raise AssertionError("Certificate-only preparation must not inspect or change DNS")
        def kubectl(arguments, **_kwargs):
            if "view" in arguments:
                return json.dumps({"clusters": [{"cluster": {"server": INVENTORY["environments"]["int"]["server"]}}]})
            if "namespace" in arguments:
                return json.dumps({"metadata": {"labels": {"bm-cluster.io/application-environment": "int"}}})
            if "secret" in arguments:
                return json.dumps({"metadata": {"labels": {"app.kubernetes.io/managed-by": "external-manager"}}, "data": {}})
            raise AssertionError(arguments)
        from argparse import Namespace
        args = Namespace(config=str(ROOT / "config/deployment-environments.remote.example.yaml"), environment="int",
                         host_label="devapp", target_kubeconfig="/fixture", certificate_only=True, check=True)
        with patch.dict(os.environ, {"CLOUDFLARE_API_TOKEN": "fixture"}), patch.object(dns, "HTTP", return_value=API()), \
                patch.object(dns, "run", side_effect=kubectl), patch.object(dns, "certificate_valid", return_value=True):
            dns.reconcile(args)
        self.assertTrue(all(method == "GET" for method, _ in calls))
        with patch.dict(os.environ, {"CLOUDFLARE_API_TOKEN": "fixture"}), patch.object(dns, "HTTP", return_value=API()), \
                patch.object(dns, "run", side_effect=kubectl), patch.object(dns, "certificate_valid", return_value=False):
            with self.assertRaisesRegex(ServiceError, "externally managed"):
                dns.reconcile(args)

    def test_local_certificate_targets_namespace_and_verified_operator_endpoint(self):
        calls = []
        class API:
            def request(self, method, path, data):
                return {"success": True, "result": [{"id": "zone"}]}
        def kubectl(arguments, **_kwargs):
            calls.append(arguments)
            if "view" in arguments:
                return json.dumps({"clusters": [{"cluster": {"server": "https://127.0.0.1:6443"}}]})
            if "namespace" in arguments:
                self.assertIn("apps-int", arguments)
                return json.dumps({"metadata": {"labels": {"bm-cluster.io/application-environment": "int"}}})
            if "secret" in arguments:
                self.assertEqual(arguments[arguments.index("-n") + 1], "apps-int")
                return "{}"
            raise AssertionError(arguments)
        args = SimpleNamespace(config="public.yaml", environment="int", host_label="devapp",
                               target_kubeconfig="/fixture", certificate_only=True, check=True)
        with patch.dict(os.environ, {"CLOUDFLARE_API_TOKEN": "fixture"}), patch.object(dns, "HTTP", return_value=API()), \
                patch.object(dns, "load_inventory", return_value=local_inventory()), \
                patch.object(dns, "run", side_effect=kubectl), patch.object(dns, "certificate_valid", return_value=True):
            dns.reconcile(args)
        self.assertIn(["kubectl", "config", "view", "--minify", "-o", "json"], calls)

    def test_local_suffix_tls_key_stays_in_infra_with_central_operator_access(self):
        calls = []
        inventory = local_inventory("suffix")
        secret_name = inventory["environments"]["int"]["tlsSecretName"]
        class API:
            def request(self, method, path, data):
                self_test.assertEqual(method, "GET")
                return {"success": True, "result": [{"id": "zone"}]}
        self_test = self
        def kubectl(arguments, **_kwargs):
            calls.append(arguments)
            if "view" in arguments:
                return json.dumps({"clusters": [{"cluster": {"server": "https://127.0.0.1:6443"}}]})
            if "namespace" in arguments:
                self.assertEqual(arguments[arguments.index("--kubeconfig") + 1], "/scoped")
                return json.dumps({"metadata": {"labels": {"bm-cluster.io/application-environment": "int"}}})
            self.assertEqual(arguments[arguments.index("--kubeconfig") + 1], "/central")
            self.assertEqual(arguments[arguments.index("-n") + 1], "infra")
            if "tlsstore" in arguments:
                return json.dumps({"spec": {"defaultCertificate": {"secretName": secret_name}}})
            if "secret" in arguments:
                return json.dumps({"metadata": {"labels": {"app.kubernetes.io/managed-by": "external-manager"}}, "data": {}})
            raise AssertionError(arguments)
        args = SimpleNamespace(config="public.yaml", environment="int", host_label="devapp", target_kubeconfig="/scoped",
                               platform_kubeconfig="/central", certificate_only=True, check=False)
        with patch.dict(os.environ, {"CLOUDFLARE_API_TOKEN": "fixture"}), patch.object(dns, "HTTP", return_value=API()), \
                patch.object(dns, "load_inventory", return_value=inventory), patch.object(dns, "run", side_effect=kubectl), \
                patch.object(dns, "certificate_valid", return_value=True):
            dns.reconcile(args)
            secret_name = "wrong-central-certificate"
            with self.assertRaisesRegex(ServiceError, "central Traefik default certificate"):
                dns.reconcile(args)
        self.assertFalse(any("apply" in command for command in calls))
        self.assertTrue(any("secret" in command for command in calls))

    def test_local_hostname_reuse_requires_self_referencing_same_application_owner(self):
        target = {"namespace": "apps-prod", "environment": "prod"}
        for namespace, owner, valid in (("apps", "devapp", True), ("apps-prod", "devapp-prod", True),
                                        ("apps", "website", False), ("apps-uat", "devapp-uat", False),
                                        ("apps", "devapp-prod", False), ("apps-prod", "", False)):
            metadata = {"name": "existing", "namespace": namespace, "annotations": {
                "argocd.argoproj.io/tracking-id": f"{owner}:networking.k8s.io/Ingress:{namespace}/existing"}}
            ingress = {"metadata": metadata, "spec": {"rules": [{"host": "devapp.example.com"}]}}
            with self.subTest(namespace=namespace, owner=owner), patch.object(dns, "run", return_value=json.dumps({"items": [ingress]})):
                if valid:
                    dns.verify_hostname_owner(["kubectl"], target, "devapp.example.com", "devapp")
                else:
                    with self.assertRaisesRegex(ServiceError, "unverified local Ingress"):
                        dns.verify_hostname_owner(["kubectl"], target, "devapp.example.com", "devapp")
            metadata["annotations"]["argocd.argoproj.io/tracking-id"] = "devapp:networking.k8s.io/Ingress:apps/copied-from-another-resource"
            with patch.object(dns, "run", return_value=json.dumps({"items": [ingress]})):
                with self.assertRaisesRegex(ServiceError, "unverified local Ingress"):
                    dns.verify_hostname_owner(["kubectl"], target, "devapp.example.com", "devapp")

    def test_existing_website_apex_blocks_dns_even_when_address_and_empty_comment_would_match(self):
        inventory = local_inventory("suffix")
        target = inventory["environments"]["prod"]
        # This record would pass the old DNS-only ownership condition.
        existing_record = {"type": "A", "content": target["ingressAddress"], "comment": ""}
        self.assertEqual(existing_record["content"], target["ingressAddress"])
        def kubectl(arguments, **_kwargs):
            if "view" in arguments:
                return json.dumps({"clusters": [{"cluster": {"server": "https://127.0.0.1:6443"}}]})
            if "namespace" in arguments:
                return json.dumps({"metadata": {"labels": {"bm-cluster.io/application-environment": "prod"}}})
            if "ingresses" in arguments:
                return json.dumps({"items": [{"metadata": {"name": "website", "namespace": "apps", "annotations": {
                    "argocd.argoproj.io/tracking-id": "website:networking.k8s.io/Ingress:apps/website"}},
                    "spec": {"rules": [{"host": "example.com"}]}}]})
            raise AssertionError(arguments)
        args = SimpleNamespace(config="public.yaml", environment="prod", host_label="@", application_name="devapp",
                               target_kubeconfig="/scoped", platform_kubeconfig="/central", certificate_only=False, check=False)
        with patch.dict(os.environ, {"CLOUDFLARE_API_TOKEN": "fixture"}), patch.object(dns, "HTTP") as provider, \
                patch.object(dns, "load_inventory", return_value=inventory), patch.object(dns, "run", side_effect=kubectl):
            with self.assertRaisesRegex(ServiceError, "already belongs"):
                dns.reconcile(args)
        provider.assert_not_called()

    def test_parent_wildcard_does_not_cover_nested_application_hostname(self):
        self.assertFalse(dns.covers("*.example.com","devapp.int.example.com"))
        self.assertTrue(dns.covers("*.int.example.com","devapp.int.example.com"))
        self.assertFalse(dns.covers("*.int.example.com","int.example.com"))
    def test_edge_certificate_checks_paginate_and_ignore_pending_packs(self):
        class API:
            def request(self,method,path,data):
                page=2 if "page=2" in path else 1
                return {"success":True,"result_info":{"total_pages":2},"result":[
                    {"status":"pending_validation" if page==1 else "active","hosts":["*.int.example.com"]}]}
        dns.edge_ready(API(),"zone","devapp.int.example.com")
        with self.assertRaises(ServiceError): dns.edge_ready(API(),"zone","devapp.uat.example.com")


class DeliveryBoundaryTests(unittest.TestCase):
    def manager(self, targets=None):
        platform = SimpleNamespace(api=object(), kubectl=lambda *_args, **_kwargs: None)
        env = SimpleNamespace(onboarding=platform, context=CONTEXT, name="devapp",
                              targets=targets or {}, contract=CONTRACT)
        return ApplicationDelivery(env)

    def test_empty_inventory_prepares_ci_without_deployment_privileges(self):
        manager = self.manager()
        documents = manager.permissions()
        roles = [item for item in documents if item["kind"] == "Role"]
        self.assertEqual(len(roles), 2)
        self.assertTrue(all(rule["resources"] == ["configmaps"] for role in roles for rule in role["rules"]))
        manager.prepare_applications()  # No checkout or fabricated target needed.

    def test_integration_cannot_write_another_environment_or_create_applications(self):
        from deployment_environments import environment_context
        manager = self.manager({env: environment_context(INVENTORY, env) for env in ("int", "uat", "prod")})
        documents = manager.permissions()
        role = next(item for item in documents if item["kind"] == "Role" and item["metadata"]["name"].endswith("-int"))
        rule = next(rule for rule in role["rules"] if rule["resources"] == ["applications"])
        self.assertEqual(rule["resourceNames"], ["devapp-int"])
        self.assertEqual(set(rule["verbs"]), {"get", "patch", "update"})
        policies = [item for item in documents if item["kind"] == "ValidatingAdmissionPolicy"]
        policy = next(item for item in policies if item["metadata"]["name"].endswith("-int"))
        expression = policy["spec"]["validations"][0]["expression"]
        for boundary in ('"applications-int"', '"apps-int"', '"infra/environments/int"',
                         CONTEXT["GITLAB_REPOSITORY_URL"], '!(has(object.spec.sources))', 'object.operation == null',
                         'object.spec.destination.namespace == "apps"', "!has(object.spec.destination.server)"):
            self.assertIn(boundary, expression)
        self.assertNotIn("apps-prod", expression)
        self.assertEqual(policy["spec"]["failurePolicy"], "Fail")

    def test_local_delivery_binds_namespace_even_when_cluster_name_is_shared(self):
        inventory = local_inventory()
        manager = self.manager({env: environment_context(inventory, env) for env in ("int", "uat", "prod")})
        policies = [item for item in manager.permissions() if item["kind"] == "ValidatingAdmissionPolicy"]
        integration = next(item for item in policies if item["metadata"]["name"].endswith("-int"))
        expression = integration["spec"]["validations"][0]["expression"]
        self.assertIn('object.spec.destination.name == "in-cluster"', expression)
        self.assertIn('object.spec.destination.namespace == "apps-int"', expression)
        self.assertNotIn("apps-uat", expression)
        self.assertNotIn("apps-prod", expression)
        release = next(item for item in policies if item["metadata"]["name"].endswith("-release"))
        for env in ("int", "uat", "prod"):
            self.assertIn('object.spec.destination.namespace == "apps-' + env + '"', release["spec"]["validations"][0]["expression"])

    def test_runners_have_fixed_accounts_and_no_shared_writable_cache(self):
        import tomllib
        resources = self.manager().runner_resources()
        config = tomllib.loads(resources[0]["data"]["config.template.toml"])
        self.assertEqual(config["concurrent"], 1)
        for runner, lane in zip(config["runners"], ("int", "release")):
            executor = runner["kubernetes"]
            self.assertEqual(executor["service_account"], "gitlab-project-7-" + lane)
            self.assertFalse(executor["privileged"])
            self.assertEqual(set(executor["volumes"]), {"empty_dir"})
            self.assertFalse(any("overwrite_allowed" in key for key in executor))
        pod = resources[1]["spec"]["template"]["spec"]
        self.assertEqual(pod["serviceAccountName"], "gitlab-runner-manager")
        self.assertTrue(all("persistentVolumeClaim" not in volume for volume in pod["volumes"]))

    def test_unprotected_default_branch_and_active_legacy_jobs_refuse_migration(self):
        manager = self.manager()
        protected, jobs = False, []
        def call(_method, path):
            if "/repository/branches/" in path: return {"protected": protected}
            if "/jobs?" in path: return jobs
            if "/runners?" in path: return []
            return {"default_branch": "main", "shared_runners_enabled": True}
        manager.api = SimpleNamespace(call=call)
        with self.assertRaisesRegex(ServiceError, "Protect the default branch"):
            manager.project_settings()
        protected, jobs = True, [{"id": 23}]
        with self.assertRaisesRegex(ServiceError, "Finish or cancel"):
            manager.project_settings()

    def test_precreated_application_is_inert_and_existing_pointer_is_preserved(self):
        from deployment_environments import environment_context
        manager = self.manager({"int": environment_context(INVENTORY, "int")})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "infra/argocd").mkdir(parents=True)
            template = copy.deepcopy(TEMPLATE)
            template["spec"]["syncPolicy"] = {"automated": {"prune": True}, "syncOptions": ["ServerSideApply=true"]}
            (root / CONTRACT["application"]).write_text(yaml.safe_dump(template))
            manager.environments.checkout = SimpleNamespace(root=root, git=lambda *_args: "a" * 40)
            applied = []
            manager.apply = applied.append
            manager.prepare_applications()
            self.assertNotIn("automated", applied[0]["spec"]["syncPolicy"])
            self.assertEqual(applied[0]["spec"]["source"]["targetRevision"], "a" * 40)
            existing = copy.deepcopy(applied[0])
            existing["spec"]["source"]["targetRevision"] = "b" * 40
            existing["spec"]["syncPolicy"]["automated"] = {"prune": True}
            manager.get = lambda *_args: existing
            manager.prepare_applications()
            self.assertEqual(len(applied), 1)
            existing["spec"]["destination"]["name"] = "apps-prod"
            with self.assertRaisesRegex(ServiceError, "another delivery target"):
                manager.prepare_applications()

    def test_runner_reconciliation_persists_tokens_and_is_idempotent(self):
        manager = self.manager()
        objects, runners, verification = {}, {}, []
        project = {"default_branch": "main", "shared_runners_enabled": True, "group_runners_enabled": True}
        calls = []
        def api(method, path, data=None):
            calls.append((method, path))
            if "/repository/branches/" in path:
                return {"protected": True}
            if "/jobs?" in path:
                return []
            if path.startswith("projects/7/runners?"):
                return list(runners.values())
            if path == "projects/7":
                if method == "PUT": project.update(data)
                return project.copy()
            if path == "user/runners":
                identity = len(runners) + 1
                runners[identity] = {**data, "id": identity, "projects": [{"id": 7}]}
                return {"id": identity, "token": "glrt-fixture-" + str(identity)}
            if path.startswith("runners/") and "reset" not in path:
                identity = int(path.split("/")[1])
                if method == "PUT": runners[identity].update(data)
                return runners[identity]
            raise AssertionError((method, path))
        def kubectl(*arguments, resource=None):
            if arguments[0] == "get":
                namespace = arguments[arguments.index("-n") + 1] if "-n" in arguments else None
                return objects.get((arguments[1].lower(), arguments[2], namespace))
            if arguments[0] == "apply":
                meta = resource["metadata"]
                objects[(resource["kind"].lower(), meta["name"], meta.get("namespace"))] = copy.deepcopy(resource)
                return None
            self.assertEqual(arguments[:2], ("rollout", "status"))
        def verify(_method, _path, data):
            verification.append(data)
            return {"id": int(data["token"].rsplit("-", 1)[1])}
        manager.api = SimpleNamespace(call=api, url="http://fixture/api/v4", headers={})
        manager.kubectl = kubectl
        with patch("application_delivery.HTTP", return_value=SimpleNamespace(request=verify)):
            manager.reconcile()
            manager.reconcile()
        self.assertEqual(sum(path == "user/runners" for _, path in calls), 2)
        self.assertEqual(len(verification), 2)
        self.assertTrue(all(value["system_id"] == manager.system_id for value in verification))
        self.assertFalse(project["shared_runners_enabled"])
        self.assertFalse(project["group_runners_enabled"])
        self.assertEqual(runners[1]["access_level"], "not_protected")
        self.assertEqual(runners[2]["access_level"], "ref_protected")
        self.assertTrue(all(value["locked"] and not value["run_untagged"] for value in runners.values()))
        saved = objects[("secret", "gitlab-project-7", "gitlab-runners")]["data"]
        self.assertEqual(set(saved), {"int-id", "int-token", "release-id", "release-token"})

if __name__ == "__main__": unittest.main()
