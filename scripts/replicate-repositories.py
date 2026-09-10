#!/usr/bin/env python3
"""Repository import and declarative deployment orchestration for replicate-repo.sh."""

import base64
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlparse
from urllib.request import Request, build_opener, HTTPRedirectHandler

import yaml

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts/lib"))
from repository_onboarding import Onboarding, OnboardingError, ServiceError
from onboarding_services import forward
WORKFLOW = ".github/workflows/sync-gitlab.yml"
NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\Z")


class ReplicationError(Exception):
    pass


@contextmanager
def gitlab_control_route():
    """Keep operator Git/API traffic on a temporary loopback route when available."""
    previous = os.environ.get("GITLAB_URL")
    if previous:
        yield
        return
    try:
        result = subprocess.run(
            ["kubectl", "--request-timeout=10s", "get", "service", "gitlab", "-n", "infra",
             "--ignore-not-found", "-o", "json"],
            text=True, capture_output=True, timeout=15, check=False)
        available = result.returncode == 0 and bool(json.loads(result.stdout or "{}"))
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        available = False
    if not available:
        # Import-only use from outside the cluster can still use public GitLab.
        yield
        return
    with forward("service/gitlab", 80) as url:
        os.environ["GITLAB_URL"] = url
        try:
            yield
        finally:
            if previous is None:
                os.environ.pop("GITLAB_URL", None)
            else:
                os.environ["GITLAB_URL"] = previous


