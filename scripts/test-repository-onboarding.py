#!/usr/bin/env python3
"""Offline onboarding contracts, Git publication, resume and delivery checks."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/lib"))
import repository_onboarding as onboarding

PROJECT = {"id": 12, "path_with_namespace": "team/catalog", "default_branch": "main", "builds_access_level": "enabled"}
CONTRACT = {
    "version": 1, "application": "infra/argocd/application.yaml",
    "inputs": [{"name": "APP_SUBDOMAIN", "label": "Public subdomain", "type": "subdomain", "default": "catalog"},
               {"name": "OPTIONAL_KEY", "secret": True, "required": False, "default": ""}],
    "files": ["infra/k8s/config.yaml", "infra/k8s/ingress.yaml", "infra/argocd/application.yaml"],
    "replacements": [{"from": "catalog.example.com", "to": "{{APP_HOST}}"}],
    "registry": {"path": "apps/catalog/registry"},
    "vault": [{"path": "apps/catalog/runtime", "fields": {"key": {"input": "OPTIONAL_KEY"}}}],
    "dns": {"hosts": ["{{APP_HOST}}"]},
    "pipeline": {"variables": {"APP_ONBOARDING": "true"}, "jobs": ["publish", "deploy"]},
    "readiness": {"deployments": ["catalog"]},
}
APP = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": {"name": "catalog", "namespace": "infra"},
       "spec": {"project": "default", "source": {"repoURL": "https://github.com/alice/catalog.git", "path": "infra/k8s", "targetRevision": "main"},
                "destination": {"server": "https://kubernetes.default.svc", "namespace": "apps"},
                "syncPolicy": {"automated": {"prune": True, "selfHeal": True}}}}


def fixture(root):
    (root / "infra/argocd").mkdir(parents=True)
    (root / "infra/k8s").mkdir()
    (root / onboarding.CONTRACT).write_text(json.dumps(CONTRACT))
    (root / ".gitlab-ci.yml").write_text("publish:\n  script: echo publish\ndeploy:\n  script: echo deploy\n")
    (root / "infra/argocd/application.yaml").write_text(yaml.safe_dump(APP, sort_keys=False))
    (root / "infra/k8s/config.yaml").write_text("publicUrl: https://catalog.example.com\n")
    (root / "infra/k8s/ingress.yaml").write_text(yaml.safe_dump({"apiVersion": "networking.k8s.io/v1", "kind": "Ingress", "metadata": {"name": "catalog"}, "spec": {"rules": [{"host": "catalog.example.com"}]}}))
    (root / "infra/k8s/kustomization.yaml").write_text("resources: [ingress.yaml]\n")


def runner():
    value = Mock()
    value.public_url = "https://gitlab.example.com"
    value.internal_zone = "internal.example.com"
    return value


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="onboarding-contract-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        fixture(self.root)
        self.context = onboarding.public_context(runner(), "alice/catalog", PROJECT)

    def test_public_settings_survive_reruns_and_secrets_never_enter_git(self):
        contract = onboarding.validate_contract(self.root)
        context, secrets = onboarding.collect_inputs(contract, self.context, {}, {"APP_SUBDOMAIN": "@", "OPTIONAL_KEY": "private-fixture"}, False)
        _, settings = onboarding.render(self.root, contract, context, {})
        self.assertEqual(secrets, {"OPTIONAL_KEY": "private-fixture"})
        self.assertNotIn("private-fixture", (self.root / onboarding.SETTINGS).read_text())
        self.assertNotIn("OPTIONAL_KEY", settings["context"])
        before = {str(path): path.read_text() for path in self.root.rglob("*") if path.is_file()}
        context, _ = onboarding.collect_inputs(contract, self.context, settings, {}, False)
        self.assertEqual(context["APP_SUBDOMAIN"], "@")
        _, repeated = onboarding.render(self.root, contract, context, settings)
        self.assertEqual(settings, repeated)
        self.assertEqual(before, {str(path): path.read_text() for path in self.root.rglob("*") if path.is_file()})
        context, _ = onboarding.collect_inputs(contract, self.context, settings, {"APP_SUBDOMAIN": "new"}, False)
        app, _ = onboarding.render(self.root, contract, context, settings)
        self.assertEqual((self.root / "infra/k8s/config.yaml").read_text(), "publicUrl: https://new.example.com\n")
        self.assertEqual(app["spec"]["source"]["repoURL"], "http://gitlab.internal.example.com/team/catalog.git")

    def test_missing_contract_and_escape_paths_are_rejected(self):
        for name in ("../outside", "/tmp/outside", ".git/config"):
            with self.subTest(name=name), self.assertRaises(onboarding.OnboardingError):
                onboarding.local_path(self.root, name)
        secret = self.root / "outside-secret"
        secret.write_text("private")
        (self.root / "linked").symlink_to(secret)
        with self.assertRaisesRegex(onboarding.OnboardingError, "Symlinks"):
            onboarding.local_path(self.root, "linked")
        (self.root / onboarding.CONTRACT).unlink()
        with self.assertRaisesRegex(onboarding.OnboardingError, "missing"):
            onboarding.validate_contract(self.root)

    def test_inputs_are_validated_and_cannot_override_platform_or_expose_secrets(self):
        for supplied in ({"APP_SUBDOMAIN": "bad/path"}, {"UNKNOWN": "x"}, {"APP_SUBDOMAIN": "two.labels"}):
            with self.subTest(supplied=supplied), self.assertRaises(onboarding.OnboardingError):
                onboarding.collect_inputs(CONTRACT, self.context, {}, supplied, False)
        contract = copy.deepcopy(CONTRACT)
        contract["inputs"].append({"name": "PUBLIC_DOMAIN", "default": "other.com"})
        with self.assertRaisesRegex(onboarding.OnboardingError, "override"):
            onboarding.collect_inputs(contract, self.context, {}, {}, False)
        with self.assertRaisesRegex(onboarding.OnboardingError, "Undeclared"):
            onboarding.expand("{{OPTIONAL_KEY}}", self.context)

    def test_wrong_destination_or_missing_default_branch_cannot_render(self):
        context, _ = onboarding.collect_inputs(CONTRACT, self.context, {}, {}, False)
        for update in ({"destination": {"server": "https://remote", "namespace": "apps"}},
                       {"source": {**APP["spec"]["source"], "targetRevision": "release-tag"}}):
            app = copy.deepcopy(APP)
            app["spec"].update(update)
            (self.root / CONTRACT["application"]).write_text(yaml.safe_dump(app))
            with self.assertRaises(onboarding.OnboardingError):
                onboarding.render(self.root, CONTRACT, context, {})

    def test_ambiguous_previous_bindings_stop_instead_of_corrupting_configuration(self):
        contract = copy.deepcopy(CONTRACT)
        contract["replacements"].append({"from": "other.example.com", "to": "{{PUBLIC_DOMAIN}}"})
        context, _ = onboarding.collect_inputs(contract, self.context, {}, {"APP_SUBDOMAIN": "new"}, False)
        previous = {"bindings": {"catalog.example.com": "example.com", "other.example.com": "example.com"}}
        with self.assertRaisesRegex(onboarding.OnboardingError, "ambiguous"):
            onboarding.render(self.root, contract, context, previous)

    def test_all_bootstrap_files_are_validated_before_any_apply(self):
        (self.root / "infra/bootstrap.yaml").write_text("apiVersion: v1\nkind: Namespace\nmetadata: {name: apps}\n---\nkind: ClusterRole\n")
        contract = {**CONTRACT, "bootstrap": ["infra/bootstrap.yaml"]}
        value = runner()
        with self.assertRaisesRegex(onboarding.OnboardingError, "Bootstrap files"):
            onboarding.Onboarding(value).bootstrap(self.root, contract)
        value.kubectl.assert_not_called()


class GitTests(unittest.TestCase):
    def test_publish_only_declared_files_and_reject_concurrent_branch_update(self):
        with tempfile.TemporaryDirectory(prefix="onboarding-git-") as directory:
            root = Path(directory)
            remote, seed = root / "remote.git", root / "seed"
            def git(cwd, *args):
                return subprocess.check_output(["git", *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL).strip()
            git(root, "init", "--bare", str(remote))
            seed.mkdir()
            git(seed, "init", "-b", "main")
            git(seed, "config", "user.name", "fixture")
            git(seed, "config", "user.email", "fixture@example.invalid")
            (seed / "public.txt").write_text("original")
            git(seed, "add", ".")
            git(seed, "commit", "-m", "initial")
            git(seed, "remote", "add", "origin", str(remote))
            git(seed, "push", "origin", "main")
            with onboarding.Checkout(str(remote), "main", "fixture-private") as checkout:
                (checkout.root / "public.txt").write_text("selected settings")
                (checkout.root / "credential.tmp").write_text("fixture-private")
                sha = checkout.publish(["public.txt"])
                self.assertEqual(git(remote, "rev-parse", "main"), sha)
                self.assertEqual(git(remote, "ls-tree", "--name-only", "main"), "public.txt")
                self.assertIn("[skip ci]", git(remote, "log", "main", "-1", "--format=%s"))
                self.assertEqual(checkout.release_head({"id": 91, "sha": sha}), sha)
                git(seed, "pull", "--ff-only", "origin", "main")
                (seed / "public.txt").write_text("concurrent operator change")
                git(seed, "commit", "-am", "advance")
                git(seed, "push", "origin", "main")
                self.assertIsNone(checkout.release_head({"id": 91, "sha": sha}))
                with self.assertRaisesRegex(onboarding.OnboardingError, "changed"):
                    checkout.publish(["public.txt"])
                git(seed, "commit", "--allow-empty", "-m", f"release\n\nOnboarding-Pipeline: 91\nOnboarding-Source: {sha}")
                git(seed, "push", "origin", "main")
                self.assertEqual(checkout.release_head({"id": 91, "sha": sha}), git(seed, "rev-parse", "HEAD"))
                self.assertIsNone(checkout.release_head({"id": 92, "sha": sha}))


class StateAndPipelineTests(unittest.TestCase):
    def test_app_project_rejects_unpermitted_source_and_destination(self):
        project = {"spec": {"sourceRepos": ["*"], "destinations": [{"server": "*", "namespace": "apps"}]}}
        onboarding.project_allows(project, APP)
        for update in ({"sourceRepos": ["https://other.invalid/*"]},
                       {"destinations": [{"server": "*", "namespace": "infra"}]},
                       {"sourceRepos": ["*", "!https://github.com/*"]}):
            with self.subTest(update=update), self.assertRaisesRegex(onboarding.OnboardingError, "does not permit"):
                onboarding.project_allows({"spec": {**project["spec"], **update}}, APP)

    def test_credential_refresh_waits_past_old_ready_condition(self):
        value = runner()
        original = {"spec": {"target": {"name": "catalog-registry"}},
                    "status": {"refreshTime": "old", "conditions": [{"type": "Ready", "status": "True"}]}}
        fresh = copy.deepcopy(original)
        fresh["status"]["refreshTime"] = "new"
        value.kubectl.side_effect = [original, {}, original, fresh, {"data": {"username": "fixture"}}]
        with patch.object(onboarding.time, "sleep") as sleep:
            onboarding.Onboarding(value).refresh_external_secret("catalog-registry", "apps")
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [1.05, 2])

    def test_journal_refuses_other_cluster_and_simultaneous_local_setup(self):
        with tempfile.TemporaryDirectory(prefix="onboarding-state-") as directory, patch.dict(os.environ, {"REPOSITORY_STATE_DIR": directory}):
            with onboarding.journal(PROJECT, "cluster-one") as (state, save):
                state["phase"] = "configured"
                save()
                with self.assertRaisesRegex(onboarding.OnboardingError, "another local"):
                    with onboarding.journal(PROJECT, "cluster-one"):
                        pass
            with self.assertRaisesRegex(onboarding.OnboardingError, "another cluster"):
                with onboarding.journal(PROJECT, "cluster-two"):
                    pass
            with onboarding.journal(PROJECT, "cluster-one") as (state, _save):
                self.assertEqual(state["phase"], "configured")

    def test_green_pipeline_with_missing_manual_or_skipped_release_is_not_success(self):
        for status in ("missing", "manual", "skipped", "failed"):
            with self.subTest(status=status):
                value = runner()
                def api(method, path):
                    if "/jobs?" in path:
                        return [] if status == "missing" else [{"id": 1, "name": "publish", "status": status}]
                    return {"status": "success"}
                value.gitlab.call.side_effect = api
                with self.assertRaisesRegex(onboarding.OnboardingError, "did not all succeed"):
                    onboarding.Onboarding(value).wait_pipeline(12, 9, ["publish"])

    def test_successful_required_jobs_and_latest_retry_are_used(self):
        value = runner()
        jobs = [{"id": 1, "name": "publish", "status": "failed"},
                {"id": 3, "name": "publish", "status": "success"},
                {"id": 2, "name": "deploy", "status": "success"}]
        value.gitlab.call.side_effect = [{"status": "success"}, jobs]
        onboarding.Onboarding(value).wait_pipeline(12, 9, ["publish", "deploy"])

    def test_stale_healthy_application_does_not_pass(self):
        value = runner()
        app = copy.deepcopy(APP)
        app["status"] = {"sync": {"revision": "a" * 40, "status": "Synced"}, "health": {"status": "Healthy"}}
        value.kubectl.return_value = app
        workflow = onboarding.Onboarding(value)
        workflow.timeout = 30
        with patch.object(onboarding.time, "monotonic", side_effect=[0, 1, 31]), patch.object(onboarding.time, "sleep"), \
                self.assertRaisesRegex(onboarding.OnboardingError, "did not become"):
            workflow.wait_application(APP, CONTRACT, "b" * 40)
        self.assertFalse(any(call.args[:2] == ("rollout", "status") for call in value.kubectl.call_args_list))

    def test_unpublished_pause_is_restored_with_resource_version_guard(self):
        value = runner()
        value.kubectl.return_value = {"metadata": {"uid": "app-one", "resourceVersion": "24"}, "spec": {"syncPolicy": {}}}
        checkout = Mock()
        checkout.remote_head.return_value = "a" * 40
        state = {"paused_application": {"name": "catalog", "uid": "app-one", "automated": {"prune": True}, "source_sha": "a" * 40}}
        onboarding.Onboarding(value).restore_unpublished_pause(checkout, state, Mock())
        self.assertNotIn("paused_application", state)
        operation = json.loads(value.kubectl.call_args.args[-1])
        self.assertEqual(operation[0], {"op": "test", "path": "/metadata/resourceVersion", "value": "24"})
        self.assertEqual(operation[1]["value"], {"prune": True})


class FlowTests(unittest.TestCase):
    def test_full_onboarding_then_repeat_reuses_pipeline_and_confirms_readiness(self):
        self.exercise_flow()

    def test_failed_deployment_resumes_after_release_advanced_branch(self):
        self.exercise_flow("failed")

    def test_interruption_after_pipeline_success_resumes_exact_release(self):
        self.exercise_flow("readiness")

    def test_lost_pipeline_creation_response_recovers_existing_pipeline(self):
        self.exercise_flow("lost_response")

    def exercise_flow(self, interruption=None):
        with tempfile.TemporaryDirectory(prefix="onboarding-flow-") as directory:
            root = Path(directory) / "repo"
            root.mkdir()
            fixture(root)
            state_dir = Path(directory) / "state"
            value = runner()
            tip = ["a" * 40]
            calls, pipelines = [], []
            interrupted = []
            app = copy.deepcopy(APP)
            def kubectl(*args, resource=None):
                calls.append((args, resource))
                if args[:3] == ("get", "namespace", "kube-system"):
                    return {"metadata": {"uid": "cluster-one"}}
                if args[:2] == ("get", "application"):
                    if not pipelines:
                        return None
                    if interruption == "readiness" and not interrupted:
                        interrupted.append(True)
                        raise onboarding.OnboardingError("Fixture rollout interruption")
                    deployed = copy.deepcopy(app)
                    deployed["spec"]["source"]["repoURL"] = "http://gitlab.internal.example.com/team/catalog.git"
                    deployed["status"] = {"sync": {"status": "Synced", "revision": tip[0]}, "health": {"status": "Healthy"}}
                    return deployed
                return {}
            value.kubectl = kubectl
            def api(method, path, data=None, **_kwargs):
                if path.endswith("/ci/lint"):
                    return {"valid": True}
                if method == "POST" and path.endswith("/pipeline"):
                    created = {"id": 91, "sha": tip[0], "web_url": "https://gitlab.example.com/pipelines/91", "status": "failed" if interruption == "failed" else "success", "variables": data["variables"]}
                    pipelines.append(created)
                    tip[0] = "c" * 40  # The release publishes its own GitOps commit.
                    if interruption == "lost_response":
                        raise onboarding.OnboardingError("Fixture lost response")
                    return created
                if "/pipelines?" in path:
                    return pipelines
                if path.endswith("/variables"):
                    return pipelines[0]["variables"]
                if path.endswith("/retry"):
                    pipelines[0]["status"] = "success"
                    return pipelines[0]
                if "/jobs?" in path:
                    return [{"id": 1, "name": "publish", "status": "success"}, {"id": 2, "name": "deploy", "status": pipelines[0]["status"]}]
                if "/pipelines/91" in path:
                    return pipelines[0]
                return {}
            value.gitlab.call.side_effect = api
            class Checkout:
                def __init__(self, *_args):
                    self.root, self.sha = root, tip[0]
                def __enter__(self):
                    return self
                def __exit__(self, *_args):
                    pass
                def git(self, *args):
                    return ""  # The publication method simulates the settings commit.
                def publish(self, _paths):
                    if not pipelines:
                        tip[0] = self.sha = "b" * 40
                    return self.sha
                def remote_head(self):
                    return tip[0]
                def release_head(self, _pipeline):
                    return tip[0]
            environment = {"REPOSITORY_STATE_DIR": str(state_dir), "REPOSITORY_NONINTERACTIVE": "true",
                           "CLOUDFLARE_API_TOKEN": "fixture-cloudflare", "GITLAB_ADMIN_TOKEN": "fixture-gitlab"}
            with patch.dict(os.environ, environment), patch.object(onboarding, "Checkout", Checkout), \
                    patch.object(onboarding, "Services") as services, patch.object(onboarding.Onboarding, "validate_local", return_value="publish: {}"):
                if interruption:
                    with self.assertRaises(onboarding.OnboardingError):
                        onboarding.Onboarding(value).run("alice/catalog", PROJECT)
                else:
                    onboarding.Onboarding(value).run("alice/catalog", PROJECT)
                onboarding.Onboarding(value).run("alice/catalog", PROJECT)
            self.assertEqual(len(pipelines), 1)
            self.assertEqual(services.return_value.provision.call_count, 2)
            self.assertTrue(any(args[:3] == ("rollout", "status", "deployment/catalog") for args, _ in calls))
            journal = json.loads(next(state_dir.glob("*.json")).read_text())
            self.assertEqual(journal["phase"], "complete")
            self.assertEqual(journal["head_after_release"], "c" * 40)
            self.assertNotIn("fixture-cloudflare", (root / onboarding.SETTINGS).read_text())


if __name__ == "__main__":
    unittest.main()
