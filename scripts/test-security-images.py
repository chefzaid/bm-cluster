#!/usr/bin/env python3
"""Exercise fresh bootstrap, existing cluster reconciliation, and Helm profiles."""
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest
import tomllib
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
            if isinstance(value.get('expression'), str):
                found.extend(re.findall(r'''\bimage:\s*['"]([^'"]+)['"]''', value['expression']))
        elif isinstance(value, list):
            for child in value:
                visit(child)
    for document in documents:
        visit(document)
    return found


class SecurityImagesTest(unittest.TestCase):
    def assert_public_longhorn_sidecars(self, documents):
        policies = [d for d in documents if d and d.get('kind') == 'MutatingAdmissionPolicy'
                    and d['metadata']['name'] == 'bm-longhorn-csi-plugin-security-image']
        self.assertEqual(len(policies), 1)
        mutations = policies[0]['spec']['mutations']
        self.assertNotIn('imagePullSecrets', json.dumps(mutations))
        selected = dict(re.findall(r"name: '([^']+)',\s*image: '([^']+)'",
                                   mutations[0]['applyConfiguration']['expression']))
        self.assertEqual(set(selected), {'node-driver-registrar', 'longhorn-liveness-probe'})
        for image in selected.values():
            self.assertRegex(image, r'^registry\.k8s\.io/sig-storage/[^:]+:v[^@]+@sha256:[a-f0-9]{64}$')

    def assert_private_image_credentials(self, documents):
        def visit(value):
            if isinstance(value, dict):
                containers = value.get('containers', []) + value.get('initContainers', [])
                private = [c['image'] for c in containers if isinstance(c, dict)
                           and c.get('image', '').startswith('registry.example.test/')]
                if private:
                    secrets = {s['name'] for s in value.get('imagePullSecrets', [])}
                    self.assertIn('platform-registry-auth', secrets,
                                  f'Private images lack registry credentials: {private}')
                for child in value.values():
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)
        visit(documents)

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
                self.assert_public_longhorn_sidecars(list(yaml.safe_load_all(
                    (root / 'k8s/base/system-workload-hardening.yaml').read_text())))
                sonar_docs = list(yaml.safe_load_all((root / 'k8s/platform/sonarqube.yaml').read_text()))
                self.assert_sonar_permissions(next(d for d in sonar_docs if d and d['kind'] == 'Deployment'), enabled)
                keycloak_docs = list(yaml.safe_load_all((root / 'k8s/platform/keycloak.yaml').read_text()))
                self.assert_keycloak_permissions(next(d for d in keycloak_docs if d and d['kind'] == 'Deployment'), enabled)
                documents = []
                for path in (root / 'k8s').rglob('*.yaml'):
                    if 'templates' not in path.parts:
                        documents.extend(yaml.safe_load_all(path.read_text()))
                refs = images(documents)
                self.assert_private_image_credentials(documents)
                self.assertTrue(refs)
                private = [ref for ref in refs if 'registry.example.test/' in ref]
                self.assertEqual(bool(private), enabled)
                vault = yaml.safe_load((root / 'config/vault-values.yaml').read_text())
                self.assertEqual(vault['server']['image']['repository'].startswith('registry.'), enabled)
                self.assertEqual(bool(vault['global']['imagePullSecrets']), enabled)
                ingress = yaml.safe_load((root / 'config/ingress-nginx-values.yaml').read_text())
                controller = ingress['controller']
                selected = controller['image']
                image = selected['repository'] + ':' + selected['tag'] + '@' + selected['digest']
                initializer = next(c for c in controller['extraInitContainers'] if c['name'] == 'prepare-nginx-dirs')
                self.assertEqual(initializer['image'], image)
                self.assertEqual(image.startswith('registry.example.test/'), enabled)
                self.assertEqual(bool(ingress['imagePullSecrets']), enabled)
                runner_docs = list(yaml.safe_load_all((root / 'k8s/platform/gitlab-runner.yaml').read_text()))
                runner_config = next(d for d in runner_docs if d and d['kind'] == 'ConfigMap' and d['metadata']['name'] == 'gitlab-runner-config')
                executor = tomllib.loads(runner_config['data']['config.template.toml'])['runners'][0]['kubernetes']
                self.assertEqual(executor['helper_image'].startswith('registry.example.test/'), enabled)
                self.assertIn('@sha256:', executor['helper_image'])
                self.assertEqual(executor['image_pull_secrets'], ['platform-registry-auth'] if enabled else [])
                self.assertTrue(controller['containerSecurityContext']['readOnlyRootFilesystem'])
                self.assertEqual(controller['containerPort'], {'http': 8080, 'https': 8444})
                self.assertEqual(controller['containerSecurityContext']['capabilities']['add'],
                                 [] if enabled else ['NET_BIND_SERVICE'])
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
                self.assert_public_longhorn_sidecars(documents)
                self.assert_private_image_credentials(documents)
                resources = {document.get('kind', '') + '/' + document.get('metadata', {}).get('name', ''): document for document in documents if document}
                self.assert_sonar_permissions(resources['Deployment/sonarqube'], enabled)
                self.assert_keycloak_permissions(resources['Deployment/keycloak'], enabled)
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
                runner_config = resources['ConfigMap/gitlab-runner-config']
                executor = tomllib.loads(runner_config['data']['config.template.toml'])['runners'][0]['kubernetes']
                self.assertEqual(executor['helper_image'].startswith('registry.example.test/'), enabled)
                self.assertEqual(executor['image_pull_secrets'], ['platform-registry-auth'] if enabled else [])
                for document in documents:
                    if document and document.get('kind') in ('Deployment', 'StatefulSet') and document['metadata']['name'] in ('trivy-operator', 'trivy-server'):
                        pod = document['spec']['template']['spec']
                        self.assertTrue(pod['containers'][0]['image'].startswith(registry + '/'))
                        self.assertEqual(bool(pod.get('imagePullSecrets')), enabled)

    def assert_keycloak_permissions(self, deployment, enabled):
        pod = deployment['spec']['template']['spec']
        self.assertEqual(bool(pod['imagePullSecrets']), enabled)
        self.assertEqual(pod['securityContext']['runAsUser'], 10001 if enabled else 1000)
        self.assertEqual(pod['securityContext']['runAsGroup'], 10001 if enabled else 0)
        self.assertEqual(pod['securityContext']['fsGroup'], 10001 if enabled else 0)
        main = next(c for c in pod['containers'] if c['name'] == 'keycloak')
        self.assertEqual(main['image'].startswith('registry.example.test/'), enabled)
        self.assertEqual(main['securityContext']['readOnlyRootFilesystem'], enabled)
        self.assertEqual('--optimized' in main['args'], enabled)
        mounts = {m['mountPath']: m for m in main['volumeMounts']}
        self.assertTrue(mounts['/opt/keycloak/data/import']['readOnly'])
        volumes = {v['name']: v for v in pod['volumes']}
        for path in ('/tmp', '/opt/keycloak/data'):
            self.assertIn('emptyDir', volumes[mounts[path]['name']])

    def assert_sonar_permissions(self, deployment, enabled):
        pod = deployment['spec']['template']['spec']
        uid = 10001 if enabled else 1000
        self.assertEqual(pod['securityContext']['fsGroup'], uid)
        self.assertEqual(pod['securityContext']['runAsUser'], uid)
        self.assertEqual(pod['securityContext']['runAsGroup'], uid)
        main = next(c for c in pod['containers'] if c['name'] == 'sonarqube')
        theme = next(c for c in pod['initContainers'] if c['name'] == 'prepare-theme')
        self.assertEqual(main['image'], theme['image'])
        self.assertEqual(main['image'].startswith('registry.example.test/'), enabled)
        for container in (main, theme):
            self.assertEqual(container['securityContext']['runAsUser'], uid)
            self.assertEqual(container['securityContext']['runAsGroup'], uid)
            self.assertTrue(container['securityContext']['readOnlyRootFilesystem'])


if __name__ == '__main__':
    unittest.main()
