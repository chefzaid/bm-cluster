"""Generic, resumable application onboarding from repository-owned declarations."""

from contextlib import contextmanager
import base64
import fcntl
from fnmatch import fnmatchcase
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import time
from urllib.parse import urlparse, urlencode
import uuid

import yaml

from onboarding_services import Services, ServiceError

CONTRACT = "infra/onboarding.json"
SETTINGS = "infra/onboarding-values.json"
PLACEHOLDER = re.compile(r"\{\{([A-Z][A-Z0-9_]*)\}\}")
LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")
ALLOWED_BOOTSTRAP = {"Namespace", "Role", "RoleBinding", "ExternalSecret"}


class OnboardingError(Exception):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def expand(value, context):
    if isinstance(value, str):
        def substitute(match):
            if match[1] not in context:
                raise OnboardingError(f"Undeclared onboarding value: {match[1]}")
            return str(context[match[1]])
        return PLACEHOLDER.sub(substitute, value)
    if isinstance(value, list):
        return [expand(item, context) for item in value]
    if isinstance(value, dict):
        return {key: expand(item, context) for key, item in value.items()}
    return value


def local_path(root, name, *, existing=True):
    if not isinstance(name, str) or not name or "\\" in name:
        raise OnboardingError("Onboarding paths must be repository-local file names")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or ".git" in path.parts:
        raise OnboardingError(f"Path leaves the repository: {name}")
    target = root / path
    current = root
    for part in path.parts:
        current /= part
        if current.is_symlink():
            raise OnboardingError(f"Symlinks are not permitted in onboarding paths: {name}")
    if existing and not target.is_file():
        raise OnboardingError(f"Required onboarding file is missing: {name}")
    return target


def load_json(path):
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise OnboardingError(f"Cannot read valid JSON from {path.name}") from error
    if not isinstance(value, dict):
        raise OnboardingError(f"{path.name} must contain a JSON object")
    return value


def validate_contract(root):
    contract = load_json(local_path(root, CONTRACT))
    allowed = {"version", "application", "inputs", "files", "replacements", "registry",
               "vault", "keycloak", "dns", "bootstrap", "pipeline", "readiness"}
    if contract.get("version") != 1 or set(contract) - allowed:
        raise OnboardingError("Unsupported onboarding contract version or fields")
    app_path = contract.get("application")
    if app_path not in ("infra/argocd/application.yaml", "argocd/application.yaml"):
        raise OnboardingError("Declare one supported Argo CD Application path")
    local_path(root, app_path)
    files = contract.get("files")
    if (not isinstance(files, list) or not files or any(not isinstance(name, str) for name in files)
            or len(set(files)) != len(files)):
        raise OnboardingError("Declare a nonempty, unique list of public configuration files")
    for name in files:
        local_path(root, name)
        if name in (CONTRACT, SETTINGS) or name.endswith((".pem", ".key", ".env")):
            raise OnboardingError("Contract, settings and credential files cannot be replacement targets")
    inputs = contract.get("inputs", [])
    if not isinstance(inputs, list):
        raise OnboardingError("inputs must be a list")
    names = set()
    for item in inputs:
        if (not isinstance(item, dict) or not isinstance(item.get("name"), str)
                or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", item["name"])
                or item["name"] in names or item.get("type", "string") not in {"string", "subdomain", "cidrs"}
                or not isinstance(item.get("label", item["name"]), str)
                or any(type(item.get(flag, False)) is not bool for flag in ("secret", "required"))):
            raise OnboardingError("Invalid or duplicate onboarding input")
        names.add(item["name"])
        if item.get("secret") and item.get("default", ""):
            raise OnboardingError("Secret inputs cannot have committed default values")
    sources = set()
    if not isinstance(contract.get("replacements", []), list):
        raise OnboardingError("replacements must be a list")
    for binding in contract.get("replacements", []):
        if (not isinstance(binding, dict) or set(binding) != {"from", "to"}
                or not isinstance(binding["from"], str) or not binding["from"]
                or not isinstance(binding["to"], str) or binding["from"] in sources):
            raise OnboardingError("Invalid or duplicate public configuration replacement")
        sources.add(binding["from"])
    pipeline = contract.get("pipeline", {})
    if not isinstance(pipeline, dict):
        raise OnboardingError("pipeline must be an object")
    jobs = pipeline.get("jobs")
    variables = pipeline.get("variables", {})
    if (not isinstance(jobs, list) or not jobs or any(not isinstance(job, str) or not job for job in jobs)
            or len(set(jobs)) != len(jobs) or not isinstance(variables, dict)
            or variables.get("APP_ONBOARDING") != "true"):
        raise OnboardingError("Declare automatic onboarding pipeline variables and required delivery jobs")
    for key, value in variables.items():
        if (not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or not isinstance(value, str)
                or re.search(r"TOKEN|PASSWORD|SECRET|CREDENTIAL|PRIVATE_KEY", key)):
            raise OnboardingError("Pipeline variables must contain public configuration only")
    if set(variables) & {"ONBOARDING_EXPECTED_SHA", "ONBOARDING_RUN_ID"} or variables.get("SONAR_SCAN_ONLY") == "true":
        raise OnboardingError("Onboarding must run delivery with an orchestrator-owned expected revision")
    if not isinstance(contract.get("bootstrap", []), list):
        raise OnboardingError("bootstrap must be a list")
    for name in contract.get("bootstrap", []):
        local_path(root, name)
    keycloak = contract.get("keycloak")
    if keycloak:
        local_path(root, keycloak.get("file") if isinstance(keycloak, dict) else None)
    if not isinstance(contract.get("readiness"), dict):
        raise OnboardingError("readiness must be an object")
    deployments = contract.get("readiness", {}).get("deployments", [])
    if not isinstance(deployments, list) or not deployments or any(not isinstance(name, str) or not LABEL.fullmatch(name) for name in deployments):
        raise OnboardingError("Declare the application Deployments to verify")
    if not isinstance(contract.get("registry"), dict) or not isinstance(contract["registry"].get("path"), str):
        raise OnboardingError("Declare the application's registry credentials path")
    if (not isinstance(contract.get("vault", []), list)
            or any(not isinstance(item, dict) or not isinstance(item.get("path"), str) for item in contract.get("vault", []))):
        raise OnboardingError("vault must be a list of declarations")
    if (not isinstance(contract.get("dns"), dict) or not isinstance(contract["dns"].get("hosts"), list)
            or not contract["dns"]["hosts"] or any(not isinstance(host, str) for host in contract["dns"]["hosts"])):
        raise OnboardingError("Declare the application's DNS hosts")
    return contract


