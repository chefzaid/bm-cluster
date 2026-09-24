"""Trusted onboarding operations for applications using the shared delivery platform."""
import base64
from contextlib import contextmanager
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

import yaml

from deployment_environments import validate_inventory, environment_context, inventory_json, application_hostname
from onboarding_services import Services, ServiceError


def repository_permitted(patterns, repository):
    """Match exact/*/** HTTP repository rules with Argo's slash separator semantics."""
    def matches(pattern):
        # Argo normalizes Git URLs to lowercase and removes the optional .git suffix.
        pattern = pattern.strip().lower().removesuffix(".git")
        value = repository.strip().lower().removesuffix(".git")
        if pattern == "*":
            return True
        expression = "".join(".*" if part == "**" else "[^/]*" if part == "*" else re.escape(part)
                             for part in re.split(r"(\*\*|\*)", pattern))
        return re.fullmatch(expression, value) is not None
    return (any(not pattern.startswith("!") and matches(pattern) for pattern in patterns)
            and not any(pattern.startswith("!") and matches(pattern[1:]) for pattern in patterns))


def validate_declaration(contract):
    from repository_onboarding import OnboardingError
    declaration = contract.get("deployment")
    if declaration != {"inventory": "infra/deployment-environments.json", "settingsDirectory": "infra/environments",
                       "defaultEnvironment": "int", "dataServices": ["postgres", "redis", "kafka"]}:
        raise OnboardingError("Version 2 requires the shared environment inventory, int default and scoped Postgres/Redis/Kafka services")
    if contract.get("bootstrap") or contract.get("vault"):
        raise OnboardingError("Version 2 provisions scoped data centrally; application bootstrap/admin secrets are unsupported")
    if "DEPLOYMENT_ENVIRONMENT" in contract.get("pipeline", {}).get("variables", {}):
        raise OnboardingError("Select the deployment environment in CI, not in onboarding variables")


class EnvironmentServices(Services):
    """Retain the existing registry/identity reconciler, with an environment-specific client."""
    def __init__(self, *args, target, **kwargs):
        super().__init__(*args, **kwargs)
        self.target = target

    def _dns_read(self, contract):
        # DNS follows the selected environment target, whether local or remote.
        return None

    def _client(self, contract, checkout):
        client = super()._client(contract, checkout)
        if not client:
            return None
        realm, desired = client
        old_host = self.context["APP_HOST"]
        subdomain = self.context["APP_SUBDOMAIN"]
        new_host = application_hostname(self.target, subdomain)
        client_id = self.context["APPLICATION_NAME"] + "-" + self.target["environment"] + "-web"
        desired["clientId"] = client_id
        for field in ("rootUrl", "baseUrl", "webOrigins", "redirectUris"):
            if field in desired:
                value = desired[field]
                desired[field] = value.replace(old_host, new_host) if isinstance(value, str) else [item.replace(old_host, new_host) for item in value]
        logout = desired["attributes"].get("post.logout.redirect.uris")
        if logout:
            desired["attributes"]["post.logout.redirect.uris"] = logout.replace(old_host, new_host)
        for mapper in desired.get("protocolMappers", []):
            if mapper["protocolMapper"] == "oidc-audience-mapper":
                mapper["config"]["included.client.audience"] = client_id
        return realm, desired


