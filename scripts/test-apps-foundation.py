#!/usr/bin/env python3
"""Ensure infrastructure-only chart reconciliation retains application foundations."""

from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def chart(corporate):
    rendered = subprocess.check_output([
        "helm", "template", "bm-cluster", str(ROOT / "k8s"), "--namespace", "infra",
        "--set", "publicDomain=example.test,internalDnsZone=internal.example.test",
        "--set", "gitopsRepositoryURL=https://gitlab.example.test/team/platform.git",
        "--set", "cloudflareAccessTeamName=example,securityImagesEnabled=false",
        "--set", f"appsEnabled={str(corporate).lower()}",
    ], text=True)
    return {(item["kind"], item["metadata"].get("namespace", ""), item["metadata"]["name"]): item
            for item in yaml.safe_load_all(rendered) if item}


class ApplicationFoundationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.infrastructure, cls.corporate = chart(False), chart(True)

    def test_shared_application_resources_survive_scope_change(self):
        for key in [
            ("Namespace", "", "apps"), ("NetworkPolicy", "apps", "default-deny-ingress"),
            ("ExternalSecret", "apps", "platform-registry-auth"),
            ("CronJob", "infra", "sonar-apps-discovery"),
            ("ClusterSecretStore", "", "vault-backend"),
        ]:
            with self.subTest(resource=key):
                self.assertIn(key, self.infrastructure)
                self.assertEqual(self.infrastructure[key], self.corporate[key])
        namespace = self.infrastructure["Namespace", "", "apps"]
        self.assertEqual(namespace["metadata"]["labels"]["pod-security.kubernetes.io/enforce"], "baseline")
        self.assertEqual(namespace["metadata"]["labels"]["security.example.test/deny-hostpath"], "true")
        policy = self.infrastructure["NetworkPolicy", "apps", "default-deny-ingress"]["spec"]
        self.assertEqual(policy["podSelector"], {})
        self.assertEqual(policy["policyTypes"], ["Ingress"])
        self.assertIn(("ValidatingAdmissionPolicyBinding", "", "deny-hostpath-on-isolated-namespaces"), self.infrastructure)

    def test_infrastructure_only_does_not_enable_corporate_workloads(self):
        self.assertFalse(any(namespace == "corp" or (kind == "Namespace" and name == "corp")
                             for kind, namespace, name in self.infrastructure))
        self.assertIn(("Namespace", "", "corp"), self.corporate)
        self.assertIn(("Deployment", "corp", "odoo"), self.corporate)


if __name__ == "__main__":
    unittest.main()