def public_context(runner, slug, project):
    domain = os.environ.get("PLATFORM_DOMAIN") or urlparse(runner.public_url).hostname.removeprefix("gitlab.")
    if not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}", domain):
        raise OnboardingError("PLATFORM_DOMAIN must be a public DNS zone")
    internal = "http://gitlab." + runner.internal_zone
    return {
        "PUBLIC_DOMAIN": domain, "INTERNAL_DNS_ZONE": runner.internal_zone,
        "TLS_SECRET_NAME": domain.replace(".", "-") + "-tls",
        "GITLAB_PROJECT_PATH": project["path_with_namespace"], "GITLAB_PROJECT_ID": str(project["id"]),
        "GITLAB_PUBLIC_URL": runner.public_url, "GITLAB_INTERNAL_URL": internal,
        "GITLAB_REPOSITORY_URL": internal + "/" + project["path_with_namespace"] + ".git",
        "REGISTRY_HOST": "registry." + domain,
        "REGISTRY_PUSH_HOST": "gitlab-registry." + runner.internal_zone + ":5050",
        "GITHUB_OWNER": slug.split("/")[0], "GITHUB_REPOSITORY": slug.split("/")[1],
        "DEFAULT_BRANCH": project["default_branch"], "KEYCLOAK_REALM": os.environ.get("KEYCLOAK_REALM", "swirlit"),
        "POD_CIDR": os.environ.get("K3S_CLUSTER_CIDR", "10.42.0.0/16"),
        "PLATFORM_SECURITY_PROJECT_PATH": os.environ.get("PLATFORM_SECURITY_PROJECT_PATH", ""),
        "SONAR_PROJECT_KEY": project["path_with_namespace"].replace("/", ":"),
    }


def collect_inputs(contract, base, previous, supplied, interactive):
    context, secrets = dict(base), {}
    definitions = {item["name"]: item for item in contract.get("inputs", [])}
    if set(supplied) - set(definitions):
        raise OnboardingError("Unknown per-repository input: " + ", ".join(sorted(set(supplied) - set(definitions))))
    for name, item in definitions.items():
        if name in base:
            raise OnboardingError(f"Application input cannot override platform context: {name}")
        secret = item.get("secret", False)
        default = expand(item.get("default", ""), context)
        if not secret:
            default = previous.get("context", {}).get(name, default)
        value = supplied.get(name)
        if value is None and interactive:
            label = item.get("label", name)
            if secret:
                value = getpass.getpass(f"{label} (leave empty to retain/skip): ")
            else:
                value = input(f"{label} [{default}]: ") or default
        if value is None:
            value = default
        if not isinstance(value, str) or "\x00" in value or len(value) > 16384:
            raise OnboardingError(f"Invalid input value: {name}")
        if not value and item.get("required", True):
            raise OnboardingError(f"Missing required input: {name}; supply a per-repository inputs file")
        kind = item.get("type", "string")
        if kind == "subdomain" and value and value != "@" and not LABEL.fullmatch(value):
            raise OnboardingError(f"{name} must be one DNS label, or @ for the zone apex")
        if kind == "cidrs" and value:
            try:
                for part in value.split(","):
                    ipaddress.ip_network(part.strip(), strict=False)
            except ValueError as error:
                raise OnboardingError(f"{name} must contain comma-separated IP networks") from error
        (secrets if secret else context)[name] = value
        if name == "APP_SUBDOMAIN":
            context["APP_HOST"] = base["PUBLIC_DOMAIN"] if value == "@" else value + "." + base["PUBLIC_DOMAIN"]
    if "APP_HOST" not in context:
        raise OnboardingError("Declare the public APP_SUBDOMAIN input")
    return context, secrets