class EnvironmentOnboarding:
    def __init__(self, onboarding, checkout, contract, context):
        from repository_onboarding import local_path, load_json, OnboardingError
        self.onboarding, self.checkout, self.contract, self.context = onboarding, checkout, contract, context
        document = onboarding.kubectl("get", "configmap", "deployment-environments", "-n", "infra", "-o", "json")
        self.inventory = validate_inventory(json.loads(document["data"]["environments.json"]), allow_partial=True)
        if (self.inventory["platform"]["domain"] != context["PUBLIC_DOMAIN"] or
                self.inventory["platform"]["internalDomain"] != context["INTERNAL_DNS_ZONE"] or
                self.inventory["platform"]["services"]["keycloak"]["realm"] != context["KEYCLOAK_REALM"] or
                self.inventory["platform"]["services"]["keycloak"]["url"] != "https://keycloak." + context["PUBLIC_DOMAIN"] + "/auth"):
            raise OnboardingError("The registered environments belong to another shared platform")
        self.environment = os.environ.get("ONBOARDING_DEPLOYMENT_ENVIRONMENT", contract["deployment"]["defaultEnvironment"])
        self.target = environment_context(self.inventory, self.environment)
        self.name = context["APPLICATION_NAME"]
        inventory_path = contract["deployment"]["inventory"]
        path = local_path(checkout.root, inventory_path, existing=False)
        if path.exists():
            old = validate_inventory(load_json(path), allow_partial=True)
            if old["platform"] != self.inventory["platform"]:
                raise OnboardingError("Shared service inventory changed; migrate existing app settings explicitly")
            for env, target in old["environments"].items():
                new = self.inventory["environments"].get(env)
                if not new or any(new[key] != target[key] for key in ("clusterName", "server", "namespace")):
                    raise OnboardingError("A saved environment changed cluster identity; migration must be explicit")
        self.paths = [inventory_path]
        template = yaml.safe_load((checkout.root / contract["application"]).read_text())
        profile = template["spec"]["source"]["path"]
        if profile not in ("infra/k8s", "infra/overlays/ha"):
            raise OnboardingError("Version 2 supports the common runtime base and its HA profile")
        self.targets = {name: environment_context(self.inventory, name) for name in sorted(self.inventory["environments"])}
        self.registrations = {}
        pending_settings = []
        for env, target in self.targets.items():
            self.registrations[env] = self.registration(env)
            settings_path = f"{contract['deployment']['settingsDirectory']}/{env}/settings.json"
            settings_file = local_path(checkout.root, settings_path, existing=False)
            settings = load_json(settings_file) if settings_file.exists() else {}
            if set(settings) - {"appSubdomain", "trustedProxyCIDRs", "highAvailability", "databaseName"}:
                raise OnboardingError("Unknown application environment setting")
            if "appSubdomain" in settings and settings["appSubdomain"] != context["APP_SUBDOMAIN"]:
                raise OnboardingError(f"Changing {env}'s saved application label requires an explicit hostname migration; "
                                      "pinned deployments still need their existing DNS and identity callbacks")
            settings.update(appSubdomain=context["APP_SUBDOMAIN"])
            settings.setdefault("trustedProxyCIDRs", target["podCIDR"])
            settings.setdefault("highAvailability", profile == "infra/overlays/ha")
            pending_settings.append((settings_file, settings))
            self.paths.append(settings_path)
        # Validate every saved label before changing public settings or shared
        # clients: only the selected environment will receive a new deployment.
        path.write_text(inventory_json(self.inventory) + "\n")
        for settings_file, settings in pending_settings:
            settings_file.parent.mkdir(parents=True, exist_ok=True)
            settings_file.write_text(json.dumps(settings, sort_keys=True, indent=2) + "\n")

    def registration(self, environment):
        from repository_onboarding import OnboardingError
        target = self.targets[environment]
        secret = self.onboarding.kubectl("get", "secret", "application-cluster-" + environment, "-n", "infra", "-o", "json")
        data = {key: base64.b64decode(value).decode() for key, value in secret.get("data", {}).items()}
        metadata = secret.get("metadata", {})
        if (data.get("name") != target["clusterName"] or data.get("server") != target["server"] or
                data.get("namespaces") != target["namespace"] or data.get("clusterResources") != "false" or
                data.get("project") != target["project"] or
                metadata.get("labels", {}).get("bm-cluster.io/application-environment") != environment):
            raise OnboardingError("Registered Argo cluster does not match the selected environment")
        local = target.get("mode", "remote") == "local"
        registration_type = metadata.get("labels", {}).get("argocd.argoproj.io/secret-type")
        if (local and registration_type is not None) or (not local and registration_type != "cluster"):
            raise OnboardingError("Local operator credentials must not replace Argo CD's built-in cluster registration")
        if local:
            # The public Argo destination is stable, while operator requests use
            # the currently selected kubeconfig's verified, reachable endpoint.
            current = self.onboarding.kubectl("config", "view", "--minify", "-o", "json")
            cluster = current["clusters"][0]["cluster"]
            if (cluster.get("insecure-skip-tls-verify") or not data.get("apiServer") or
                    data["apiServer"].rstrip("/") != cluster["server"].rstrip("/")):
                raise OnboardingError("Local environment credentials belong to another platform endpoint")
        elif data.get("apiServer"):
            raise OnboardingError("Remote environment credentials cannot override their registered endpoint")
        config = json.loads(data["config"])
        tls = config.get("tlsClientConfig", {})
        if set(config) - {"bearerToken", "tlsClientConfig"} or not config.get("bearerToken") or tls.get("insecure") or not tls.get("caData"):
            raise OnboardingError("Application cluster registration must use a scoped token and verified CA")
        return data

    @contextmanager
    def target_kubeconfig(self, environment):
        # Recheck registration at the operation boundary; no bearer token reaches argv or Git.
        data = self.registration(environment)
        config = json.loads(data["config"])
        with tempfile.TemporaryDirectory(prefix="onboarding-target-") as directory:
            path = Path(directory) / "kubeconfig"
            path.write_text(json.dumps({"apiVersion": "v1", "kind": "Config", "current-context": "target",
                "clusters": [{"name": "target", "cluster": {"server": data.get("apiServer", data["server"]), "certificate-authority-data": config["tlsClientConfig"]["caData"]}}],
                "users": [{"name": "target", "user": {"token": config["bearerToken"]}}],
                "contexts": [{"name": "target", "context": {"cluster": "target", "user": "target", "namespace": self.targets[environment]["namespace"]}}]}))
            path.chmod(0o600)
            yield str(path)

    def invoke(self, script, *arguments, environment=None):
        result = subprocess.run(["python3", str(Path(__file__).resolve().parents[1] / script), *arguments],
                                env=environment, text=True, capture_output=True, timeout=600)
        if result.returncode:
            raise ServiceError(result.stderr.strip() or f"{script} did not complete; run its documented prerequisite check before retrying onboarding")
        if result.stdout.strip():
            print(result.stdout.strip(), flush=True)

    def application(self, template):
        app = copy.deepcopy(template)
        app["metadata"]["name"] = self.name + "-" + self.environment
        app["spec"]["project"] = self.target["project"]
        app["spec"]["destination"] = {"name": self.target["clusterName"], "namespace": self.target["namespace"]}
        app["spec"]["source"]["path"] = "infra/environments/" + self.environment
        return app

    def validate(self, checkout, contract, app):
        from repository_onboarding import local_path, OnboardingError
        ci = local_path(checkout.root, ".gitlab-ci.yml").read_text()
        data = yaml.load(ci, Loader=yaml.BaseLoader)
        selector = data.get("variables", {}).get("DEPLOYMENT_ENVIRONMENT", {})
        if selector.get("value") != "int" or set(selector.get("options", [])) != {"int", "uat", "prod"}:
            raise OnboardingError("CI must provide the int/uat/prod selector with int as the safe initial target")
        for env, target in self.targets.items():
            project = self.onboarding.kubectl("get", "appproject", target["project"], "-n", "infra", "-o", "json")["spec"]
            destinations = project.get("destinations", [])
            if destinations not in ([{"name": target["clusterName"], "namespace": target["namespace"]}],
                                    [{"server": target["server"], "namespace": target["namespace"]}]):
                raise OnboardingError("Application project must permit exactly its registered environment destination")
            patterns = project.get("sourceRepos", [])
            url = self.context["GITLAB_REPOSITORY_URL"]
            if not repository_permitted(patterns, url):
                raise OnboardingError("Application project does not allow this shared GitLab repository")
            with self.target_kubeconfig(env) as path:
                namespace = subprocess.run(["kubectl", "--kubeconfig", path, "get", "namespace", target["namespace"], "-o", "json"],
                                           text=True, capture_output=True, timeout=30, check=True)
                if json.loads(namespace.stdout)["metadata"].get("labels", {}).get("bm-cluster.io/application-environment") != env:
                    raise OnboardingError("Target namespace environment identity does not match registration")
        return ci

    def services(self, secret_inputs):
        self.secret_inputs = secret_inputs
        self.clients = {env: EnvironmentServices(self.onboarding.api, self.onboarding.kubectl, self.context,
                        secret_inputs, target=target) for env, target in self.targets.items()}
        return self

    def dns(self, env, *, check=False):
        with self.target_kubeconfig(env) as path:
            self.invoke("configure-application-dns.py", "--config", str(self.checkout.root / self.contract["deployment"]["inventory"]),
                        "--environment", env, "--target-kubeconfig", path, "--host-label", self.context["APP_SUBDOMAIN"],
                        "--application-name", self.name,
                        *(["--check"] if check else []),
                        environment={**os.environ, "CLOUDFLARE_API_TOKEN": self.secret_inputs["CLOUDFLARE_API_TOKEN"]})

    def preflight(self, contract, checkout):
        for env, client in self.clients.items():
            client.preflight(contract, checkout)
            self.invoke("configure-application-data.py", "--config", str(self.checkout.root / contract["deployment"]["inventory"]),
                        "--environment", env, "--check")
            self.dns(env, check=True)

    def provision(self, contract, checkout):
        for env, client in self.clients.items():
            settings = json.loads((self.checkout.root / f"infra/environments/{env}/settings.json").read_text())
            database = settings.get("databaseName", self.name.replace("-", "_") + "_" + env)
            adopt = [] if database == self.name.replace("-", "_") + "_" + env else ["--adopt-existing-database", database]
            self.invoke("configure-application-data.py", "--config", str(self.checkout.root / contract["deployment"]["inventory"]),
                        "--environment", env, "--application", self.name, *adopt)
            client.provision(contract, checkout)

    def publish_dns(self, contract):
        for env in self.targets:
            self.dns(env)

    def configure_delivery(self):
        from application_delivery import ApplicationDelivery
        ApplicationDelivery(self).reconcile()

    def refresh_credentials(self):
        for env in self.targets:
            with self.target_kubeconfig(env) as path:
                def kubectl(*arguments):
                    result = subprocess.run(["kubectl", "--kubeconfig", path, *arguments], text=True,
                                            capture_output=True, timeout=60)
                    if result.returncode:
                        raise ServiceError("Cannot refresh the target application's External Secrets")
                    return json.loads(result.stdout) if arguments[-2:] == ("-o", "json") else None
                resources = kubectl("get", "externalsecrets", "-n", self.targets[env]["namespace"], "-o", "json")
                paths = {self.contract["registry"]["path"], *(f"apps/{self.name}/{env}/{service}" for service in ("database", "redis", "kafka"))}
                for item in resources.get("items", []):
                    spec = item.get("spec", {})
                    references = {field.get("remoteRef", {}).get("key") for field in spec.get("data", [])}
                    references.update(field.get("extract", {}).get("key") for field in spec.get("dataFrom", []))
                    if references & paths:
                        self.onboarding.refresh_external_secret(item["metadata"]["name"], self.targets[env]["namespace"], kubectl)

    def release_application(self, checkout, release_head):
        from repository_onboarding import OnboardingError
        app = yaml.safe_load(checkout.git("show", release_head + ":infra/argocd/" + self.environment + ".yaml"))
        expected = self.application(yaml.safe_load((checkout.root / self.contract["application"]).read_text()))
        if (app["metadata"]["name"] != expected["metadata"]["name"] or app["metadata"].get("namespace") != "infra" or
                any(app["spec"].get(key) != expected["spec"][key] for key in ("project", "destination")) or
                any(app["spec"]["source"].get(key) != expected["spec"]["source"][key] for key in ("repoURL", "path"))):
            raise OnboardingError("Published Application does not match the selected registered environment")
        revision = app["spec"]["source"].get("targetRevision", "")
        if not re.fullmatch(r"[0-9a-f]{40}", revision) or revision == release_head:
            raise OnboardingError("Application must pin the preceding immutable runtime configuration commit")
        checkout.git("merge-base", "--is-ancestor", revision, release_head)
        return app

    def wait_deployments(self, contract):
        with self.target_kubeconfig(self.environment) as path:
            for deployment in contract["readiness"]["deployments"]:
                result = subprocess.run(["kubectl", "--kubeconfig", path, "rollout", "status", "deployment/" + deployment,
                    "-n", self.target["namespace"], "--timeout=120s"], text=True, capture_output=True, timeout=150)
                if result.returncode:
                    raise ServiceError("A selected application environment deployment is not available")
