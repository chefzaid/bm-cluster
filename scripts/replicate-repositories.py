#!/usr/bin/env python3
"""Repository import and declarative deployment orchestration for replicate-repo.sh."""

import base64
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlparse
from urllib.request import Request, build_opener, HTTPRedirectHandler

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ".github/workflows/sync-gitlab.yml"
APPLICATION_PATHS = ("infra/argocd/application.yaml", "argocd/application.yaml")
NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\Z")


class ReplicationError(Exception):
    pass


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
        self.internal_zone = os.environ.get("INTERNAL_DNS_ZONE") or (
            "internal." + urlparse(public_url).hostname.removeprefix("gitlab."))
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
                       "GITLAB_URL": self.public_url, "INITIALIZE_REPOSITORY_SYNC": "true"}
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

    def application(self, slug, project):
        project_id, branch = project["id"], project["default_branch"]
        ci = self.file(project_id, ".gitlab-ci.yml", branch)
        # GitLab owns semantic validation, including its custom !reference tag.
        if not ci or not isinstance(yaml.load(ci, Loader=yaml.BaseLoader), dict):
            raise ReplicationError("missing or invalid .gitlab-ci.yml")
        candidates = [(path, self.file(project_id, path, branch)) for path in APPLICATION_PATHS]
        candidates = [(path, content) for path, content in candidates if content]
        if len(candidates) != 1:
            raise ReplicationError("expected exactly one Argo CD Application at " + " or ".join(APPLICATION_PATHS))
        documents = list(yaml.safe_load_all(candidates[0][1]))
        if len(documents) != 1 or not isinstance(documents[0], dict):
            raise ReplicationError("Argo CD bootstrap must contain one Application")
        app = copy.deepcopy(documents[0])
        if app.get("apiVersion") != "argoproj.io/v1alpha1" or app.get("kind") != "Application":
            raise ReplicationError("Argo CD bootstrap must be an argoproj.io/v1alpha1 Application")
        metadata, spec = app.get("metadata"), app.get("spec")
        if not isinstance(metadata, dict) or not isinstance(spec, dict):
            raise ReplicationError("Application metadata and spec must be mappings")
        if not metadata.get("name") or metadata.get("namespace", self.namespace) != self.namespace:
            raise ReplicationError(f"Application needs a name and namespace {self.namespace}")
        source = spec.get("source")
        if (not isinstance(source, dict) or spec.get("sources") or
                not isinstance(source.get("path"), str) or not source["path"] or source.get("chart")):
            raise ReplicationError("Application needs one repository source with a local manifest path")
        source_path = PurePosixPath(source["path"])
        if source_path.is_absolute() or ".." in source_path.parts:
            raise ReplicationError("Application source.path must stay inside the imported repository")
        revision = source.get("targetRevision", "HEAD")
        if not isinstance(revision, str) or not revision:
            raise ReplicationError("Application targetRevision must be a branch, tag, or commit")
        tree = self.gitlab.call("GET", f"projects/{project_id}/repository/tree?" + urlencode({
            "path": str(source_path), "ref": branch if revision == "HEAD" else revision, "per_page": 1}), missing=True)
        if not tree:
            raise ReplicationError(f"Application source path {source_path} is missing or empty at {revision}")
        destination = spec.get("destination")
        if (not isinstance(destination, dict) or destination.get("server") != "https://kubernetes.default.svc"
                or not destination.get("namespace")):
            raise ReplicationError("Application must target a namespace in the local Kubernetes cluster")
        if not isinstance(source.get("repoURL"), str):
            raise ReplicationError("Application repoURL must identify the imported repository")
        original_path = urlparse(source["repoURL"]).path.removeprefix("/").removesuffix(".git")
        if original_path not in (slug, project["path_with_namespace"]):
            raise ReplicationError("Application repoURL does not identify this GitHub/GitLab repository")
        source["repoURL"] = f"http://gitlab.{self.internal_zone}/{project['path_with_namespace']}.git"
        metadata["namespace"] = self.namespace
        if not spec.get("project"):
            raise ReplicationError("Application spec.project is required")
        return ci, app

    def kubectl(self, *args, resource=None):
        result = subprocess.run(["kubectl", *args], input=None if resource is None else json.dumps(resource),
                                text=True, capture_output=True)
        if result.returncode:
            # Secret manifests and echoed API responses must not reach logs.
            raise ReplicationError("kubectl " + " ".join(args) + " failed; check cluster access, Argo CD, and resource permissions")
        return json.loads(result.stdout) if result.stdout.strip().startswith("{") else None

    def deploy(self, slug, project):
        ci, app = self.application(slug, project)
        self.kubectl("get", "crd", "applications.argoproj.io", "-o", "json")
        self.kubectl("get", "appproject", app["spec"]["project"], "-n", self.namespace, "-o", "json")
        existing = self.kubectl("get", "application", app["metadata"]["name"], "-n", self.namespace,
                                "--ignore-not-found", "-o", "json")
        if existing:
            existing_path = urlparse(existing.get("spec", {}).get("source", {}).get("repoURL", "")).path
            if existing_path != urlparse(app["spec"]["source"]["repoURL"]).path:
                raise ReplicationError("an Application with this name already manages another repository")
        self.kubectl("apply", "--dry-run=server", "-f", "-", resource=app)
        project_id = project["id"]
        previous_builds = project.get("builds_access_level", "enabled")
        self.gitlab.call("PUT", f"projects/{project_id}", {"builds_access_level": "enabled"})
        try:
            lint = self.gitlab.call("POST", f"projects/{project_id}/ci/lint", {
                "content": ci, "ref": project["default_branch"]})
            if not lint.get("valid"):
                raise ReplicationError("GitLab CI lint rejected .gitlab-ci.yml; inspect it in GitLab's Pipeline Editor")
            self.repository_credentials(project_id, app["spec"]["source"]["repoURL"])
            self.gitlab.call("PUT", f"projects/{project_id}", {
                "shared_runners_enabled": True, "ci_config_path": ".gitlab-ci.yml"})
            self.kubectl("apply", "-f", "-", resource=app)
            pipeline = self.gitlab.call("POST", f"projects/{project_id}/pipeline", {"ref": project["default_branch"]})
        except (ReplicationError, OSError):
            self.gitlab.call("PUT", f"projects/{project_id}", {"builds_access_level": previous_builds})
            raise
        print(f"[DEPLOY] {slug}: Application {app['metadata']['name']} applied; pipeline {pipeline['web_url']}", flush=True)

    def repository_credentials(self, project_id, url):
        name = "repository-" + hashlib.sha256(url.encode()).hexdigest()[:16]
        existing = self.kubectl("get", "secret", name, "-n", self.namespace, "--ignore-not-found", "-o", "json")
        if existing:
            data = existing.get("data", {})
            if base64.b64decode(data.get("url", "")).decode() != url or not data.get("password"):
                raise ReplicationError(f"Argo CD repository credential Secret {name} is inconsistent")
            return
        token = self.gitlab.call("POST", f"projects/{project_id}/deploy_tokens", {
            "name": "bm-cluster-argocd", "scopes": ["read_repository"]})
        secret = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                  "metadata": {"name": name, "namespace": self.namespace,
                               "labels": {"argocd.argoproj.io/secret-type": "repository"}},
                  "stringData": {"type": "git", "url": url, "username": token["username"], "password": token["token"]}}
        try:
            self.kubectl("apply", "-f", "-", resource=secret)
        except ReplicationError:
            self.gitlab.call("DELETE", f"projects/{project_id}/deploy_tokens/{token['id']}")
            raise


def main():
    repositories, group, public_url = inputs()
    if "--check-inputs" in sys.argv:
        return 0
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
        except (ReplicationError, yaml.YAMLError, OSError, UnicodeError) as error:
            print(f"[CANNOT DEPLOY] {slug}: {error}. Repository remains imported and synchronized.", file=sys.stderr, flush=True)
            failures.append(slug)
    print(f"[INFO] Imported and synchronized {len(imported)} repository/repositories; {len(set(failures))} need attention.")
    return 1 if failures else 0


if __name__ == "__main__":
    os.umask(0o077)
    try:
        sys.exit(main())
    except (ReplicationError, EOFError, KeyboardInterrupt) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        sys.exit(1)