def render(root, contract, context, previous):
    substitutions, bindings = {}, {}
    for item in contract.get("replacements", []):
        original = item["from"]
        old = previous.get("bindings", {}).get(original, original)
        new = expand(item["to"], context)
        if old in substitutions and substitutions[old] != new:
            raise OnboardingError("Previous public settings produce ambiguous replacements; review the app's contract")
        substitutions[old] = new
        bindings[original] = new
    pattern = re.compile("|".join(re.escape(key) for key in sorted(substitutions, key=len, reverse=True))) if substitutions else None
    for name in contract["files"]:
        path = local_path(root, name)
        source = path.read_text()
        updated = pattern.sub(lambda match: substitutions[match[0]], source) if pattern else source
        if source != updated:
            path.write_text(updated)
    app_path = local_path(root, contract["application"])
    documents = list(yaml.safe_load_all(app_path.read_text()))
    if len(documents) != 1 or not isinstance(documents[0], dict):
        raise OnboardingError("Declare exactly one Argo CD Application")
    app = documents[0]
    if app.get("apiVersion") != "argoproj.io/v1alpha1" or app.get("kind") != "Application":
        raise OnboardingError("Invalid Argo CD Application")
    spec = app.get("spec", {})
    source = spec.get("source", {})
    if not isinstance(source, dict) or set(source) - {"repoURL", "path", "targetRevision"}:
        raise OnboardingError("Version 1 requires a plain local Kustomize source or Helm chart using its defaults")
    if (spec.get("sources") or source.get("chart") or not source.get("path")
            or spec.get("destination", {}).get("server") != "https://kubernetes.default.svc"
            or spec.get("destination", {}).get("namespace") != "apps" or not spec.get("project")):
        raise OnboardingError("Onboarding requires one repository-local Application in the apps namespace")
    source_path = local_path(root, source["path"], existing=False)
    if not source_path.is_dir():
        raise OnboardingError("Argo CD source directory is missing")
    old_revision = source.get("targetRevision", "HEAD")
    if old_revision not in ("HEAD", context["DEFAULT_BRANCH"]):
        raise OnboardingError("Onboarding release pipelines require the Application to follow the default branch")
    if not LABEL.fullmatch(app.get("metadata", {}).get("name", "")):
        raise OnboardingError("Invalid Application name")
    app["metadata"]["namespace"] = "infra"
    source["repoURL"] = context["GITLAB_REPOSITORY_URL"]
    source["targetRevision"] = context["DEFAULT_BRANCH"]
    options = spec.setdefault("syncPolicy", {}).setdefault("syncOptions", [])
    if "FailOnSharedResource=true" not in options:
        options.append("FailOnSharedResource=true")
    app_path.write_text(yaml.safe_dump(app, sort_keys=False))
    settings = {"version": 1, "context": context, "bindings": bindings}
    local_path(root, SETTINGS, existing=False).write_text(json.dumps(settings, indent=2, sort_keys=True) + "\n")
    return app, settings


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            temporary.unlink(missing_ok=True)


