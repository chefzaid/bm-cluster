#!/usr/bin/env python3
"""Offline behavioral checks: no credentials, service APIs, or cluster required."""

import base64
import contextlib
import copy
import importlib.util
import io
import json
import os
import shlex
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import yaml

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("replication", ROOT / "scripts/replicate-repositories.py")
replication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replication)

ENV = {"GITHUB_USERNAME": "alice", "GITHUB_ADMIN_TOKEN": "fixture-github",
       "GITHUB_REPOSITORIES": "web, org/api", "GITLAB_GROUP_PATH": "team",
       "GITLAB_ADMIN_TOKEN": "fixture-gitlab", "GITLAB_PUBLIC_URL": "https://gitlab.example.com",
       "PLATFORM_DOMAIN": "example.com", "INTERNAL_DNS_ZONE": "services.internal", "KEYCLOAK_REALM": "people",
       "PLATFORM_SECURITY_PROJECT_PATH": "platform/infrastructure/security"}
PROJECT = {"id": 7, "path_with_namespace": "team/web", "default_branch": "main",
           "builds_access_level": "disabled", "visibility": "private"}
APP = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application",
       "metadata": {"name": "web", "namespace": "infra"},
       "spec": {"project": "default", "source": {"repoURL": "https://github.com/alice/web.git",
                "path": "infra/k8s", "targetRevision": "main"},
                "destination": {"server": "https://kubernetes.default.svc", "namespace": "apps"}}}


class ReplicationTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, ENV, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        route = patch.object(replication, "gitlab_control_route", side_effect=contextlib.nullcontext)
        route.start()
        self.addCleanup(route.stop)
        self.runner = replication.Replicator("team", ENV["GITLAB_PUBLIC_URL"])
        self.runner.github = Mock()
        self.runner.gitlab = Mock(url=ENV["GITLAB_PUBLIC_URL"] + "/api/v4")

    def files(self, app=APP, ci="build:\n  script: echo test\n", tree=None):
        documents = {".gitlab-ci.yml": ci, "infra/argocd/application.yaml": yaml.safe_dump(app)}
        self.runner.file = Mock(side_effect=lambda project, path, ref: documents.get(path))
        self.runner.gitlab.call.return_value = [{"name": "kustomization.yaml"}] if tree is None else tree
        return documents

    def test_names_and_explicit_selection(self):
        repositories, group, url = replication.inputs()
        self.assertEqual(repositories, ["alice/web", "org/api"])
        self.assertEqual(group, "team")
        self.assertEqual(url, ENV["GITLAB_PUBLIC_URL"])
        self.assertEqual(replication.select_repositories("api, alice/web,api", repositories), ["org/api", "alice/web"])
        self.assertEqual(replication.select_repositories("none", repositories), [])
        self.assertEqual(replication.select_repositories("all", repositories), repositories)

    def test_invalid_inputs_fail_before_mutations(self):
        for key, value in [("GITHUB_REPOSITORIES", "web,"), ("GITHUB_REPOSITORIES", "a/web,b/web"),
                           ("GITHUB_REPOSITORIES", "../secret"), ("GITHUB_REPOSITORIES", "a/b/c"),
                           ("GITLAB_PUBLIC_URL", "https://token@gitlab.example.com"),
                           ("GITLAB_PUBLIC_URL", "http://gitlab.example.com"),
                           ("DEPLOY_REPOSITORIES", "unknown")]:
            with self.subTest(key=key, value=value), patch.dict(os.environ, {key: value}):
                with self.assertRaises(replication.ReplicationError):
                    replication.inputs()

    def test_group_creation_handles_nested_groups_privately(self):
        self.runner.group = "team/nested"
        self.runner.gitlab.call.side_effect = [{"id": 3}, None, {"id": 4}]
        self.assertEqual(self.runner.ensure_group(), 4)
        self.assertEqual(self.runner.gitlab.call.call_args.args,
                         ("POST", "groups", {"name": "nested", "path": "nested", "visibility": "private", "parent_id": 3}))

    def prepare_import(self, existing_project=None, existing_workflow=None):
        self.runner.github.call.side_effect = [
            {"default_branch": "main", "private": True, "permissions": {"admin": True}},
            {"name": "main"}, existing_workflow, None, None]
        self.runner.gitlab.call.side_effect = [existing_project, PROJECT, PROJECT] if existing_project is None else [existing_project, PROJECT]

    @patch.object(replication.subprocess, "run")
    def test_import_installs_workflow_and_disables_new_project_ci(self, run):
        self.prepare_import()
        self.assertEqual(self.runner.import_repository("alice/web", 3), PROJECT)
        create = self.runner.gitlab.call.call_args_list[1].args[2]
        self.assertEqual(create["visibility"], "private")
        self.assertEqual(create["builds_access_level"], "disabled")
        self.assertFalse(create["initialize_with_readme"])
        put = self.runner.github.call.call_args_list[3].args
        self.assertEqual(put[:2], ("PUT", "repos/alice/web/contents/" + replication.WORKFLOW))
        self.assertEqual(base64.b64decode(put[2]["content"]), (ROOT / replication.WORKFLOW).read_bytes())
        self.assertEqual(run.call_args.kwargs["env"]["INITIALIZE_REPOSITORY_SYNC"], "true")
        self.assertEqual(run.call_args.kwargs["env"]["GITLAB_PROJECT_PATH"], "team/web")
        self.assertEqual(run.call_args.kwargs["env"]["GITLAB_URL"], ENV["GITLAB_PUBLIC_URL"])
        self.assertEqual(run.call_args.kwargs["env"]["GITLAB_API_BASE_URL"], ENV["GITLAB_PUBLIC_URL"])
        self.assertTrue(run.call_args.kwargs["check"])

    @patch.object(replication.subprocess, "run")
    def test_import_passes_private_api_origin_without_replacing_public_sync_url(self, run):
        self.runner.gitlab.url = "http://127.0.0.1:43210/api/v4"
        self.prepare_import()
        self.runner.import_repository("alice/web", 3)
        self.assertEqual(run.call_args.kwargs["env"]["GITLAB_API_BASE_URL"], "http://127.0.0.1:43210")
        self.assertEqual(run.call_args.kwargs["env"]["GITLAB_URL"], ENV["GITLAB_PUBLIC_URL"])

    @patch.object(replication.subprocess, "run")
    def test_rerun_reuses_existing_workflow_and_preserves_visibility(self, run):
        workflow = {"content": base64.b64encode((ROOT / replication.WORKFLOW).read_bytes()).decode()}
        self.prepare_import(PROJECT, workflow)
        self.runner.import_repository("alice/web", 3)
        self.assertTrue(all(call.args[0] == "GET" for call in self.runner.gitlab.call.call_args_list))
        self.assertFalse(any(call.args[:2] == ("PUT", "repos/alice/web/contents/" + replication.WORKFLOW)
                             for call in self.runner.github.call.call_args_list))

    def test_private_source_cannot_leak_into_public_destination(self):
        self.prepare_import({**PROJECT, "visibility": "public"})
        with self.assertRaisesRegex(replication.ReplicationError, "private GitLab"):
            self.runner.import_repository("alice/web", 3)
        self.assertEqual(self.runner.github.call.call_count, 2)

    def test_custom_workflow_is_not_overwritten(self):
        self.prepare_import(PROJECT, {"content": base64.b64encode(b"name: Other\n").decode()})
        with self.assertRaisesRegex(replication.ReplicationError, "unmanaged workflow"):
            self.runner.import_repository("alice/web", 3)

    def test_deployment_delegates_to_generic_onboarding(self):
        with patch.object(replication, "Onboarding") as onboarding:
            self.runner.deploy("alice/web", PROJECT)
        onboarding.assert_called_once_with(self.runner)
        onboarding.return_value.run.assert_called_once_with("alice/web", PROJECT)

    def test_onboarding_failure_is_reported_without_a_second_deployment_path(self):
        with patch.object(replication, "Onboarding") as onboarding:
            onboarding.return_value.run.side_effect = replication.OnboardingError("missing contract")
            with self.assertRaisesRegex(replication.OnboardingError, "missing contract"):
                self.runner.deploy("alice/web", PROJECT)
        self.runner.gitlab.call.assert_not_called()

    def test_batch_continues_after_failed_import_and_deployment(self):
        self.runner.github.call.return_value = {"login": "alice"}
        self.runner.ensure_group = Mock(return_value=3)
        self.runner.import_repository = Mock(side_effect=[replication.ReplicationError("no access"), PROJECT])
        self.runner.deploy = Mock(side_effect=replication.ReplicationError("missing .gitlab-ci.yml"))
        with patch.dict(os.environ, {"DEPLOY_REPOSITORIES": "all"}), patch.object(replication, "Replicator", return_value=self.runner), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(replication.main(), 1)
        self.runner.deploy.assert_called_once_with("org/api", PROJECT)
        self.assertIn("[FAILED] alice/web", errors.getvalue())
        self.assertIn("[CANNOT DEPLOY] org/api", errors.getvalue())

    def test_interactive_default_is_all_successful_imports_after_imports(self):
        self.runner.github.call.return_value = {"login": "alice"}
        self.runner.ensure_group = Mock(return_value=3)
        self.runner.import_repository = Mock(return_value=PROJECT)
        self.runner.deploy = Mock()

        def answer(prompt):
            self.assertEqual(self.runner.import_repository.call_count, 2)
            self.assertIn("[web,api]", prompt)
            self.runner.deploy.assert_not_called()
            return ""

        with patch.object(replication, "Replicator", return_value=self.runner), patch("builtins.input", side_effect=answer), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(replication.main(), 0)
        self.assertEqual(self.runner.deploy.call_count, 2)

    def test_entrypoint_requires_explicit_noninteractive_deployment_selection(self):
        env = {**os.environ, "PATH": os.defpath}
        result = subprocess.run([str(ROOT / "replicate-repo.sh"), "--yes"], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Set DEPLOY_REPOSITORIES", result.stderr)
        self.assertNotIn(ENV["GITHUB_ADMIN_TOKEN"], result.stdout + result.stderr)


class GitLabControlRouteTests(unittest.TestCase):
    def test_main_uses_a_private_route_and_restores_the_environment_after_failure(self):
        for previous in (None, ""):
            environment = {**ENV}
            if previous is not None:
                environment["GITLAB_URL"] = previous

            def operation(*args):
                self.assertEqual(os.environ["GITLAB_URL"], "http://127.0.0.1:43210")
                self.assertEqual(os.environ["GITLAB_PUBLIC_URL"], ENV["GITLAB_PUBLIC_URL"])
                runner = replication.Replicator("engineering", ENV["GITLAB_PUBLIC_URL"])
                self.assertEqual(runner.gitlab.url, "http://127.0.0.1:43210/api/v4")
                raise replication.ReplicationError("fixture failure")

            service = subprocess.CompletedProcess([], 0, '{"metadata":{"name":"gitlab"}}', "")
            with self.subTest(previous=previous), patch.dict(os.environ, environment, clear=True), \
                    patch.object(replication.subprocess, "run", return_value=service), \
                    patch.object(replication, "forward", return_value=contextlib.nullcontext("http://127.0.0.1:43210")) as forward, \
                    patch.object(replication, "replicate", side_effect=operation):
                with self.assertRaisesRegex(replication.ReplicationError, "fixture failure"):
                    replication.main()
                forward.assert_called_once_with("service/gitlab", 80)
                self.assertEqual(os.environ.get("GITLAB_URL"), previous)

    def test_explicit_control_url_wins_without_cluster_access(self):
        with patch.dict(os.environ, {**ENV, "GITLAB_URL": "http://explicit.internal:8080"}, clear=True), \
                patch.object(replication.subprocess, "run") as run, patch.object(replication, "forward") as forward:
            with replication.gitlab_control_route():
                self.assertEqual(os.environ["GITLAB_URL"], "http://explicit.internal:8080")
            run.assert_not_called()
            forward.assert_not_called()
            self.assertEqual(os.environ["GITLAB_URL"], "http://explicit.internal:8080")

    def test_import_outside_cluster_keeps_public_access(self):
        with patch.dict(os.environ, ENV, clear=True), patch.object(replication.subprocess, "run", side_effect=FileNotFoundError), \
                patch.object(replication, "forward") as forward:
            with replication.gitlab_control_route():
                runner = replication.Replicator("engineering", ENV["GITLAB_PUBLIC_URL"])
                self.assertEqual(runner.gitlab.url, ENV["GITLAB_PUBLIC_URL"] + "/api/v4")
            forward.assert_not_called()
            self.assertNotIn("GITLAB_URL", os.environ)


class PlatformContextTests(unittest.TestCase):
    def discovery(self, resources, environment=None, required=True):
        def get(command, **kwargs):
            self.assertEqual(command[:3], ["kubectl", "--request-timeout=10s", "get"])
            self.assertNotIn("secret", command)
            resource = resources.get((command[3], command[4]), {})
            return subprocess.CompletedProcess(command, 0, json.dumps(resource), "")
        with patch.dict(os.environ, environment or {}, clear=True), patch.object(replication.subprocess, "run", side_effect=get):
            return replication.platform_context(required=required)

    def test_helm_parameter_precedence_and_live_issuer(self):
        resources = {
            ("application", "bm-cluster"): {"spec": {"source": {"helm": {
                "values": "publicDomain: inline.invalid\ninternalDnsZone: inline.internal\n",
                "valuesObject": {"publicDomain": "object.invalid", "internalDnsZone": "object.internal"},
                "parameters": [{"name": "publicDomain", "value": "example.com"},
                               {"name": "internalDnsZone", "value": "services.internal"}]}}}},
            ("deployment", "oauth2-proxy"): {"spec": {"template": {"spec": {"containers": [
                {"args": ["--oidc-issuer-url=https://keycloak.example.com/auth/realms/people"]}]}}}},
            ("ingress", "gitlab-ingress"): {"spec": {"rules": [{"host": "source.example.com"}]}}}
        result = self.discovery(resources)
        self.assertEqual(result, {"PLATFORM_DOMAIN": "example.com", "INTERNAL_DNS_ZONE": "services.internal",
                                  "KEYCLOAK_REALM": "people", "GITLAB_PUBLIC_URL": "https://source.example.com"})

    def test_legacy_coredns_and_issuer_discovery_does_not_invent_a_zone(self):
        resources = {
            ("configmap", "coredns-custom"): {"data": {"aliases.override":
                "rewrite stop name suffix .services.internal. .infra.svc.cluster.local. answer auto\n"}},
            ("deployment", "oauth2-proxy"): {"spec": {"template": {"spec": {"containers": [
                {"args": ["--oidc-issuer-url=https://keycloak.example.com/auth/realms/people"]}]}}}}}
        self.assertEqual(self.discovery(resources)["INTERNAL_DNS_ZONE"], "services.internal")
        del resources[("configmap", "coredns-custom")]
        with self.assertRaisesRegex(replication.ReplicationError, "INTERNAL_DNS_ZONE.*no internal DNS zone is guessed"):
            self.discovery(resources)
        self.assertNotIn("INTERNAL_DNS_ZONE", self.discovery(resources, required=False))

    def test_explicit_settings_do_not_need_cluster_access(self):
        environment = {name: ENV[name] for name in ("PLATFORM_DOMAIN", "INTERNAL_DNS_ZONE", "KEYCLOAK_REALM", "GITLAB_PUBLIC_URL", "PLATFORM_SECURITY_PROJECT_PATH")}
        with patch.dict(os.environ, environment, clear=True), patch.object(replication.subprocess, "run") as run:
            self.assertEqual(replication.platform_context(required=True), environment)
            run.assert_not_called()

    def test_security_images_follow_platform_project_when_app_group_differs(self):
        environment = {**ENV, "GITLAB_GROUP_PATH": "engineering"}
        environment.pop("PLATFORM_SECURITY_PROJECT_PATH")
        resources = {("application", "bm-cluster"): {"spec": {"source": {
            "repoURL": "http://gitlab.services.internal/platform/infrastructure.git"}}}}
        context = self.discovery(resources, environment)
        self.assertEqual(context["PLATFORM_SECURITY_PROJECT_PATH"], "platform/infrastructure/security")
        self.assertNotIn("engineering", context["PLATFORM_SECURITY_PROJECT_PATH"])
        context = self.discovery(resources, {**environment, "PLATFORM_SECURITY_PROJECT_PATH": "images/shared/helpers"})
        self.assertEqual(context["PLATFORM_SECURITY_PROJECT_PATH"], "images/shared/helpers")
        # Import-only flows remain available without an installed platform chart.
        self.assertNotIn("PLATFORM_SECURITY_PROJECT_PATH", self.discovery({}, environment, required=False))

    def test_ambiguous_coredns_and_invalid_explicit_values_fail(self):
        resources = {("configmap", "coredns-custom"): {"data": {"aliases.override":
            "rewrite stop name suffix .first.internal. .infra.svc.cluster.local. answer auto\n"
            "rewrite stop name suffix .second.internal. .infra.svc.cluster.local. answer auto\n"}}}
        with self.assertRaisesRegex(replication.ReplicationError, "INTERNAL_DNS_ZONE"):
            self.discovery(resources, {"PLATFORM_DOMAIN": "example.com", "KEYCLOAK_REALM": "people", "GITLAB_PUBLIC_URL": "https://gitlab.example.com"})
        for value in ("https://services.internal", "services.internal; bad", "example.com"):
            with self.subTest(value=value), self.assertRaises(replication.ReplicationError):
                self.discovery({}, {**ENV, "INTERNAL_DNS_ZONE": value})


class SyncBootstrapTests(unittest.TestCase):
    def test_admin_api_uses_private_origin_but_github_variables_keep_public_urls(self):
        with tempfile.TemporaryDirectory(prefix="sync-bootstrap-test.") as directory:
            root = Path(directory)
            log = root / "requests.jsonl"
            curl = root / "curl"
            curl.write_text('''#!/usr/bin/env python3
import base64, json, os, pathlib, sys
from urllib.parse import urlparse
args = sys.argv[1:]
url = next(value for value in args if value.startswith(("https://", "http://")))
path = urlparse(url).path
method = args[args.index("--request") + 1] if "--request" in args else "GET"
request = {"url": url, "method": method}
if "/actions/variables" in path and "--data-binary" in args:
    request["body"] = json.loads(pathlib.Path(args[args.index("--data-binary") + 1][1:]).read_text())
with open(os.environ["MOCK_REQUESTS"], "a") as output:
    output.write(json.dumps(request) + "\\n")
result = {}
status = "200"
if path == "/api/v4/projects/team%2Fweb": result = {"id": 7}
elif path == "/repos/alice/web": result = {"default_branch": "main"}
elif path == "/repos/alice/web/actions/secrets":
    result = {"secrets": [{"name": value} for value in ("GITLAB_SYNC_USERNAME", "GITLAB_SYNC_TOKEN", "REPOSITORY_SYNC_ADMIN_TOKEN")]}
elif path.endswith("/actions/secrets/public-key"):
    result = {"key_id": "fixture", "key": base64.b64encode(bytes([9]) + bytes(31)).decode()}
elif path == "/api/v4/projects/7/access_tokens":
    result = [{"id": 20, "name": "github-actions-sync", "active": True, "revoked": False,
               "scopes": ["write_repository", "self_rotate"], "expires_at": "2099-01-01"}]
elif "/actions/variables/" in path and method == "GET": status = "404"
elif path == "/api/v4/projects/7/hooks": result = [] if method == "GET" else {"id": 11}
elif path == "/api/v4/projects/7/hooks/11" and method == "GET":
    result = {"url": "https://api.github.com/repos/alice/web/dispatches", "push_events": True,
              "tag_push_events": True, "enable_ssl_verification": True, "custom_webhook_template": "fixture",
              "custom_headers": [{"key": key} for key in ("Accept", "Authorization", "X-GitHub-Api-Version")]}
if "--output" in args:
    pathlib.Path(args[args.index("--output") + 1]).write_text(json.dumps(result))
else: print(json.dumps(result), end="")
if "--write-out" in args: print(status, end="")
''')
            curl.chmod(0o755)
            environment = {**os.environ, **ENV, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                           "GITHUB_OWNER": "alice", "GITHUB_REPOSITORY": "web", "GITLAB_PROJECT_PATH": "team/web",
                           "GITLAB_URL": "https://gitlab.example.com", "GITLAB_API_BASE_URL": "http://127.0.0.1:43210",
                           "INITIALIZE_REPOSITORY_SYNC": "false", "MOCK_REQUESTS": str(log)}
            result = subprocess.run(["bash", str(ROOT / "scripts/configure-repository-sync.sh")],
                                    cwd=ROOT, env=environment, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for key in ("GITHUB_ADMIN_TOKEN", "GITLAB_ADMIN_TOKEN"):
                self.assertNotIn(ENV[key], result.stdout + result.stderr + log.read_text())
            requests = [json.loads(line) for line in log.read_text().splitlines()]
            api_urls = [item["url"] for item in requests if "/api/v4/" in item["url"]]
            self.assertGreaterEqual(len(api_urls), 6)
            self.assertTrue(all(url.startswith("http://127.0.0.1:43210/api/v4/") for url in api_urls))
            variables = {item["body"]["name"]: item["body"]["value"] for item in requests if "body" in item}
            self.assertEqual(variables["GITLAB_API_URL"], "https://gitlab.example.com/api/v4")
            self.assertEqual(variables["GITLAB_HOST"], "gitlab.example.com")
            self.assertEqual(variables["GITLAB_REPOSITORY"], "https://gitlab.example.com/team/web.git")
            self.assertNotIn("127.0.0.1", json.dumps(variables))


class SyncWorkflowTests(unittest.TestCase):
    """Execute the shipped Git reconciler with real local repositories and fake API."""

    def test_two_way_branches_tags_and_conflict_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            github, gitlab, source = (root / name for name in ("github.git", "gitlab.git", "source"))
            env = {**os.environ, "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
                   "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}

            def git(*args, cwd=source):
                return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, text=True, capture_output=True).stdout.strip()

            for bare in (github, gitlab):
                git("init", "--bare", "--initial-branch=main", str(bare), cwd=root)
            git("init", "--initial-branch=main", str(source), cwd=root)
            (source / "file").write_text("initial\n")
            git("add", ".")
            git("commit", "-m", "initial")
            git("push", str(github), "main")
            binaries = root / "bin"
            binaries.mkdir()
            curl = binaries / "curl"
            curl.write_text('#!/bin/sh\nprintf \'{"expires_at":"2099-01-01"}\\n\'\n')
            curl.chmod(0o700)
            # New Git versions create remote HEAD aliases on fetch. Reproduce
            # that behavior on older test hosts too: aliases must never become
            # real branches or participate in the final ref comparison.
            git_wrapper = binaries / "git"
            git_wrapper.write_text(f'''#!/bin/sh
real_git={shlex.quote(shutil.which("git"))}
"$real_git" "$@" || exit "$?"
if [ "$1" = fetch ]; then
  for remote in github gitlab; do
    if "$real_git" show-ref --verify --quiet "refs/remotes/$remote/main"; then
      "$real_git" symbolic-ref "refs/remotes/$remote/HEAD" "refs/remotes/$remote/main" || exit "$?"
    fi
  done
fi
''')
            git_wrapper.chmod(0o700)
            event = root / "event.json"
            event.write_text("{}")
            workflow = yaml.load((ROOT / replication.WORKFLOW).read_text(), Loader=yaml.BaseLoader)
            script = workflow["jobs"]["sync-repository"]["steps"][0]["run"]
            env.update({"PATH": f"{binaries}:{os.environ['PATH']}", "GITHUB_REPOSITORY": "alice/web",
                        "GITHUB_ADMIN_TOKEN": "fixture", "GITLAB_TOKEN": "fixture", "GITLAB_USERNAME": "reader",
                        "GITLAB_HOST": "gitlab.example.com", "GITLAB_API_URL": "https://gitlab.example.com/api/v4",
                        "GITLAB_REPOSITORY": "https://gitlab.example.com/team/web.git", "GITHUB_EVENT_PATH": str(event),
                        "GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": f"url.file://{github}.insteadOf",
                        "GIT_CONFIG_VALUE_0": "https://github.com/alice/web.git",
                        "GIT_CONFIG_KEY_1": f"url.file://{gitlab}.insteadOf",
                        "GIT_CONFIG_VALUE_1": "https://gitlab.example.com/team/web.git"})

            def reconcile(iteration, success=True):
                runner = root / f"runner-{iteration}"
                runner.mkdir()
                result = subprocess.run(["bash", "-c", script], cwd=root, env={**env, "RUNNER_TEMP": str(runner)},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

            reconcile(1)
            self.assertEqual(git("rev-parse", "main", cwd=github), git("rev-parse", "main", cwd=gitlab))
            (source / "github-only").write_text("github\n")
            git("add", ".")
            git("commit", "-m", "github update")
            git("push", str(github), "main")
            git("checkout", "HEAD~1")
            (source / "gitlab-only").write_text("gitlab\n")
            git("add", ".")
            git("commit", "-m", "gitlab update")
            git("tag", "v1")
            git("push", str(gitlab), "HEAD:main", "v1")
            reconcile(2)
            self.assertEqual(git("show-ref", cwd=github), git("show-ref", cwd=gitlab))
            self.assertNotIn("refs/heads/HEAD", git("show-ref", cwd=github))
            git("fetch", str(github), "main")
            git("checkout", "FETCH_HEAD")
            base = git("rev-parse", "HEAD")
            (source / "file").write_text("github conflict\n")
            git("commit", "-am", "github conflict")
            git("push", str(github), "HEAD:main")
            git("checkout", base)
            (source / "file").write_text("gitlab conflict\n")
            git("commit", "-am", "gitlab conflict")
            git("push", str(gitlab), "HEAD:main")
            before = (git("show-ref", cwd=github), git("show-ref", cwd=gitlab))
            reconcile(3, success=False)
            self.assertEqual(before, (git("show-ref", cwd=github), git("show-ref", cwd=gitlab)))


class SyncDispatchTests(unittest.TestCase):
    def test_dispatch_waits_for_new_run_and_propagates_failure(self):
        script = (ROOT / "scripts/configure-repository-sync.sh").read_text()
        initialization = script[script.index('if [[ "$INITIALIZE_REPOSITORY_SYNC" == "true" ]]; then'):]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "github-repository.json").write_text('{"default_branch":"main"}')
            setup = r'''
set -euo pipefail
info() { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
sleep() { :; }
gitlab_api() {
    [[ "$1 $2" == 'PUT projects/7' && "$4" == 'default_branch=main' ]] || fail 'Unexpected GitLab operation'
    touch "$work_dir/default-branch-aligned"
}
github_api() {
    case "$1 $2" in
        'POST '*'/dispatches') touch "$work_dir/dispatched" ;;
        'GET '*'/runs?event='*)
            if [[ -f "$work_dir/dispatched" ]]; then
                printf '{"workflow_runs":[{"id":3,"head_branch":"other"},{"id":2,"head_branch":"main"},{"id":1,"head_branch":"main"}]}'
            else
                printf '{"workflow_runs":[{"id":1,"head_branch":"main"}]}'
            fi
            ;;
        'GET '*'/actions/runs/2')
            if [[ -f "$work_dir/polled" ]]; then
                printf '{"status":"completed","conclusion":"%s"}' "$conclusion"
            else
                touch "$work_dir/polled"
                printf '{"status":"in_progress"}'
            fi
            ;;
        *) fail "Unexpected API operation: $1 $2" ;;
    esac
}
'''
            for conclusion in ("success", "failure"):
                for marker in ("dispatched", "polled", "default-branch-aligned"):
                    (root / marker).unlink(missing_ok=True)
                result = subprocess.run(["bash", "-c", setup + initialization], capture_output=True, text=True,
                                        env={**os.environ, "work_dir": directory, "conclusion": conclusion,
                                             "INITIALIZE_REPOSITORY_SYNC": "true", "GITHUB_OWNER": "alice",
                                             "GITHUB_REPOSITORY": "web", "GITLAB_PROJECT_PATH": "team/web", "project_id": "7"})
                self.assertEqual(result.returncode == 0, conclusion == "success", result.stdout + result.stderr)
                self.assertTrue((root / "polled").exists())
                self.assertEqual((root / "default-branch-aligned").exists(), conclusion == "success")
                self.assertIn("Waiting for GitHub Actions", result.stdout)
                if conclusion == "failure":
                    self.assertIn("/actions/runs/2", result.stderr)

    def test_noninteractive_token_helper_never_prompts_even_with_terminal(self):
        import pty
        master, slave = pty.openpty()
        try:
            script = r'''
set -euo pipefail
source "$1"
kubectl() { return 1; }
info() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
gitlab_prompt_admin_token() { echo PROMPT_CALLED; exit 99; }
gitlab_acquire_admin_token
'''
            result = subprocess.run(["bash", "-c", script, "_", str(ROOT / "scripts/lib/gitlab-admin-token.sh")],
                                    stdin=slave, capture_output=True, text=True,
                                    env={"PATH": os.environ["PATH"], "GITLAB_ADMIN_TOKEN_NONINTERACTIVE": "true"})
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("PROMPT_CALLED", result.stdout)
            self.assertIn("Set GITLAB_ADMIN_TOKEN", result.stderr)
        finally:
            os.close(master)
            os.close(slave)


if __name__ == "__main__":
    unittest.main()
