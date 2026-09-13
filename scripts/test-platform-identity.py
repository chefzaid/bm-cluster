#!/usr/bin/env python3
"""Exercise installation identity through shell rendering and Argo's Helm inputs."""
import ast
import base64
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.request
import urllib.parse
import urllib.error

import yaml

ROOT = Path(__file__).resolve().parent.parent
IDENTITY_KEYS = ("ORGANIZATION_NAME", "ORGANIZATION_SLUG", "GITLAB_GROUP_PATH", "GITLAB_GROUP_NAME",
                 "GITLAB_PROJECT_NAME", "GITLAB_PROJECT_PATH", "KEYCLOAK_REALM", "TLS_SECRET_NAME",
                 "CLOUDFLARE_TLS_SECRET_NAME", "SONAR_ALM_SETTING", "CLOUDFLARE_ACCESS_IDP_NAME")


def clean_env(**values):
    return {**{key: value for key, value in os.environ.items() if key not in IDENTITY_KEYS}, **values}


def resources(text):
    return {f"{item['kind']}/{item['metadata']['name']}": item
            for item in yaml.safe_load_all(text) if item}


class IdentityTest(unittest.TestCase):
    def render(self, directory, enabled, name, slug, domain):
        env = clean_env(SECURITY_IMAGES_ENABLED=str(enabled).lower(), GITLAB_GROUP_NAME=name,
                        SONAR_ALM_SETTING="quality-gitlab", CLOUDFLARE_ACCESS_IDP_NAME="Company SSO")
        result = subprocess.run([
            str(ROOT / "scripts/render-cluster-config.sh"), "--output", directory,
            "--domain", domain, "--internal-domain", "services." + domain,
            "--organization-name", name, "--organization-slug", slug,
            "--gitlab-group", "engineering/team", "--gitlab-project", "infrastructure",
            "--keycloak-realm", "employees", "--tls-secret-name", "shared-wildcard-tls",
            "--gitops-repository", "https://github.com/example/infrastructure.git",
            "--cloudflare-access-team", "example-access",
        ], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return Path(directory)

    def test_bootstrap_and_gitops_preserve_two_organization_identities(self):
        for enabled, name, slug, domain in (
            (False, "Acme & Partners", "acme", "acme.example"),
            (True, "Example's \"Research\", Inc. $(false) `false`", "research", "research.example"),
        ):
            with self.subTest(enabled=enabled), tempfile.TemporaryDirectory() as directory:
                root = self.render(directory, enabled, name, slug, domain)
                application = yaml.safe_load((root / "k8s/addons/bm-cluster-application.yaml").read_text())
                helm = application["spec"]["source"]["helm"]
                values = dict(helm["valuesObject"])
                for parameter in helm["parameters"]:
                    target = values
                    parts = parameter["name"].split(".")
                    for part in parts[:-1]:
                        target = target.setdefault(part, {})
                    value = parameter["value"]
                    if not parameter.get("forceString") and value in ("true", "false"):
                        value = value == "true"
                    target[parts[-1]] = value
                values_path = root / "argo-values.json"
                values_path.write_text(json.dumps(values))
                command = ["helm", "template", "bm-cluster", str(ROOT / "k8s"), "--namespace", "infra"]
                for profile in helm["valueFiles"]:
                    command += ["--values", str(ROOT / "k8s" / profile)]
                rendered = subprocess.check_output(command + ["--values", str(values_path)], text=True)
                self.assertEqual(set(re.findall(r"__[A-Z][A-Z0-9_]+__", rendered)), {"__RUNNER_TOKEN__"})
                runtime = resources(rendered)
                stored = runtime["ConfigMap/bm-cluster-identity"]["data"]
                self.assertEqual(stored["ORGANIZATION_NAME"], name)
                self.assertEqual(stored["ORGANIZATION_SLUG"], slug)
                self.assertEqual(stored["GITLAB_GROUP_PATH"], "engineering/team")
                self.assertEqual(stored["KEYCLOAK_REALM"], "employees")
                self.assertEqual(stored["TLS_SECRET_NAME"], "shared-wildcard-tls")
                homepage = yaml.safe_load(runtime["ConfigMap/homepage-config"]["data"]["settings.yaml"])
                self.assertEqual(homepage["title"], name + " Intranet")
                for item in runtime.values():
                    if item["kind"] == "Ingress":
                        for tls in item["spec"].get("tls", []):
                            self.assertEqual(tls["secretName"], "shared-wildcard-tls")
                script = runtime["ConfigMap/keycloak-sso-reconciler"]["data"]["reconcile.sh"]
                subprocess.run(["sh", "-n"], input=script, text=True, check=True)
                escape = re.search(r"    json_escape\(\) \{.*?\n    \}", script, re.S)
                # YAML strips the block indentation; accept both source and parsed text.
                escape = escape or re.search(r"json_escape\(\) \{.*?\n\}", script, re.S)
                body = re.search(r"realm_body='.*?\n\}'", script, re.S).group(0)
                snippet = escape.group(0) + '\norganization_name_json="$(printf \'%s\' "$ORGANIZATION_NAME" | json_escape)"\n' + body + '\nprintf \'%s\' "$realm_body"\n'
                payload = subprocess.check_output(["sh"], input=snippet, text=True, env=clean_env(ORGANIZATION_NAME=name))
                self.assertEqual(json.loads(payload)["displayName"], name)
                self.assertEqual(json.loads(payload)["realm"], "employees")
                private_prefix = f"registry.{domain}/engineering/team/infrastructure/security/"
                if enabled:
                    self.assertIn(private_prefix + "gitlab:", rendered)
                    self.assertIn(private_prefix + "trivy-operator:", rendered)
                else:
                    self.assertNotIn(private_prefix, rendered)
                    argocd = yaml.safe_load((root / "config/argocd-values.yaml").read_text())
                    self.assertEqual(argocd["redis"]["image"]["repository"], "docker.io/library/redis")
                discovery = runtime["CronJob/sonar-apps-discovery"]["spec"]["jobTemplate"]["spec"]["template"]["spec"]
                settings = {item["name"]: item.get("value") for item in discovery["containers"][0]["env"]}
                self.assertEqual(settings["GITLAB_GROUP_PATH"], "engineering/team")
                self.assertIn("quality-gitlab", runtime["ConfigMap/sonar-apps-discovery"]["data"]["discovery.mjs"])

    def test_defaults_and_invalid_identifiers(self):
        command = ['bash', '-ceu', 'source scripts/lib/platform-identity.sh; platform_identity_defaults; platform_identity_validate; printf "%s|%s|%s" "$GITLAB_PROJECT_PATH" "$KEYCLOAK_REALM" "$TLS_SECRET_NAME"']
        result = subprocess.run(command, cwd=ROOT, env=clean_env(PLATFORM_DOMAIN="example.com"), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "example/bm-cluster|example|example-com-tls")
        for key, value in (("ORGANIZATION_SLUG", "bad/name"), ("KEYCLOAK_REALM", "master"),
                           ("TLS_SECRET_NAME", "Bad Name"), ("ORGANIZATION_NAME", "Bad\nName"),
                           ("GITLAB_PROJECT_PATH", "group//project"),
                           ("GITLAB_PROJECT_NAME", "$(false)")):
            with self.subTest(key=key):
                result = subprocess.run(command, cwd=ROOT, env=clean_env(PLATFORM_DOMAIN="example.com", **{key: value}), capture_output=True)
                self.assertNotEqual(result.returncode, 0)

    def test_installer_collects_organization_and_identity_before_installation(self):
        source = (ROOT / "install-control-plane.sh").read_text()
        definition = "prompt_cluster_identity() {" + source.split("prompt_cluster_identity() {", 1)[1].split("\ngithub_repository_url()", 1)[0]
        setup = '''set -euo pipefail
source scripts/lib/installer-prompts.sh
source scripts/lib/platform-identity.sh
platform_identity_load() { :; }
info() { :; }
error() { printf '%s\\n' "$*" >&2; exit 1; }
'''
        command = setup + definition + '\nprompt_cluster_identity\npython3 scripts/platform-identity.py\n'
        answers = ["Example Company", "example.com", "company", "engineering", "Engineering",
                   "cluster", "employees", "custom-tls", "private.example.com", "server-01"]
        env = clean_env(AUTO_APPROVE="false", PLATFORM_DOMAIN="", INTERNAL_DNS_ZONE="",
                        CONTROL_PLANE_NODE_NAME="", CLOUDFLARE_ZONE="",
                        CLOUDFLARE_NODE_DNS_LABEL="node-01", CLOUDFLARE_ACCESS_TEAM_NAME="",
                        K3S_REGISTRY_HOST="", TAILSCALE_NODE_HOSTNAME="")
        result = subprocess.run(["bash", "-c", command], input="\n".join(answers) + "\n", cwd=ROOT,
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = json.loads(result.stdout)
        self.assertEqual(settings["ORGANIZATION_NAME"], "Example Company")
        self.assertEqual(settings["GITLAB_GROUP_PATH"], "engineering")
        self.assertEqual(settings["GITLAB_PROJECT_NAME"], "cluster")
        self.assertEqual(settings["KEYCLOAK_REALM"], "employees")
        self.assertEqual(settings["TLS_SECRET_NAME"], "custom-tls")
        self.assertEqual(settings["INTERNAL_DNS_ZONE"], "private.example.com")
        missing = subprocess.run(["bash", "-c", command], cwd=ROOT,
                                 env={**env, "AUTO_APPROVE": "true"}, capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("Set ORGANIZATION_NAME", missing.stderr)

    def test_existing_identity_is_reused_and_explicit_values_win(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            kubectl = root / "kubectl"
            data = {"PLATFORM_DOMAIN": "example.com", "ORGANIZATION_NAME": "Existing Company",
                    "ORGANIZATION_SLUG": "existing", "KEYCLOAK_REALM": "existing-users",
                    "TLS_SECRET_NAME": "existing-tls", "GITLAB_GROUP_PATH": "existing-group"}
            kubectl.write_text('#!/usr/bin/env python3\nimport json\nprint(' + repr(json.dumps({"data": data})) + ')\n')
            kubectl.chmod(0o700)
            command = ['bash', '-ceu', 'source scripts/lib/platform-identity.sh; platform_identity_load; platform_identity_defaults; platform_identity_validate; printf "%s|%s|%s" "$ORGANIZATION_NAME" "$KEYCLOAK_REALM" "$GITLAB_GROUP_PATH"']
            env = clean_env(PLATFORM_DOMAIN="example.com", PATH=str(root) + ":" + os.environ["PATH"])
            result = subprocess.check_output(command, cwd=ROOT, env=env, text=True)
            self.assertEqual(result, "Existing Company|existing-users|existing-group")
            result = subprocess.check_output(command, cwd=ROOT, env={**env, "ORGANIZATION_NAME": "New display name"}, text=True)
            self.assertEqual(result, "New display name|existing-users|existing-group")
            kubectl.write_text('#!/bin/sh\necho "API unavailable" >&2\nexit 1\n')
            self.assertNotEqual(subprocess.run(command, cwd=ROOT, env=env, capture_output=True).returncode, 0)

    def test_sonar_integration_uses_the_selected_name_and_private_domain(self):
        source = (ROOT / "scripts/configure-sonar-discovery.sh").read_text().split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        tree = ast.parse(source)
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "configure_sonar")
        namespace = {"os": os, "json": json, "base64": base64, "urllib": __import__("urllib"),
                     "kubectl": lambda *args: b'{"spec":{"clusterIP":"127.0.0.1"}}',
                     "vault": lambda script: "fixture-sonar-admin-token"}
        exec(compile(ast.Module(body=[function], type_ignores=[]), "sonar-configurator", "exec"), namespace)
        for existing in (False, True):
            calls = []
            def response(request, timeout):
                calls.append(request)
                settings = [{"key": "company-gitlab"}] if existing else []
                return io.BytesIO(json.dumps({"gitlab": settings} if request.method == "GET" else {}).encode())
            with patch.dict(os.environ, {"SONAR_ALM_SETTING": "company-gitlab", "INTERNAL_DNS_ZONE": "private.example.com"}), patch.object(urllib.request, "urlopen", response):
                namespace["configure_sonar"]("fixture-gitlab-group-token")
            self.assertEqual(calls[1].full_url.rsplit("/", 1)[1], "update_gitlab" if existing else "create_gitlab")
            form = urllib.parse.parse_qs(calls[1].data.decode())
            self.assertEqual(form["key"], ["company-gitlab"])
            self.assertEqual(form["url"], ["http://gitlab.private.example.com/api/v4"])
            self.assertEqual(form["personalAccessToken"], ["fixture-gitlab-group-token"])
            self.assertEqual(urllib.parse.parse_qs(calls[2].data.decode()), {
                "almSetting": ["company-gitlab"], "pat": ["fixture-gitlab-group-token"]})


if __name__ == "__main__":
    unittest.main()
