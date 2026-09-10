#!/usr/bin/env python3
"""Render chart contracts for DNS, External Secrets, and Argo CD HA offline."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
PINS = dict(line.split('=',1) for line in (ROOT/'config/platform.env').read_text().splitlines()
            if line.startswith('DEFAULT_') and '=' in line)


def render(name, chart, version, values):
    args=['helm','template',name,chart,'--namespace','infra']
    if version: args += ['--version',version]
    for value in values: args += ['--values',str(ROOT/value)]
    return [doc for doc in yaml.safe_load_all(subprocess.check_output(args,text=True)) if doc]


def index(objects): return {(o['kind'],o['metadata']['name']):o for o in objects}


class PlatformHATests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.argo=index(render('argocd','argo/argo-cd',PINS['DEFAULT_ARGOCD_CHART_VERSION'],
                             ['config/argocd-values.yaml','config/argocd-ha-values.yaml']))
        cls.eso=index(render('external-secrets','external-secrets/external-secrets',PINS['DEFAULT_EXTERNAL_SECRETS_CHART_VERSION'],
                            ['config/external-secrets-values.yaml','config/external-secrets-ha-values.yaml']))

        output=subprocess.check_output(['helm','template','bm-cluster',str(ROOT/'k8s'),'--namespace','infra',
            '--set','publicDomain=example.test','--set','internalDnsZone=internal.example.test',
            '--set','gitopsRepositoryURL=https://example.test/platform.git','--set','cloudflareAccessTeamName=example',
            '--set','highAvailabilityEnabled=true','--set','securityImagesEnabled=false'],text=True)
        cls.platform=index([d for d in yaml.safe_load_all(output) if d])

    def deployment(self,objects,name): return objects['Deployment',name]['spec']

    def test_external_secrets_has_two_hosts_per_component_and_elects_mutating_controllers(self):
        for name in ('external-secrets','external-secrets-webhook','external-secrets-cert-controller'):
            with self.subTest(name=name):
                deployment=self.deployment(self.eso,name)
                self.assertEqual(deployment['replicas'],2)
                spread=deployment['template']['spec']['topologySpreadConstraints'][0]
                self.assertEqual(spread['minDomains'],2)
                self.assertEqual(spread['whenUnsatisfiable'],'DoNotSchedule')
                self.assertEqual(spread['labelSelector'],deployment['selector'])
                args=deployment['template']['spec']['containers'][0]['args']
                self.assertEqual('--enable-leader-election=true' in args,name!='external-secrets-webhook')
                self.assertEqual(self.eso['PodDisruptionBudget',name+'-pdb']['spec']['minAvailable'],1)

    def test_argo_request_paths_have_two_replicas_on_separate_hosts(self):
        for name in ('argocd-server','argocd-repo-server','argocd-applicationset-controller','argocd-redis-ha-haproxy'):
            deployment=self.deployment(self.argo,name)
            self.assertEqual(deployment['replicas'],2)
            anti=deployment['template']['spec']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution']
            self.assertEqual(anti[0]['topologyKey'],'kubernetes.io/hostname')
            pdb=name+'-pdb' if name.endswith('haproxy') else name
            self.assertEqual(self.argo['PodDisruptionBudget',pdb]['spec']['minAvailable'],1)
        params=self.argo['ConfigMap','argocd-cmd-params-cm']['data']
        self.assertEqual(params['applicationsetcontroller.enable.leader.election'],'true')

    def test_controller_is_one_replaceable_deployment_without_static_shards(self):
        self.assertNotIn(('StatefulSet','argocd-application-controller'),self.argo)
        controller=self.deployment(self.argo,'argocd-application-controller')
        self.assertEqual(controller['replicas'],1)
        pod=controller['template']['spec']
        env={e['name']:e.get('value') for e in pod['containers'][0]['env']}
        self.assertEqual(env['ARGOCD_ENABLE_DYNAMIC_CLUSTER_DISTRIBUTION'],'true')
        self.assertNotIn('ARGOCD_CONTROLLER_REPLICAS',env)
        for condition in ('not-ready','unreachable'):
            taint=next(t for t in pod['tolerations'] if t['key']=='node.kubernetes.io/'+condition)
            self.assertEqual(taint['tolerationSeconds'],30)

    def test_redis_and_sentinel_auth_use_existing_secret_and_all_containers_have_budgets(self):
        self.assertNotIn(('Deployment','argocd-redis'),self.argo)
        state=self.argo['StatefulSet','argocd-redis-ha-server']['spec']
        self.assertEqual(state['replicas'],3)
        self.assertFalse(state.get('volumeClaimTemplates'))  # Disposable Argo cache.
        self.assertEqual(self.argo['PodDisruptionBudget','argocd-redis-ha-pdb']['spec']['maxUnavailable'],1)
        for name in ('argocd-redis-ha-server','argocd-redis-ha-haproxy'):
            kind='StatefulSet' if name.endswith('server') else 'Deployment'
            pod=self.argo[kind,name]['spec']['template']['spec']
            for container in pod['containers']+pod.get('initContainers',[]):
                for field in ('requests','limits'):
                    self.assertTrue({'cpu','memory'} <= set(container['resources'][field]),container['name'])
                env={e['name']:e.get('valueFrom') for e in container.get('env',[])}
                if container['name'] in ('redis','sentinel','haproxy','split-brain-fix'):
                    self.assertEqual(env['AUTH']['secretKeyRef'],{'name':'argocd-redis','key':'auth'})
                if container['name'] in ('sentinel','haproxy','split-brain-fix'):
                    self.assertEqual(env['SENTINELAUTH']['secretKeyRef'],{'name':'argocd-redis','key':'auth'})
        self.assertNotIn(('Secret','argocd-redis'),self.argo)  # Existing hook owns creation.

    def test_shared_cache_policy_selectors_match_real_pods_and_isolate_sentinel(self):
        server=self.platform['StatefulSet','shared-redis-ha-server']['spec']['template']
        proxy=self.platform['Deployment','shared-redis-ha-haproxy']['spec']['template']
        for name,pod in [('shared-redis-ha-servers',server),('shared-redis-ha-clients',proxy)]:
            policy=self.platform['NetworkPolicy',name]['spec']
            labels=pod['metadata']['labels']
            self.assertTrue(all(labels.get(k)==v for k,v in policy['podSelector']['matchLabels'].items()))
            anti=pod['spec']['affinity']['podAntiAffinity']['requiredDuringSchedulingIgnoredDuringExecution'][0]
            self.assertTrue(all(labels.get(k)==v for k,v in anti['labelSelector']['matchLabels'].items()))
            self.assertEqual(anti['topologyKey'],'kubernetes.io/hostname')
        management=self.platform['NetworkPolicy','shared-redis-ha-servers']['spec']['ingress']
        self.assertEqual({p['port'] for p in management[0]['ports']},{6379,26379})
        source=management[0]['from'][0]
        self.assertEqual(set(source),{'podSelector'})  # Namespace remains infra.
        self.assertEqual(source['podSelector']['matchLabels'],{'release':'bm-cluster'})
        self.assertEqual(set(source['podSelector']['matchExpressions'][0]['values']),{'redis-ha','redis-ha-haproxy'})
        clients=self.platform['NetworkPolicy','shared-redis-ha-clients']['spec']['ingress']
        self.assertEqual([p['port'] for p in clients[0]['ports']],[6379])
        self.assertEqual(set(clients[0]['from'][0]['namespaceSelector']['matchExpressions'][0]['values']),{'infra','apps','corp'})

    def test_coredns_policy_is_opt_in_and_covers_packaged_updates_and_scale(self):
        # Render this template alone to avoid unrelated workload/image profiles.
        source=(ROOT/'k8s/templates/high-availability.yaml').read_text()
        with tempfile.TemporaryDirectory(prefix='dns-ha-chart-') as directory:
            directory=Path(directory); (directory/'templates').mkdir()
            (directory/'Chart.yaml').write_text('apiVersion: v2\nname: fixture\nversion: 1.0.0\n')
            (directory/'templates/ha.yaml').write_text(source)
            def profile(enabled):
                output=subprocess.check_output(['helm','template','fixture',str(directory),
                    '--set','highAvailabilityEnabled='+str(enabled).lower()],text=True)
                return index([d for d in yaml.safe_load_all(output) if d])
            self.assertEqual(profile(False),{})
            objects=profile(True)
        policy=objects['MutatingAdmissionPolicy','bm-coredns-availability']['spec']
        self.assertEqual(policy['failurePolicy'],'Fail')
        self.assertEqual(policy['matchConstraints']['resourceRules'][0]['resources'],['deployments','deployments/scale'])
        self.assertIn("object.metadata.namespace == 'kube-system'",policy['matchConditions'][0]['expression'])
        self.assertIn("object.metadata.name == 'coredns'",policy['matchConditions'][0]['expression'])
        expression=policy['mutations'][0]['jsonPatch']['expression']
        self.assertIn("path: '/spec/replicas', value: 3",expression)
        self.assertIn("'minDomains': dyn(3)",expression)
        self.assertIn("request.subResource == 'scale' ? []",expression)
        self.assertEqual(objects['PodDisruptionBudget','coredns']['spec']['minAvailable'],2)
        self.assertFalse(any(kind=='Deployment' for kind,_ in objects))


if __name__=='__main__': unittest.main()
