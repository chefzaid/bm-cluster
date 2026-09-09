#!/usr/bin/env python3
"""Offline behavioral checks: no credentials, service APIs, or cluster required."""

import base64
import contextlib
import copy
import importlib.util
import io
import json
import os
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
       "GITLAB_ADMIN_TOKEN": "fixture-gitlab", "GITLAB_PUBLIC_URL": "https://gitlab.example.com"}
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
        self.runner = replication.Replicator("team", ENV["GITLAB_PUBLIC_URL"])
        self.runner.github = Mock()
        self.runner.gitlab = Mock()

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
        self.assertTrue(run.call_args.kwargs["check"])

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

    def test_application_rewrites_only_bootstrap_repository_and_preserves_revision(self):
        documents = self.files()
        original = documents["infra/argocd/application.yaml"]
        _, app = self.runner.application("alice/web", PROJECT)
        self.assertEqual(app["spec"]["source"]["repoURL"], "http://gitlab.internal.example.com/team/web.git")
        self.assertEqual(app["spec"]["source"]["targetRevision"], "main")
        self.assertEqual(documents["infra/argocd/application.yaml"], original)

    def test_missing_ci_and_source_path_are_not_deployable(self):
        self.files(ci=None)
        with self.assertRaisesRegex(replication.ReplicationError, "gitlab-ci"):
            self.runner.application("alice/web", PROJECT)
        self.files(tree=[])
        with self.assertRaisesRegex(replication.ReplicationError, "missing or empty"):
            self.runner.application("alice/web", PROJECT)

    def test_gitlab_reference_tags_are_left_for_server_lint(self):
        ci = "job:\n  script: !reference [.template, script]\n"
        self.files(ci=ci)
        actual_ci, _ = self.runner.application("alice/web", PROJECT)
        self.assertEqual(actual_ci, ci)

    def test_missing_and_ambiguous_argo_bootstrap_are_not_deployable(self):
        documents = self.files()
        del documents["infra/argocd/application.yaml"]
        with self.assertRaisesRegex(replication.ReplicationError, "exactly one"):
            self.runner.application("alice/web", PROJECT)
        documents = self.files()
        documents["argocd/application.yaml"] = documents["infra/argocd/application.yaml"]
        with self.assertRaisesRegex(replication.ReplicationError, "exactly one"):
            self.runner.application("alice/web", PROJECT)

    def test_malformed_and_unrelated_applications_are_rejected(self):
        for field, value in [("source", None), ("source", {"path": "../outside"}),
                             ("destination", {"server": "https://other.cluster", "namespace": "apps"})]:
            app = copy.deepcopy(APP)
            app["spec"][field] = value
            self.files(app=app)
            with self.subTest(field=field), self.assertRaises(replication.ReplicationError):
                self.runner.application("alice/web", PROJECT)
        app = copy.deepcopy(APP)
        app["spec"]["source"]["repoURL"] = "https://github.com/someone/else.git"
        self.files(app=app)
        with self.assertRaisesRegex(replication.ReplicationError, "does not identify"):
            self.runner.application("alice/web", PROJECT)

    def test_ci_lint_failure_restores_disabled_ci_without_applying(self):
        self.files()
        _, app = self.runner.application("alice/web", PROJECT)
        self.runner.application = Mock(return_value=("build: {}", app))
        self.runner.kubectl = Mock(return_value=None)
        self.runner.repository_credentials = Mock()
        self.runner.gitlab.call.side_effect = [None, {"valid": False}, None]
        with self.assertRaisesRegex(replication.ReplicationError, "lint rejected"):
            self.runner.deploy("alice/web", PROJECT)
        self.runner.repository_credentials.assert_not_called()
        self.assertEqual(self.runner.gitlab.call.call_args.args, ("PUT", "projects/7", {"builds_access_level": "disabled"}))
        self.assertFalse(any(call.args == ("apply", "-f", "-") for call in self.runner.kubectl.call_args_list))

    def test_valid_deployment_lints_applies_and_starts_pipeline(self):
        self.files()
        _, app = self.runner.application("alice/web", PROJECT)
        self.runner.application = Mock(return_value=("build: {}", app))
        self.runner.kubectl = Mock(return_value=None)
        self.runner.repository_credentials = Mock()
        self.runner.gitlab.call.side_effect = [None, {"valid": True}, None, {"web_url": "https://gitlab.example.com/pipeline/1"}]
        with contextlib.redirect_stdout(io.StringIO()):
            self.runner.deploy("alice/web", PROJECT)
        self.runner.repository_credentials.assert_called_once()
        self.assertEqual(self.runner.gitlab.call.call_args.args, ("POST", "projects/7/pipeline", {"ref": "main"}))
        self.runner.kubectl.assert_called_with("apply", "-f", "-", resource=app)

    def test_name_collision_does_not_take_over_existing_application(self):
        self.files()
        _, app = self.runner.application("alice/web", PROJECT)
        self.runner.application = Mock(return_value=("build: {}", app))
        self.runner.kubectl = Mock(side_effect=[{}, {}, {"spec": {"source": {"repoURL": "http://gitlab/other/app.git"}}}])
        self.runner.gitlab.reset_mock()
        with self.assertRaisesRegex(replication.ReplicationError, "another repository"):
            self.runner.deploy("alice/web", PROJECT)
        self.runner.gitlab.call.assert_not_called()

    def test_failed_secret_apply_revokes_new_read_only_token(self):
        self.runner.kubectl = Mock(side_effect=[None, replication.ReplicationError("apply failed")])
        self.runner.gitlab.call.return_value = {"id": 20, "username": "reader", "token": "fixture"}
        with self.assertRaises(replication.ReplicationError):
            self.runner.repository_credentials(7, "http://gitlab/team/web.git")
        self.assertEqual(self.runner.gitlab.call.call_args_list[0].args[2]["scopes"], ["read_repository"])
        self.assertEqual(self.runner.gitlab.call.call_args.args, ("DELETE", "projects/7/deploy_tokens/20"))

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
