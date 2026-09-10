#!/usr/bin/env python3
"""Exercise admission against server-side dry runs; never change workloads."""
import copy
import json
from pathlib import Path
import re
import subprocess
import unittest
import yaml


def kubectl(*args, payload=None):
    result = subprocess.run(["kubectl", *args], input=payload, text=True,
                            capture_output=True, check=True)
    return json.loads(result.stdout)


class SystemHardeningTest(unittest.TestCase):
    def preview(self, namespace, name, kind="deployment", spec=None):
        original = kubectl("get", kind, name, "-n", namespace, "-o", "json")
        patch = [{"op": "add", "path": "/metadata/annotations/security-test", "value": "dry-run"}]
        if not original["metadata"].get("annotations"):
            patch = [{"op": "add", "path": "/metadata/annotations", "value": {"security-test": "dry-run"}}]
        if spec is not None:
            patch.append({"op": "replace", "path": "/spec/template/spec", "value": spec})
        actual = kubectl("patch", kind, name, "-n", namespace, "--type=json",
                         "-p", json.dumps(patch), "--dry-run=server", "-o", "json")
        return original["spec"]["template"]["spec"], actual["spec"]["template"]["spec"]

    def test_csi_preserves_socket_access_and_existing_resource_budgets(self):
        source = kubectl("get", "deployment", "csi-attacher", "-n", "longhorn-system", "-o", "json")
        spec = copy.deepcopy(source["spec"]["template"]["spec"])
        spec["securityContext"] = {}
        container = spec["containers"][0]
        container["securityContext"] = {"runAsUser": 0, "runAsGroup": 0}
        container["resources"] = {"requests": {"cpu": "40m"}, "limits": {"memory": "512Mi"}}
        _, actual = self.preview("longhorn-system", "csi-attacher", spec=spec)
        hardened = actual["containers"][0]
        self.assertEqual(hardened["securityContext"]["runAsUser"], 0)
        self.assertTrue(hardened["securityContext"]["readOnlyRootFilesystem"])
        self.assertFalse(hardened["securityContext"]["allowPrivilegeEscalation"])
        self.assertEqual(hardened["securityContext"]["capabilities"], {"drop": ["ALL"]})
        self.assertEqual(hardened["resources"]["limits"]["memory"], "512Mi")
        self.assertEqual(hardened["resources"]["requests"]["cpu"], "40m")
        self.assertEqual(hardened["resources"]["requests"]["memory"], "64Mi")
        for key in ("args", "env", "image", "volumeMounts"):
            self.assertEqual(hardened[key], container[key])
        self.assertEqual(actual["volumes"], spec["volumes"])

    def test_stateless_system_controllers_get_nonroot_and_writable_tmp(self):
        for name in ("coredns", "metrics-server", "local-path-provisioner"):
            with self.subTest(name=name):
                source = kubectl("get", "deployment", name, "-n", "kube-system", "-o", "json")
                spec = copy.deepcopy(source["spec"]["template"]["spec"])
                spec["securityContext"] = {}
                for container in spec["containers"]:
                    container["securityContext"] = {}
                    container["resources"] = {}
                _, actual = self.preview("kube-system", name, spec=spec)
                self.assertEqual(actual["securityContext"]["runAsUser"], 65534)
                self.assertEqual(actual["securityContext"]["seccompProfile"]["type"], "RuntimeDefault")
                self.assertTrue(any(v["name"] == "bm-security-tmp" for v in actual["volumes"]))
                for container in actual["containers"]:
                    context = container["securityContext"]
                    self.assertTrue(context["runAsNonRoot"])
                    self.assertTrue(context["readOnlyRootFilesystem"])
                    self.assertFalse(context["allowPrivilegeEscalation"])
                    self.assertEqual(context["capabilities"]["drop"], ["ALL"])
                    self.assertTrue(container["resources"]["limits"]["cpu"])
                    self.assertTrue(container["resources"]["requests"]["memory"])

    def test_does_not_mutate_storage_engines_or_other_applications(self):
        for namespace, name, kind in (("longhorn-system", "longhorn-manager", "daemonset"),
                                      ("infra", "dbgate", "deployment")):
            with self.subTest(name=name):
                before, after = self.preview(namespace, name, kind)
                self.assertEqual(before, after)

    def test_longhorn_ui_has_no_api_token_and_keeps_bootstrap_write_paths(self):
        before, after = self.preview('longhorn-system', 'longhorn-ui')
        self.assertFalse(after['automountServiceAccountToken'])
        self.assertEqual(after['securityContext']['runAsUser'], 10001)
        container = after['containers'][0]
        self.assertTrue(container['securityContext']['readOnlyRootFilesystem'])
        self.assertEqual(container['securityContext']['capabilities']['drop'], ['ALL'])
        mounts = {m['mountPath'].rstrip('/') for m in container['volumeMounts']}
        self.assertTrue({'/var/lib/nginx', '/var/log/nginx', '/var/config/nginx', '/var/cache/nginx', '/var/run', '/tmp'} <= mounts)
        self.assertEqual(container['env'], before['containers'][0]['env'])
        self.assertEqual(container['ports'], before['containers'][0]['ports'])

    def test_driver_deployer_hardens_init_and_retains_controller_credentials(self):
        before, after = self.preview('longhorn-system', 'longhorn-driver-deployer')
        self.assertTrue(after['automountServiceAccountToken'])
        self.assertEqual(after['serviceAccountName'], before['serviceAccountName'])
        self.assertEqual(after['securityContext']['runAsUser'], 10001)
        for field in ('containers', 'initContainers'):
            for original, actual in zip(before[field], after[field], strict=True):
                self.assertEqual(actual['command'], original['command'])
                self.assertEqual(actual.get('env'), original.get('env'))
                context = actual['securityContext']
                self.assertEqual(context['runAsUser'], 10001)
                self.assertEqual(context['capabilities']['drop'], ['ALL'])
                self.assertTrue(context['readOnlyRootFilesystem'])
                self.assertFalse(context['allowPrivilegeEscalation'])
                self.assertTrue(actual['resources']['limits']['memory'])

    def test_csi_sidecars_keep_sockets_and_do_not_change_privileged_driver(self):
        before, after = self.preview('longhorn-system', 'longhorn-csi-plugin', 'daemonset')
        self.assertEqual(before['securityContext'], after['securityContext'])
        self.assertEqual(before['volumes'], after['volumes'])
        originals = {c['name']: c for c in before['containers']}
        for container in after['containers']:
            original = originals[container['name']]
            if container['name'] == 'longhorn-csi-plugin':
                self.assertEqual(container, original)
                continue
            context = container['securityContext']
            self.assertFalse(context['privileged'])
            self.assertFalse(context['allowPrivilegeEscalation'])
            self.assertTrue(context['readOnlyRootFilesystem'])
            self.assertEqual(context['runAsUser'], 0)
            self.assertEqual(context['capabilities']['drop'], ['ALL'])
            self.assertEqual(context['seccompProfile']['type'], 'RuntimeDefault')
            for field in ('args', 'env', 'volumeMounts'):
                self.assertEqual(container.get(field), original.get(field))

    def test_image_overrides_restore_all_pins_after_controller_recreation(self):
        targets = [('kube-system', name, 'deployment') for name in
                   ('coredns', 'metrics-server', 'local-path-provisioner')]
        targets += [('longhorn-system', name, 'deployment') for name in
                    ('longhorn-ui', 'csi-attacher', 'csi-provisioner', 'csi-resizer', 'csi-snapshotter')]
        targets += [('longhorn-system', 'longhorn-csi-plugin', 'daemonset'),
                    ('infra', 'ingress-nginx-controller', 'deployment'),
                    ('infra', 'ingress-nginx-controller', 'daemonset')]
        for namespace, name, kind in targets:
            with self.subTest(name=name):
                result = subprocess.run(['kubectl', 'get', 'mutatingadmissionpolicy',
                    f'bm-{name}-security-image', '--ignore-not-found', '-o', 'json'],
                    capture_output=True, text=True, check=True)
                if not result.stdout.strip():
                    continue  # Foundation-only installation, before platform policies.
                policy = json.loads(result.stdout)
                expected = dict(re.findall(r"name: '([^']+)',\s*image: '([^']+)'",
                    policy['spec']['mutations'][0]['applyConfiguration']['expression']))
                self.assertTrue(expected)
                source_result = subprocess.run(['kubectl', 'get', kind, name, '-n', namespace,
                    '--ignore-not-found', '-o', 'json'], capture_output=True, text=True, check=True)
                if not source_result.stdout.strip():
                    continue  # Only one ingress workload kind exists in each profile.
                source = json.loads(source_result.stdout)
                spec = copy.deepcopy(source['spec']['template']['spec'])
                spec['imagePullSecrets'] = [{'name': 'unrelated-dry-run-credential'}]
                for container in spec['containers']:
                    if container['name'] in expected:
                        container['image'] = 'docker.io/library/busybox:unpulled-dry-run'
                for container in spec.get('initContainers', []):
                    if name == 'ingress-nginx-controller' and container['name'] == 'prepare-nginx-dirs':
                        container['image'] = 'docker.io/library/busybox:unpulled-dry-run'
                _, actual = self.preview(namespace, name, kind, spec)
                images = {c['name']: c['image'] for c in actual['containers']}
                for container, image in expected.items():
                    self.assertEqual(images[container], image)
                for container in actual.get('initContainers', []):
                    if name == 'ingress-nginx-controller' and container['name'] == 'prepare-nginx-dirs':
                        self.assertEqual(container['image'], expected['controller'])
                self.assertIn({'name': 'unrelated-dry-run-credential'}, actual['imagePullSecrets'])

    def test_reapplying_policies_is_idempotent(self):
        for namespace, name in (("longhorn-system", "csi-attacher"), ("kube-system", "metrics-server")):
            before, after = self.preview(namespace, name)
            self.assertEqual(before, after)

    def test_coredns_override_preserves_other_pull_credentials(self):
        result = subprocess.run([
            'kubectl', 'get', 'mutatingadmissionpolicy', 'bm-coredns-security-image',
            '--ignore-not-found', '-o', 'json',
        ], capture_output=True, text=True, check=True)
        if not result.stdout.strip():
            self.skipTest('Platform image override is not installed during bootstrap')
        policy = json.loads(result.stdout)
        expected = re.search(r"image: '([^']+)'", policy['spec']['mutations'][0]['applyConfiguration']['expression']).group(1)
        source = kubectl('get', 'deployment', 'coredns', '-n', 'kube-system', '-o', 'json')
        spec = copy.deepcopy(source['spec']['template']['spec'])
        spec['imagePullSecrets'] = [{'name': 'unrelated-dry-run-credential'}]
        _, actual = self.preview('kube-system', 'coredns', spec=spec)
        self.assertEqual(actual['containers'][0]['image'], expected)
        self.assertIn({'name': 'unrelated-dry-run-credential'}, actual['imagePullSecrets'])
        self.assertEqual({'name': 'platform-registry-auth'} in actual['imagePullSecrets'], '/security/coredns:' in expected)


class SystemHardeningSourceTest(unittest.TestCase):
    def test_ingress_policy_and_reconciliation_cover_both_workload_kinds(self):
        root = Path(__file__).resolve().parents[1]
        policies = list(yaml.safe_load_all((root/'k8s/platform/system-image-overrides.yaml').read_text()))
        ingress = next(policy for policy in policies if policy['kind'] == 'MutatingAdmissionPolicy' and policy['metadata']['name'] == 'bm-ingress-nginx-controller-security-image')
        self.assertEqual(set(ingress['spec']['matchConstraints']['resourceRules'][0]['resources']), {'deployments', 'daemonsets'})
        reconciler = (root/'scripts/reconcile-system-hardening.sh').read_text()
        for kind in ('deployment', 'daemonset'):
            self.assertIn(kind+'/infra/ingress-nginx-controller', reconciler)
        # Privileged CSI exclusions must not exempt the HA ingress sidecars.
        self.assertIn('$name != "longhorn-csi-plugin"', reconciler)


if __name__ == "__main__":
    unittest.main()