def platform_context(*, required=False):
    """Read public installed settings; explicit operator environment always wins."""
    keys = ("PLATFORM_DOMAIN", "INTERNAL_DNS_ZONE", "KEYCLOAK_REALM", "GITLAB_PUBLIC_URL")
    context = {key: os.environ[key] for key in (*keys, "PLATFORM_SECURITY_PROJECT_PATH") if os.environ.get(key)}

    def resource(kind, name, namespace):
        try:
            result = subprocess.run(
                ["kubectl", "--request-timeout=10s", "get", kind, name, "-n", namespace,
                 "--ignore-not-found", "-o", "json"],
                text=True, capture_output=True, timeout=15, check=False)
            return json.loads(result.stdout) if result.returncode == 0 and result.stdout.strip() else {}
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
            return {}

    namespace = os.environ.get("GITLAB_NAMESPACE", "infra")
    if not all(context.get(key) for key in ("PLATFORM_DOMAIN", "INTERNAL_DNS_ZONE", "PLATFORM_SECURITY_PROJECT_PATH")):
        application = resource("application", "bm-cluster", "infra")
        source = application.get("spec", {}).get("source", {})
        repository = urlparse(source.get("repoURL", ""))
        project_path = repository.path.strip("/").removesuffix(".git")
        if ("PLATFORM_SECURITY_PROJECT_PATH" not in context and repository.scheme in ("http", "https", "ssh")
                and repository.hostname and len(project_path.split("/")) >= 2
                and all(NAME.fullmatch(part) for part in project_path.split("/"))):
            context["PLATFORM_SECURITY_PROJECT_PATH"] = project_path + "/security"
        helm = source.get("helm", {})
        try:
            inline = yaml.safe_load(helm.get("values", "")) or {}
        except yaml.YAMLError:
            inline = {}
        values = dict(inline) if isinstance(inline, dict) else {}
        values.update(helm.get("valuesObject") or {})
        values.update({item["name"]: item.get("value") for item in helm.get("parameters", []) if "name" in item})
        for key, name in (("PLATFORM_DOMAIN", "publicDomain"), ("INTERNAL_DNS_ZONE", "internalDnsZone")):
            if key not in context and values.get(name):
                context[key] = values[name]

    if "INTERNAL_DNS_ZONE" not in context:
        config = resource("configmap", "coredns-custom", "kube-system")
        zones = set()
        for value in config.get("data", {}).values():
            zones.update(re.findall(
                r"(?m)^\s*rewrite\s+stop\s+name\s+suffix\s+\.([^\s]+)\.\s+\.infra\.svc\.cluster\.local\.\s+answer\s+auto\s*$",
                value))
        if len(zones) == 1:
            context["INTERNAL_DNS_ZONE"] = zones.pop()

    if "KEYCLOAK_REALM" not in context or "PLATFORM_DOMAIN" not in context:
        deployment = resource("deployment", "oauth2-proxy", "infra")
        issuers = set()
        for container in deployment.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []):
            for argument in container.get("args", []):
                if argument.startswith("--oidc-issuer-url="):
                    issuers.add(argument.split("=", 1)[1])
        if len(issuers) == 1:
            issuer = urlparse(issuers.pop())
            match = re.fullmatch(r"/auth/realms/([A-Za-z0-9_.-]+)", issuer.path)
            if issuer.scheme == "https" and issuer.hostname and not issuer.username and not issuer.password and match:
                context.setdefault("KEYCLOAK_REALM", match[1])
                if issuer.hostname.startswith("keycloak."):
                    context.setdefault("PLATFORM_DOMAIN", issuer.hostname.removeprefix("keycloak."))

    if "GITLAB_PUBLIC_URL" not in context:
        ingress = resource("ingress", "gitlab-ingress", namespace)
        hosts = {item["host"] for item in ingress.get("spec", {}).get("rules", []) if item.get("host")}
        if len(hosts) == 1:
            context["GITLAB_PUBLIC_URL"] = "https://" + hosts.pop()
        elif context.get("PLATFORM_DOMAIN"):
            context["GITLAB_PUBLIC_URL"] = "https://gitlab." + context["PLATFORM_DOMAIN"]

    if "PLATFORM_DOMAIN" not in context and context.get("GITLAB_PUBLIC_URL"):
        host = urlparse(context["GITLAB_PUBLIC_URL"]).hostname or ""
        if host.startswith("gitlab."):
            context["PLATFORM_DOMAIN"] = host.removeprefix("gitlab.")
    for key in ("PLATFORM_DOMAIN", "INTERNAL_DNS_ZONE"):
        if key in context and (not isinstance(context[key], str) or not re.fullmatch(
                r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}", context[key])):
            raise ReplicationError(f"{key} must be a DNS zone; set its explicit environment override.")
    if context.get("PLATFORM_DOMAIN") and context.get("INTERNAL_DNS_ZONE") == context["PLATFORM_DOMAIN"]:
        raise ReplicationError("INTERNAL_DNS_ZONE must differ from PLATFORM_DOMAIN.")
    if "KEYCLOAK_REALM" in context and (not isinstance(context["KEYCLOAK_REALM"], str) or
            not re.fullmatch(r"[A-Za-z0-9_.-]+", context["KEYCLOAK_REALM"]) or context["KEYCLOAK_REALM"] == "master"):
        raise ReplicationError("KEYCLOAK_REALM must name the existing application realm.")
    security_path = context.get("PLATFORM_SECURITY_PROJECT_PATH")
    if security_path is not None and (not isinstance(security_path, str) or len(security_path.split("/")) < 2
            or any(not NAME.fullmatch(part) for part in security_path.split("/"))):
        raise ReplicationError("PLATFORM_SECURITY_PROJECT_PATH must be the installed platform's registry project path.")
    if required:
        missing = [key for key in keys if key not in context]
        if missing:
            raise ReplicationError("Unable to discover installed platform settings: " + ", ".join(missing) +
                                   ". Set these environment variables explicitly; no internal DNS zone is guessed.")
    return context


def names(value):
    result = []
    for name in value.split(","):
        name = name.strip()
        if not name or any(not NAME.fullmatch(part) for part in name.split("/")):
            raise ReplicationError("Use nonempty comma-separated repository names or owner/name entries.")
        if name in result:
            continue
        result.append(name)
    return result


def inputs():
    username = os.environ["GITHUB_USERNAME"]
    if not NAME.fullmatch(username):
        raise ReplicationError("Invalid GitHub username.")
    repositories = [name if "/" in name else f"{username}/{name}"
                    for name in names(os.environ["GITHUB_REPOSITORIES"])]
    if any(len(name.split("/")) != 2 for name in repositories):
        raise ReplicationError("GitHub repositories must use owner/name.")
    repositories = list(dict.fromkeys(repositories))
    if len({name.split("/")[1].lower() for name in repositories}) != len(repositories):
        raise ReplicationError("Different source owners cannot import the same name into one GitLab group.")
    group = os.environ["GITLAB_GROUP_PATH"]
    if any(not NAME.fullmatch(part) for part in group.split("/")):
        raise ReplicationError("Invalid GitLab group path.")
    url = os.environ["GITLAB_PUBLIC_URL"].rstrip("/")
    parsed = urlparse(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.path or parsed.query or parsed.fragment):
        raise ReplicationError("GITLAB_PUBLIC_URL must be a public HTTPS origin without credentials or a path.")
    selection = os.environ.get("DEPLOY_REPOSITORIES")
    if selection:
        select_repositories(selection, repositories)
    return repositories, group, url


def select_repositories(value, repositories):
    if value.strip().lower() == "none":
        return []
    if value.strip().lower() == "all":
        return repositories[:]
    selected = []
    for name in names(value):
        matches = [repo for repo in repositories if name in (repo, repo.split("/")[1])]
        if len(matches) != 1:
            raise ReplicationError(f"Deployment selection '{name}' is not an imported repository.")
        if matches[0] not in selected:
            selected.append(matches[0])
    return selected


class NoRedirect(HTTPRedirectHandler):
    # Never forward authentication to a redirected host (e.g. Cloudflare login).
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class API:
    def __init__(self, url, headers):
        self.url = url
        self.headers = headers
        self.opener = build_opener(NoRedirect())

    def call(self, method, path, data=None, missing=False):
        request = Request(f"{self.url}/{path}", method=method,
                          headers={**self.headers, "Content-Type": "application/json"},
                          data=None if data is None else json.dumps(data).encode())
        try:
            with self.opener.open(request, timeout=60) as response:
                content = response.read()
                return json.loads(content) if content else None
        except HTTPError as error:
            if missing and error.code == 404:
                return None
            # Responses can echo webhook headers or token request bodies.
            raise ReplicationError(f"{method} {path.split('?')[0]} returned HTTP {error.code}.") from None
        except (URLError, TimeoutError):
            raise ReplicationError(f"Unable to reach {self.url}; check routing and API access.") from None
        except json.JSONDecodeError:
            raise ReplicationError(f"{self.url} returned a non-JSON API response; check proxy authentication.") from None


class Replicator:
    def __init__(self, group, public_url):
        self.group = group
        self.public_url = public_url
        self.namespace = os.environ.get("GITLAB_NAMESPACE", "infra")
        self.internal_zone = os.environ.get("INTERNAL_DNS_ZONE", "")
        self.github = API("https://api.github.com", {
            "Authorization": f"Bearer {os.environ['GITHUB_ADMIN_TOKEN']}",
            "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
        # The sync runner needs the public URL. Control-plane API access can use
        # the internal Service to avoid browser-only authentication at the edge.
        self.gitlab = API(os.environ.get("GITLAB_URL", public_url).rstrip("/") + "/api/v4",
                          {"PRIVATE-TOKEN": os.environ["GITLAB_ADMIN_TOKEN"]})

    def ensure_group(self):
        parent = None
        for index, part in enumerate(self.group.split("/"), 1):
            path = "/".join(self.group.split("/")[:index])
            group = self.gitlab.call("GET", f"groups/{quote(path, safe='')}", missing=True)
            if group is None:
                payload = {"name": part, "path": part, "visibility": "private"}
                if parent is not None:
                    payload["parent_id"] = parent
                group = self.gitlab.call("POST", "groups", payload)
            parent = group["id"]
        return parent

    def import_repository(self, slug, group_id):
        source = self.github.call("GET", f"repos/{slug}")
        if source.get("archived") or source.get("disabled") or not source.get("permissions", {}).get("admin"):
            raise ReplicationError("GitHub repository must be writable with Administration permission.")
        branch = source["default_branch"]
        self.github.call("GET", f"repos/{slug}/branches/{quote(branch, safe='')}")
        path = f"{self.group}/{slug.split('/')[1]}"
        project = self.gitlab.call("GET", f"projects/{quote(path, safe='')}", missing=True)
        if project is None:
            project = self.gitlab.call("POST", "projects", {
                "name": slug.split("/")[1], "path": slug.split("/")[1], "namespace_id": group_id,
                "visibility": "private", "initialize_with_readme": False,
                "builds_access_level": "disabled", "shared_runners_enabled": True,
                "container_registry_access_level": "private", "package_registry_access_level": "private"})
        if project.get("archived"):
            raise ReplicationError("Destination GitLab project is archived.")
        if source.get("private") and project.get("visibility") != "private":
            raise ReplicationError("Private GitHub source requires a private GitLab destination; fix its visibility first.")

        workflow_path = f"repos/{slug}/contents/{WORKFLOW}"
        existing = self.github.call("GET", workflow_path + "?" + urlencode({"ref": branch}), missing=True)
        template = (ROOT / WORKFLOW).read_bytes()
        current = base64.b64decode(existing["content"]) if existing else b""
        if existing and current != template:
            parsed = yaml.load(current, Loader=yaml.BaseLoader)
            if not isinstance(parsed, dict) or parsed.get("name") != "Sync GitHub and GitLab":
                raise ReplicationError(f"{WORKFLOW} contains an unmanaged workflow; move it before rerunning.")
        if current != template:
            # Avoid starting a push workflow before credentials/webhooks exist.
            payload = {"message": "ci: configure bidirectional GitHub and GitLab sync [skip ci]",
                       "content": base64.b64encode(template).decode(), "branch": branch}
            if existing:
                payload["sha"] = existing["sha"]
            self.github.call("PUT", workflow_path, payload)
        self.github.call("PUT", f"repos/{slug}/actions/workflows/sync-gitlab.yml/enable")
        environment = {**os.environ, "GITHUB_OWNER": slug.split("/")[0],
                       "GITHUB_REPOSITORY": slug.split("/")[1], "GITLAB_PROJECT_PATH": path,
                       "GITLAB_URL": self.public_url, "GITLAB_API_BASE_URL": self.gitlab.url.removesuffix("/api/v4"),
                       "INITIALIZE_REPOSITORY_SYNC": "true"}
        subprocess.run([str(ROOT / "scripts/configure-repository-sync.sh")], env=environment, check=True)
        project = self.gitlab.call("GET", f"projects/{project['id']}")
        if not project.get("default_branch"):
            raise ReplicationError("Synchronization finished without a GitLab default branch.")
        return project

    def file(self, project_id, path, ref):
        value = self.gitlab.call("GET", f"projects/{project_id}/repository/files/{quote(path, safe='')}?"
                                 + urlencode({"ref": ref}), missing=True)
        if value is None:
            return None
        return base64.b64decode(value["content"]).decode()

    def kubectl(self, *args, resource=None):
        result = subprocess.run(["kubectl", "--request-timeout=30s", *args], input=None if resource is None else json.dumps(resource),
                                text=True, capture_output=True, timeout=180)
        if result.returncode:
            # Secret manifests and echoed API responses must not reach logs.
            raise ReplicationError("kubectl " + " ".join(args) + " failed; check cluster access, Argo CD, and resource permissions")
        return json.loads(result.stdout) if result.stdout.strip().startswith("{") else None

    def deploy(self, slug, project):
        context = platform_context(required=True)
        os.environ.update(context)
        self.internal_zone = context["INTERNAL_DNS_ZONE"]
        Onboarding(self).run(slug, project)


def main():
    if "--platform-context" in sys.argv:
        print(json.dumps(platform_context()))
        return 0
    repositories, group, public_url = inputs()
    if "--check-inputs" in sys.argv:
        return 0
    with gitlab_control_route():
        return replicate(repositories, group, public_url)


def replicate(repositories, group, public_url):
    replicator = Replicator(group, public_url)
    user = replicator.github.call("GET", "user")
    if user["login"].lower() != os.environ["GITHUB_USERNAME"].lower():
        raise ReplicationError("GitHub token belongs to a different username; use owner/name for organization repositories.")
    group_id = replicator.ensure_group()
    imported, failures = {}, []
    for slug in repositories:
        print(f"[IMPORT] {slug} -> {group}/{slug.split('/')[1]}", flush=True)
        try:
            imported[slug] = replicator.import_repository(slug, group_id)
        except (ReplicationError, subprocess.CalledProcessError, yaml.YAMLError, OSError, UnicodeError) as error:
            print(f"[FAILED] {slug}: {error}", file=sys.stderr, flush=True)
            failures.append(slug)
    if not imported:
        raise ReplicationError("No repositories were successfully imported; fix the reported errors and rerun.")
    value = os.environ.get("DEPLOY_REPOSITORIES")
    if not value:
        import readline
        default = ",".join(slug.split("/")[1] for slug in imported)
        readline.set_startup_hook(lambda: readline.insert_text(default))
        try:
            value = input(f"Repositories to deploy (comma separated; 'none' to skip) [{default}]: ") or default
        finally:
            readline.set_startup_hook()
    selected = select_repositories(value, repositories if os.environ.get("DEPLOY_REPOSITORIES") else list(imported))
    for slug in selected:
        if slug not in imported:
            continue
        try:
            replicator.deploy(slug, imported[slug])
        except (ReplicationError, OnboardingError, ServiceError, yaml.YAMLError, OSError, UnicodeError, subprocess.SubprocessError) as error:
            print(f"[CANNOT DEPLOY] {slug}: {error}. Repository remains imported and synchronized.", file=sys.stderr, flush=True)
            failures.append(slug)
    print(f"[INFO] Imported and synchronized {len(imported)} repository/repositories; {len(set(failures))} need attention.")
    return 1 if failures else 0


if __name__ == "__main__":
    os.umask(0o077)
    try:
        sys.exit(main())
    except (ReplicationError, OnboardingError, ServiceError, EOFError, KeyboardInterrupt) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        sys.exit(1)