@contextmanager
def journal(project, cluster_uid):
    base = Path(os.environ.get("REPOSITORY_STATE_DIR") or str(Path.home() / ".local/state/bm-cluster/repositories"))
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    if base.is_symlink() or base.stat().st_mode & 0o077:
        raise OnboardingError("REPOSITORY_STATE_DIR must be a private directory (mode 0700)")
    key = digest({"project": project["id"], "path": project["path_with_namespace"]})[:24]
    path = base / (key + ".json")
    lock_path = base / (key + ".lock")
    if path.is_symlink() or lock_path.is_symlink():
        raise OnboardingError("Onboarding state cannot be a symlink")
    with lock_path.open("a") as lock:
        os.chmod(lock_path, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise OnboardingError("This repository is already being configured by another local process") from error
        state = load_json(path) if path.exists() else {}
        identity = {"cluster_uid": cluster_uid, "project_id": project["id"], "project_path": project["path_with_namespace"]}
        if any(state.get(name, value) != value for name, value in identity.items()):
            raise OnboardingError("Saved onboarding state belongs to another cluster or project; choose another state directory")
        state.update(identity)
        yield state, lambda: atomic_json(path, state)


class Checkout:
    def __init__(self, url, branch, token):
        self.url, self.branch, self.token = url, branch, token

    def __enter__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bm-repository-")
        directory = Path(self.temporary.name)
        self.root = directory / "checkout"
        helper = directory / "askpass"
        helper.write_text("#!/usr/bin/env python3\nimport os,sys\nprint('oauth2' if 'Username' in sys.argv[1] else os.environ['ONBOARDING_GIT_TOKEN'])\n")
        helper.chmod(0o700)
        self.environment = {key: value for key, value in os.environ.items() if key in ("PATH", "HOME", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR")}
        self.environment.update(GIT_TERMINAL_PROMPT="0", GIT_ASKPASS=str(helper), ONBOARDING_GIT_TOKEN=self.token,
                                GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
        try:
            self.git("clone", "--quiet", "--single-branch", "--no-tags", "--branch", self.branch, "--", self.url, str(self.root), cwd=directory)
            self.sha = self.git("rev-parse", "HEAD")
            return self
        except BaseException:
            self.temporary.cleanup()
            raise

    def __exit__(self, *_args):
        self.environment.pop("ONBOARDING_GIT_TOKEN", None)
        self.temporary.cleanup()

    def git(self, *args, cwd=None):
        result = subprocess.run(["git", "-c", "credential.helper=", "-c", "core.hooksPath=/dev/null",
                                 "-c", "http.followRedirects=false", *args], cwd=cwd or self.root,
                                env=self.environment, text=True, capture_output=True, timeout=300)
        if result.returncode:
            raise OnboardingError("Git operation failed (" + args[0] + "); check repository access or concurrent branch changes")
        return result.stdout.strip()

    def remote_head(self):
        return self.git("ls-remote", "origin", "refs/heads/" + self.branch).split()[0]

    def release_head(self, pipeline):
        """Return only a source tip or the GitOps tip produced by this pipeline."""
        self.git("fetch", "--quiet", "origin", "refs/heads/" + self.branch)
        tip = self.git("rev-parse", "FETCH_HEAD")
        if tip == pipeline["sha"]:
            return tip
        message = self.git("show", "-s", "--format=%B", tip)
        if (re.findall(r"^Onboarding-Pipeline: (\d+)$", message, re.M) != [str(pipeline["id"])]
                or re.findall(r"^Onboarding-Source: ([0-9a-f]{40})$", message, re.M) != [pipeline["sha"]]):
            return None
        self.git("merge-base", "--is-ancestor", pipeline["sha"], tip)
        if pipeline["sha"] not in self.git("rev-list", "--first-parent", tip).splitlines():
            return None
        return tip

    def publish(self, paths):
        if self.remote_head() != self.sha:
            raise OnboardingError("The default branch changed during setup; rerun against its new revision")
        self.git("add", "--", *sorted(set(paths)))
        changed = self.git("diff", "--cached", "--name-only")
        if not changed:
            return self.sha
        self.git("diff", "--cached", "--check")
        self.git("-c", "user.name=Application onboarding", "-c", "user.email=onboarding@localhost",
                 "commit", "--quiet", "-m", "Configure application deployment settings [skip ci]")
        self.git("push", "--quiet", "origin", "HEAD:refs/heads/" + self.branch)
        self.sha = self.git("rev-parse", "HEAD")
        return self.sha


def all_jobs(api, project_id, pipeline_id):
    jobs = []
    for page in range(1, 51):
        batch = api.call("GET", f"projects/{project_id}/pipelines/{pipeline_id}/jobs?per_page=100&page={page}")
        jobs.extend(batch)
        if len(batch) < 100:
            return jobs
    raise OnboardingError("Pipeline job inventory is too large")


def delivery_status(jobs, required):
    latest = {}
    for job in jobs:
        if job.get("name") in required and job.get("id", 0) > latest.get(job["name"], {}).get("id", -1):
            latest[job["name"]] = job
    return {name: latest.get(name, {}).get("status", "missing") for name in required}


def project_allows(project, app):
    spec = project.get("spec", {})
    source = app["spec"]["source"]["repoURL"]
    patterns = spec.get("sourceRepos", [])
    allowed_source = any(not item.startswith("!") and fnmatchcase(source, item) for item in patterns)
    denied_source = any(item.startswith("!") and fnmatchcase(source, item[1:]) for item in patterns)
    destination = app["spec"]["destination"]
    matches, denied = False, False
    for item in spec.get("destinations", []):
        server, namespace = item.get("server", ""), item.get("namespace", "")
        if not server and item.get("name") in ("in-cluster", "*"):
            server = destination["server"]
        if fnmatchcase(destination["server"], server.lstrip("!")) and fnmatchcase(destination["namespace"], namespace.lstrip("!")):
            if server.startswith("!") or namespace.startswith("!"):
                denied = True
            else:
                matches = True
    if not allowed_source or denied_source or not matches or denied:
        raise OnboardingError("The Argo CD AppProject does not permit this repository and apps destination")


class Onboarding:
    def __init__(self, runner):
        self.runner = runner
        self.api = runner.gitlab
        self.kubectl = runner.kubectl
        try:
            self.timeout = int(os.environ.get("ONBOARDING_TIMEOUT", "3600"))
        except ValueError:
            raise OnboardingError("ONBOARDING_TIMEOUT must be an integer number of seconds") from None
        if not 30 <= self.timeout <= 43200:
            raise OnboardingError("ONBOARDING_TIMEOUT must be between 30 and 43200 seconds")

    def supplied_inputs(self, slug):
        filename = os.environ.get("REPOSITORY_INPUTS_FILE")
        if not filename:
            return {}
        path = Path(filename)
        if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
            raise OnboardingError("REPOSITORY_INPUTS_FILE must be a private regular JSON file (mode 0600)")
        values = load_json(path).get(slug, {})
        if not isinstance(values, dict):
            raise OnboardingError("Per-repository inputs must be a JSON object keyed by owner/repository")
        return values

    def validate_local(self, checkout, contract, app):
        root = checkout.root
        ci = local_path(root, ".gitlab-ci.yml").read_text()
        if not isinstance(yaml.load(ci, Loader=yaml.BaseLoader), dict):
            raise OnboardingError("Missing or invalid .gitlab-ci.yml")
        self.bootstrap_resources(root, contract)
        namespace = self.kubectl("get", "namespace", "apps", "-o", "json")
        if (namespace.get("status", {}).get("phase") != "Active"
                or namespace.get("metadata", {}).get("labels", {}).get("pod-security.kubernetes.io/enforce") not in ("baseline", "restricted")):
            raise OnboardingError("Reconcile the platform apps namespace and its security policy before adding applications")
        self.kubectl("get", "networkpolicy", "default-deny-ingress", "-n", "apps", "-o", "json")
        store = self.kubectl("get", "clustersecretstore", "vault-backend", "-o", "json")
        if not any(item.get("type") == "Ready" and item.get("status") == "True" for item in store.get("status", {}).get("conditions", [])):
            raise OnboardingError("The platform Vault External Secrets store is not Ready")
        project = self.kubectl("get", "appproject", app["spec"]["project"], "-n", "infra", "-o", "json")
        project_allows(project, app)
        self.kubectl("apply", "--dry-run=server", "-f", "-", resource=app)
        source = root / app["spec"]["source"]["path"]
        if (source / "kustomization.yaml").is_file() or (source / "kustomization.yml").is_file():
            command = ["kubectl", "kustomize", str(source)]
        elif (source / "Chart.yaml").is_file():
            command = ["helm", "template", app["metadata"]["name"], str(source), "--namespace", "apps"]
        else:
            raise OnboardingError("Declare a repository-local Kustomize directory or Helm chart")
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise OnboardingError("Application manifests do not render; run its local deployment checks")
        for document in yaml.safe_load_all(result.stdout):
            if document and document.get("kind") == "Ingress":
                ingress = document.get("spec", {})
                if ingress.get("ingressClassName"):
                    self.kubectl("get", "ingressclass", ingress["ingressClassName"], "-o", "json")
                for rule in document.get("spec", {}).get("rules", []):
                    if rule.get("host") not in contract["dns"]["hosts"]:
                        raise OnboardingError("An application Ingress hostname is missing from its DNS declaration")
                for tls in ingress.get("tls", []):
                    secret = self.kubectl("get", "secret", tls["secretName"], "-n", "apps", "-o", "json")
                    if secret.get("type") != "kubernetes.io/tls" or not all(secret.get("data", {}).get(key) for key in ("tls.crt", "tls.key")):
                        raise OnboardingError("The platform must provision the application TLS certificate before onboarding")
                    certificate = base64.b64decode(secret["data"]["tls.crt"]).decode()
                    for host in tls.get("hosts", []):
                        checked = subprocess.run(["openssl", "x509", "-noout", "-checkend", "0", "-checkhost", host],
                                                 input=certificate, capture_output=True, text=True, timeout=10)
                        if checked.returncode or "does match certificate" not in checked.stdout:
                            raise OnboardingError("The platform TLS certificate is expired or does not cover an application hostname")
        return ci

    def bootstrap_resources(self, root, contract):
        resources = []
        for name in contract.get("bootstrap", []):
            for resource in yaml.safe_load_all(local_path(root, name).read_text()):
                if not resource:
                    continue
                if not isinstance(resource, dict) or resource.get("kind") not in ALLOWED_BOOTSTRAP:
                    raise OnboardingError("Bootstrap files may only contain Namespace, Role, RoleBinding and ExternalSecret resources")
                namespace = resource.get("metadata", {}).get("namespace", "apps")
                if namespace not in ("infra", "apps"):
                    raise OnboardingError("Application bootstrap resources must stay in infra/apps")
                if resource["kind"] == "Namespace" and resource["metadata"]["name"] != "apps":
                    raise OnboardingError("Application bootstrap can only create the apps namespace")
                if resource["kind"] != "Namespace":
                    resource.setdefault("metadata", {}).setdefault("namespace", "apps")
                resources.append(resource)
        return resources

    def bootstrap(self, root, contract):
        for resource in self.bootstrap_resources(root, contract):
            self.kubectl("apply", "-f", "-", resource=resource)

    def repository_credentials(self, contract, context):
        url = context["GITLAB_REPOSITORY_URL"]
        name = "repository-" + hashlib.sha256(url.encode()).hexdigest()[:16]
        resource = {"apiVersion": "external-secrets.io/v1", "kind": "ExternalSecret",
                    "metadata": {"name": name, "namespace": "infra"}, "spec": {
                        "refreshInterval": "1h", "secretStoreRef": {"name": "vault-backend", "kind": "ClusterSecretStore"},
                        "target": {"name": name, "creationPolicy": "Owner", "template": {
                            "metadata": {"labels": {"argocd.argoproj.io/secret-type": "repository"}},
                            "data": {"type": "git", "url": url, "username": "{{ .username }}", "password": "{{ .password }}"}}},
                        "data": [{"secretKey": key, "remoteRef": {"key": contract["registry"]["path"], "property": key}}
                                 for key in ("username", "password")]}}
        self.kubectl("apply", "-f", "-", resource=resource)

    def refresh_credentials(self, contract):
        paths = {contract["registry"]["path"], *(item["path"] for item in contract.get("vault", []))}
        inventory = self.kubectl("get", "externalsecrets", "-A", "-o", "json")
        for resource in inventory.get("items", []):
            metadata, spec = resource["metadata"], resource["spec"]
            references = {item.get("remoteRef", {}).get("key") for item in spec.get("data", [])}
            references.update(item.get("extract", {}).get("key") for item in spec.get("dataFrom", []))
            if metadata.get("namespace") in ("apps", "infra") and references & paths:
                self.refresh_external_secret(metadata["name"], metadata["namespace"])

    def refresh_external_secret(self, name, namespace):
        before = self.kubectl("get", "externalsecret", name, "-n", namespace, "-o", "json")
        old_refresh = before.get("status", {}).get("refreshTime")
        # ESO's refreshTime has whole-second precision. A first reconciliation
        # and our forced refresh must be distinguishable even on a fast cluster.
        if old_refresh:
            time.sleep(1.05)
        self.kubectl("annotate", "externalsecret", name, "-n", namespace, "force-sync=" + str(time.time_ns()), "--overwrite")
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            current = self.kubectl("get", "externalsecret", name, "-n", namespace, "-o", "json")
            status = current.get("status", {})
            if (status.get("refreshTime") and status["refreshTime"] != old_refresh
                    and any(item.get("type") == "Ready" and item.get("status") == "True" for item in status.get("conditions", []))):
                target = current.get("spec", {}).get("target", {}).get("name", name)
                secret = self.kubectl("get", "secret", target, "-n", namespace, "-o", "json")
                if secret.get("data"):
                    return
            time.sleep(2)
        raise OnboardingError(f"ExternalSecret {namespace}/{name} did not refresh its target credentials")

    def wait_pipeline(self, project_id, pipeline_id, required):
        deadline, last = time.monotonic() + self.timeout, None
        while time.monotonic() < deadline:
            pipeline = self.api.call("GET", f"projects/{project_id}/pipelines/{pipeline_id}")
            jobs = delivery_status(all_jobs(self.api, project_id, pipeline_id), required)
            observed = (pipeline["status"], tuple(jobs.items()))
            if observed != last:
                print("[DELIVERY] " + ", ".join(name + "=" + status for name, status in jobs.items()), flush=True)
                last = observed
            if all(status == "success" for status in jobs.values()):
                return
            if pipeline["status"] in ("failed", "canceled", "skipped", "success", "manual") or any(status == "manual" for status in jobs.values()):
                raise OnboardingError("Required delivery jobs did not all succeed; inspect the recorded pipeline and rerun after correcting it")
            time.sleep(10)
        raise OnboardingError("Timed out waiting for delivery; the pipeline is retained and a rerun resumes it")

    def wait_application(self, app, contract, expected_revision):
        name = app["metadata"]["name"]
        self.kubectl("annotate", "application", name, "-n", "infra", "argocd.argoproj.io/refresh=hard", "--overwrite")
        deadline = time.monotonic() + min(self.timeout, 900)
        while time.monotonic() < deadline:
            current = self.kubectl("get", "application", name, "-n", "infra", "-o", "json")
            source = current.get("spec", {}).get("source", {})
            if any(source.get(key) != app["spec"]["source"].get(key) for key in ("repoURL", "path", "targetRevision")):
                raise OnboardingError("The deployed Application does not match this repository's selected source")
            status = current.get("status", {})
            if (status.get("sync", {}).get("revision") == expected_revision
                    and status.get("sync", {}).get("status") == "Synced" and status.get("health", {}).get("status") == "Healthy"):
                for deployment in contract["readiness"]["deployments"]:
                    self.kubectl("rollout", "status", "deployment/" + deployment, "-n", "apps", "--timeout=120s")
                return status.get("sync", {}).get("revision", "")
            time.sleep(10)
        raise OnboardingError("Application did not become Synced/Healthy; rerun after resolving its rollout")

    def recover_pipeline(self, project_id, state, save):
        intent = state.get("pipeline_intent")
        if not intent:
            return
        candidates = []
        for page in range(1, 51):
            batch = self.api.call("GET", f"projects/{project_id}/pipelines?" + urlencode({
                "sha": intent["sha"], "source": "api", "per_page": 100, "page": page}))
            for pipeline in batch:
                variables = self.api.call("GET", f"projects/{project_id}/pipelines/{pipeline['id']}/variables")
                if any(item.get("key") == "ONBOARDING_RUN_ID" and item.get("value") == intent["id"] for item in variables):
                    candidates.append(pipeline)
            if len(batch) < 100:
                break
        else:
            raise OnboardingError("Too many pipelines to recover the pending creation safely")
        if len(candidates) > 1:
            raise OnboardingError("Multiple pipelines match the interrupted request; resolve them in GitLab before rerunning")
        if candidates:
            pipeline = candidates[0]
            state.update(pipeline_id=pipeline["id"], pipeline_sha=pipeline["sha"], pipeline_configuration=intent["configuration"])
            state.pop("pipeline_intent")
            save()
        else:
            raise OnboardingError("The interrupted pipeline request has no confirmed result yet; check GitLab before clearing pipeline_intent in the private journal")

    def restore_unpublished_pause(self, checkout, state, save):
        pause = state.get("paused_application")
        if not isinstance(pause, dict) or checkout.remote_head() != pause["source_sha"]:
            return
        current = self.kubectl("get", "application", pause["name"], "-n", "infra", "-o", "json")
        automated = current.get("spec", {}).get("syncPolicy", {}).get("automated")
        if current["metadata"]["uid"] != pause["uid"] or automated not in (None, pause["automated"]):
            raise OnboardingError("Application changed while setup was paused; review its sync policy before rerunning")
        if automated == pause["automated"]:
            state.pop("paused_application")
            save()
            return
        self.kubectl("patch", "application", pause["name"], "-n", "infra", "--type=json", "-p", json.dumps([
            {"op": "test", "path": "/metadata/resourceVersion", "value": current["metadata"]["resourceVersion"]},
            {"op": "add", "path": "/spec/syncPolicy/automated", "value": pause["automated"]}]))
        state.pop("paused_application")
        save()

    def run(self, slug, project):
        cluster = self.kubectl("get", "namespace", "kube-system", "-o", "json")["metadata"]["uid"]
        base = public_context(self.runner, slug, project)
        clone_url = os.environ.get("GITLAB_URL", self.runner.public_url).rstrip("/") + "/" + project["path_with_namespace"] + ".git"
        parsed_url = urlparse(clone_url)
        if parsed_url.scheme not in ("https", "http") or not parsed_url.hostname or parsed_url.username or parsed_url.password or parsed_url.query or parsed_url.fragment:
            raise OnboardingError("GitLab clone access must use an HTTP(S) URL without embedded credentials")
        with journal(project, cluster) as (state, save), Checkout(clone_url, project["default_branch"], os.environ["GITLAB_ADMIN_TOKEN"]) as checkout:
            self.recover_pipeline(project["id"], state, save)
            self.restore_unpublished_pause(checkout, state, save)
            contract = validate_contract(checkout.root)
            if "{{PLATFORM_SECURITY_PROJECT_PATH}}" in json.dumps(contract) and not base["PLATFORM_SECURITY_PROJECT_PATH"]:
                if os.environ.get("REPOSITORY_NONINTERACTIVE") != "true":
                    base["PLATFORM_SECURITY_PROJECT_PATH"] = input("Shared platform helper-image project path (group/project/security): ").strip()
                if not base["PLATFORM_SECURITY_PROJECT_PATH"]:
                    raise OnboardingError("Set PLATFORM_SECURITY_PROJECT_PATH to the installed platform's helper-image path")
            if base["PLATFORM_SECURITY_PROJECT_PATH"] and not re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+", base["PLATFORM_SECURITY_PROJECT_PATH"]):
                raise OnboardingError("PLATFORM_SECURITY_PROJECT_PATH must be a GitLab project/image path")
            settings_path = local_path(checkout.root, SETTINGS, existing=False)
            previous = load_json(settings_path) if settings_path.exists() else {}
            if previous and (previous.get("version") != 1 or not isinstance(previous.get("context"), dict)
                             or not isinstance(previous.get("bindings"), dict)
                             or any(not isinstance(value, str) or not value for value in previous["bindings"].values())):
                raise OnboardingError("Unsupported saved onboarding settings version")
            previous_context = previous.get("context", {})
            previous_hosts = expand(contract["dns"]["hosts"], previous_context) if previous_context else []
            if not previous_context:
                for filename in contract["files"]:
                    if filename.endswith((".yaml", ".yml")) and "/k8s/" in filename:
                        for document in yaml.safe_load_all(local_path(checkout.root, filename).read_text()):
                            if isinstance(document, dict) and document.get("kind") == "Ingress":
                                previous_hosts.extend(rule.get("host") for rule in document.get("spec", {}).get("rules", []) if rule.get("host"))
            context, secrets = collect_inputs(contract, base, previous, self.supplied_inputs(slug),
                                              os.environ.get("REPOSITORY_NONINTERACTIVE") != "true")
            app, settings = render(checkout.root, contract, context, previous)
            resolved = expand(contract, context)
            context = {**context, "APPLICATION_NAME": app["metadata"]["name"], "PREVIOUS_HOSTS": previous_hosts}
            print(f"[SETUP] {slug}@{checkout.sha[:12]} -> {', '.join(resolved['dns']['hosts'])}", flush=True)
            ci = self.validate_local(checkout, resolved, app)
            existing = self.kubectl("get", "application", app["metadata"]["name"], "-n", "infra", "--ignore-not-found", "-o", "json")
            if existing:
                old_url = existing.get("spec", {}).get("source", {}).get("repoURL", "")
                permitted_hosts = {urlparse(context["GITLAB_REPOSITORY_URL"]).hostname, urlparse(self.runner.public_url).hostname}
                if (urlparse(old_url).hostname not in permitted_hosts
                        or urlparse(old_url).path.removesuffix(".git") != "/" + project["path_with_namespace"]):
                    raise OnboardingError("Application name already belongs to another repository")
            cf_token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
            if not cf_token and os.environ.get("REPOSITORY_NONINTERACTIVE") != "true":
                cf_token = getpass.getpass("Cloudflare token for application DNS (input hidden): ")
            if not cf_token:
                raise OnboardingError("Set CLOUDFLARE_API_TOKEN to configure the declared DNS records")
            secrets["CLOUDFLARE_API_TOKEN"] = cf_token
            services = Services(self.api, self.kubectl, context, secrets)
            services.preflight(resolved, checkout.root)
            project_id = project["id"]
            previous_builds = project.get("builds_access_level", "enabled")
            self.api.call("PUT", f"projects/{project_id}", {"builds_access_level": "enabled"})
            lint = self.api.call("POST", f"projects/{project_id}/ci/lint", {"content": ci, "ref": project["default_branch"]})
            if not lint.get("valid"):
                self.api.call("PUT", f"projects/{project_id}", {"builds_access_level": previous_builds})
                raise OnboardingError("GitLab rejected the rendered pipeline configuration")
            configuration = digest(settings)
            if state.get("pipeline_id") and state.get("configuration") != configuration:
                pipeline = self.api.call("GET", f"projects/{project_id}/pipelines/{state['pipeline_id']}")
                if pipeline["status"] not in ("failed", "canceled", "success", "skipped"):
                    raise OnboardingError("An earlier onboarding pipeline is still active; finish it before changing settings")
            paths = [*contract["files"], contract["application"], SETTINGS]
            changed = bool(checkout.git("status", "--porcelain", "--", *paths))
            if changed and existing and existing.get("spec", {}).get("syncPolicy", {}).get("automated") is not None:
                state["paused_application"] = {"name": app["metadata"]["name"], "uid": existing["metadata"]["uid"],
                    "automated": existing["spec"]["syncPolicy"]["automated"], "source_sha": checkout.sha}
                save()
                self.kubectl("patch", "application", app["metadata"]["name"], "-n", "infra", "--type=json", "-p", json.dumps([
                    {"op": "test", "path": "/metadata/resourceVersion", "value": existing["metadata"]["resourceVersion"]},
                    {"op": "remove", "path": "/spec/syncPolicy/automated"}]))
            try:
                sha = checkout.publish(paths)
            except BaseException:
                self.restore_unpublished_pause(checkout, state, save)
                raise
            state.update(configuration=configuration, configured_sha=sha, phase="configured")
            save()
            services.provision(resolved, checkout.root)
            self.repository_credentials(resolved, context)
            self.bootstrap(checkout.root, resolved)
            self.refresh_credentials(resolved)
            self.api.call("PUT", f"projects/{project_id}", {"shared_runners_enabled": True,
                          "ci_config_path": ".gitlab-ci.yml", "ci_push_repository_for_job_token_allowed": True})
            services.publish_dns(resolved)
            state["phase"] = "provisioned"
            save()
            reuse = False
            if state.get("pipeline_id") and state.get("pipeline_configuration") == configuration:
                previous_pipeline = self.api.call("GET", f"projects/{project_id}/pipelines/{state['pipeline_id']}")
                reuse = (not changed and checkout.release_head(previous_pipeline) == sha) or sha == state.get("pipeline_sha")
                if not reuse and previous_pipeline["status"] not in ("failed", "canceled", "success", "skipped"):
                    raise OnboardingError("An earlier onboarding pipeline is still active for another source revision")
            if reuse:
                pipeline = self.api.call("GET", f"projects/{project_id}/pipelines/{state['pipeline_id']}")
                if pipeline.get("sha") != state.get("pipeline_sha"):
                    raise OnboardingError("Saved pipeline identity no longer matches its source revision")
                if pipeline["status"] == "failed":
                    self.api.call("POST", f"projects/{project_id}/pipelines/{pipeline['id']}/retry")
                elif pipeline["status"] in ("canceled", "skipped"):
                    reuse = False
            if not reuse:
                if checkout.remote_head() != sha:
                    raise OnboardingError("The source branch changed before release; rerun to configure its latest revision")
                intent = {"id": str(uuid.uuid4()), "sha": sha, "configuration": configuration}
                state["pipeline_intent"] = intent
                save()
                variables = {**resolved["pipeline"]["variables"], "ONBOARDING_EXPECTED_SHA": sha, "ONBOARDING_RUN_ID": intent["id"]}
                pipeline = self.api.call("POST", f"projects/{project_id}/pipeline", {
                    "ref": project["default_branch"], "variables": [{"key": key, "value": value} for key, value in variables.items()]})
                state.update(pipeline_id=pipeline["id"], pipeline_sha=pipeline["sha"], pipeline_configuration=configuration)
                state.pop("pipeline_intent")
                save()
                if pipeline["sha"] != sha:
                    self.api.call("POST", f"projects/{project_id}/pipelines/{pipeline['id']}/cancel")
                    raise OnboardingError("Pipeline selected a different revision and was canceled; rerun")
            state["phase"] = "pipeline"
            save()
            print(f"[PIPELINE] {pipeline['web_url']}", flush=True)
            self.wait_pipeline(project_id, pipeline["id"], resolved["pipeline"]["jobs"])
            release_head = checkout.release_head(pipeline)
            if not release_head:
                raise OnboardingError("The branch tip is not a verified output of this onboarding pipeline; rerun for its current source")
            state["head_after_release"] = release_head
            save()
            revision = self.wait_application(app, resolved, release_head)
            if checkout.remote_head() != revision:
                raise OnboardingError("The source changed during rollout verification; rerun for its current revision")
            state.update(phase="complete", deployed_revision=revision)
            state.pop("paused_application", None)
            save()
            print(f"[READY] {slug}: required delivery jobs succeeded; Application is Synced/Healthy and deployments are available", flush=True)
