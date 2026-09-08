#!/usr/bin/env python3
"""Exercise fresh bootstrap, existing cluster reconciliation, and Helm profiles."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('security_images', ROOT / 'scripts/render-security-images.py')
RENDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RENDER)


def images(documents):
    found = []
    def visit(value):
        if isinstance(value, dict):
            if isinstance(value.get('image'), str):
                found.append(value['image'])
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    for document in documents:
        visit(document)
    return found


class SecurityImagesTest(unittest.TestCase):
    def test_existing_cluster_preserves_profile(self):
        for profile, expected in [(None, True), ('patched', True), ('bootstrap', False)]:
            helm = {'parameters': [{'name': 'publicDomain', 'value': 'example.test'}]}
            if profile:
                helm['valueFiles'] = [f'profiles/security-images-{profile}.values']
            result = subprocess.CompletedProcess([], 0, json.dumps({'spec': {'source': {'helm': helm}}}), '')
            with patch.object(RENDER.subprocess, 'run', return_value=result):
                self.assertEqual(RENDER.select_enabled('auto', 'example.test'), expected)
                self.assertFalse(RENDER.select_enabled('auto', 'fresh.example.test'))

    def test_missing_application_bootstraps(self):
        error = subprocess.CalledProcessError(1, [], stderr='Error from server (NotFound)')
        with patch.object(RENDER.subprocess, 'run', side_effect=error):
            self.assertFalse(RENDER.select_enabled('auto', 'example.test'))

    def test_unavailable_api_does_not_downgrade(self):
        error = subprocess.CalledProcessError(1, [], stderr='TLS handshake timeout')
        with patch.object(RENDER.subprocess, 'run', side_effect=error):
            with self.assertRaises(RuntimeError):
                RENDER.select_enabled('auto', 'example.test')
            self.assertTrue(RENDER.select_enabled('true', 'example.test'))
            self.assertFalse(RENDER.select_enabled('false', 'example.test'))

    def test_installer_profiles(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([
                    str(ROOT / 'scripts/render-cluster-config.sh'), '--output', directory,
                    '--domain', 'example.test', '--internal-domain', 'swirlit.internal',
                    '--gitops-repository', 'http://gitlab.swirlit.internal/swirlit/bm-cluster.git',
                    '--cloudflare-access-team', 'swirlit',
                ], env={**os.environ, 'SECURITY_IMAGES_ENABLED': str(enabled).lower()},
                    capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout.strip(), directory)
                root = Path(directory)
                documents = []
                for path in (root / 'k8s').rglob('*.yaml'):
                    if 'templates' not in path.parts:
                        documents.extend(yaml.safe_load_all(path.read_text()))
                refs = images(documents)
                self.assertTrue(refs)
                private = [ref for ref in refs if 'registry.example.test/' in ref]
                self.assertEqual(bool(private), enabled)
                vault = yaml.safe_load((root / 'config/vault-values.yaml').read_text())
                self.assertEqual(vault['server']['image']['repository'].startswith('registry.'), enabled)
                self.assertEqual(bool(vault['global']['imagePullSecrets']), enabled)
                app = yaml.safe_load((root / 'k8s/addons/bm-cluster-application.yaml').read_text())
                profile = 'patched' if enabled else 'bootstrap'
                self.assertEqual(app['spec']['source']['helm']['valueFiles'], [f'profiles/security-images-{profile}.values'])

    def test_cache_failure_stops_reconciliation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            kubectl = root / 'kubectl'
            kubectl.write_text('#!/bin/sh\nif [ "$1" = "rollout" ]; then exit 42; fi\n')
            kubectl.chmod(0o700)
            result = subprocess.run([str(ROOT / 'scripts/cache-gitlab-image.sh'), directory],
                env={**os.environ, 'PATH': directory + ':' + os.environ['PATH']},
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 42)

    def test_helm_profiles(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                profile = 'patched' if enabled else 'bootstrap'
                registry = 'registry.example.test' if enabled else 'docker.io'
                result = subprocess.run([
                    'helm', 'template', 'bm-cluster', str(ROOT / 'k8s'),
                    '-f', str(ROOT / f'k8s/profiles/security-images-{profile}.values'),
                    '--set', 'publicDomain=example.test,internalDnsZone=swirlit.internal,cloudflareAccessTeamName=swirlit,appsEnabled=true',
                    '--set', 'gitopsRepositoryURL=http://gitlab.swirlit.internal/swirlit/bm-cluster.git',
                    '--set', f'trivy-operator.image.registry={registry},trivy-operator.trivy.image.registry={registry}',
                ], capture_output=True, text=True, check=True)
                self.assertNotIn('__SECURITY_', result.stdout)
                documents = list(yaml.safe_load_all(result.stdout))
                resources = {document.get('kind', '') + '/' + document.get('metadata', {}).get('name', ''): document for document in documents if document}
                cache = resources['DaemonSet/gitlab-image-cache']
                gitlab = resources['Deployment/gitlab']
                self.assertLess(int(cache['metadata']['annotations']['argocd.argoproj.io/sync-wave']), int(gitlab['metadata']['annotations']['argocd.argoproj.io/sync-wave']))
                cache_pod = cache['spec']['template']['spec']
                gitlab_pod = gitlab['spec']['template']['spec']
                self.assertEqual(cache_pod['containers'][0]['image'], gitlab_pod['containers'][0]['image'])
                self.assertEqual(cache_pod['nodeSelector'], gitlab_pod['nodeSelector'])
                self.assertFalse(cache_pod['automountServiceAccountToken'])
                self.assertEqual(cache_pod['containers'][0]['command'], ['/bin/sh', '-ec', 'exec sleep infinity'])
                refs = images(documents)
                self.assertEqual(any('registry.example.test/' in ref for ref in refs), enabled)
                for document in documents:
                    if document and document.get('kind') in ('Deployment', 'StatefulSet') and document['metadata']['name'] in ('trivy-operator', 'trivy-server'):
                        pod = document['spec']['template']['spec']
                        self.assertTrue(pod['containers'][0]['image'].startswith(registry + '/'))
                        self.assertEqual(bool(pod.get('imagePullSecrets')), enabled)


if __name__ == '__main__':
    unittest.main()
