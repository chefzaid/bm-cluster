#!/usr/bin/env python3
"""Fencing safety and least-privilege chart tests; all providers are simulated."""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import ssl
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('fencing', ROOT/'k8s/scripts/fence-unresponsive-nodes.py')
F = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(F)
NOW = datetime(2026, 1, 1, tzinfo=timezone.utc)
UIDS = [f'00000000-0000-0000-0000-00000000000{i}' for i in range(1,5)]
SYSTEMS = [f'10000000-0000-0000-0000-00000000000{i}' for i in range(1,5)]


def node(i, ready=True):
    return {'metadata':{'name':f'cp{i}','uid':UIDS[i-1],'resourceVersion':'123',
                        'labels':{'node-role.kubernetes.io/control-plane':'true'},
                        'annotations':{F.POLICY:'verified'}},
            'spec':{'taints':[{'key':'keep-existing','effect':'NoSchedule'}]},
            'status':{'nodeInfo':{'systemUUID':SYSTEMS[i-1]},
                      'conditions':[{'type':'Ready','status':'True' if ready else 'Unknown',
                                     'lastTransitionTime':(NOW-timedelta(seconds=400)).isoformat()}]}}


def lease(i, age):
    return {'metadata':{'name':f'cp{i}','ownerReferences':[{'kind':'Node','uid':UIDS[i-1]}]},
            'spec':{'holderIdentity':f'cp{i}','renewTime':(NOW-timedelta(seconds=age)).isoformat()}}


class FakeKubernetes:
    def __init__(self):
        self.nodes = [node(1,False),node(2),node(3)]
        self.leases = [lease(1,400),lease(2,5),lease(3,5)]
        self.actions = []
        self.snapshots = 0
        self.on_snapshot = lambda _: None

    def snapshot(self):
        self.snapshots += 1
        self.on_snapshot(self.snapshots)
        return copy.deepcopy(self.nodes), copy.deepcopy(self.leases)

    def taint(self, target):
        self.actions.append(copy.deepcopy(target))


class FakeRedfish(F.Redfish):
    def __init__(self, entry, secret_dir):
        self.entry = entry
        self.url = entry['computerSystemURL']
        self.parsed,self.origin = F.https_url(self.url)
        self.system_uuid = entry['systemUUID']
        self.power = 'On'
        self.never_off = False
        self.requests = []
        self.action = self.url + '/Actions/ComputerSystem.Reset'
        self.allowed = ['On','ForceOff']
        self.fail = False
        self.http = self

    def request(self, method, url, body=None):
        self.requests.append((method,url,body))
        if self.fail:
            raise F.Refusal('BMC request unavailable')
        if method == 'POST':
            assert body == {'ResetType':'ForceOff'}
            if not self.never_off: self.power='Off'
            return {}
        return {'UUID':self.system_uuid,'@odata.id':self.parsed.path,'PowerState':self.power,
                'Actions':{'#ComputerSystem.Reset':{'target':self.action,'ResetType@Redfish.AllowableValues':self.allowed}}}


class FencingFixture(unittest.TestCase):
    def setUp(self):
        self.entry={'name':'cp1','nodeUID':UIDS[0],'systemUUID':SYSTEMS[0],
                    'computerSystemURL':'https://bmc.example.test/redfish/v1/Systems/1',
                    'username':'fixture-admin','password':'fixture-secret-password','caFile':'ca.pem'}
        self.inventory={'version':1,'controlPlanes':{f'cp{i}':UIDS[i-1] for i in range(1,4)},'nodes':[self.entry]}
        self.kube=FakeKubernetes()
        self.bmc=FakeRedfish(self.entry,Path('.'))

    def run_fence(self, apply=True):
        with patch.object(F.time,'sleep',lambda _: None):
            return F.run(self.inventory,Path('.'),self.kube,lambda *_: self.bmc,apply=apply,now=lambda:NOW)

    def posts(self): return [r for r in self.bmc.requests if r[0]=='POST']


class SafetyTests(FencingFixture):
    def test_unverified_controller_storage_policy_never_contacts_bmc(self):
        self.kube.nodes[1]['metadata']['annotations'].clear()
        with self.assertRaisesRegex(F.Refusal, 'storage detach policy'): self.run_fence()
        self.assertEqual(self.bmc.requests, [])

    def test_recent_not_ready_transition_does_not_authorize_fencing(self):
        self.kube.nodes[0]['status']['conditions'][0]['lastTransitionTime'] = (NOW-timedelta(seconds=20)).isoformat()
        self.assertEqual(self.run_fence(), 0)
        self.assertEqual(self.bmc.requests, [])

    def test_membership_replacement_is_rejected_even_with_a_ready_majority(self):
        self.kube.nodes[2]['metadata']['uid'] = UIDS[3]
        with self.assertRaisesRegex(F.Refusal, 'membership'): self.run_fence()
        self.assertEqual(self.bmc.requests, [])

    def test_replayed_success_never_repeats_power_action_or_taint(self):
        self.assertEqual(self.run_fence(), 1)
        self.kube.nodes[0]['spec']['taints'].append({'key': F.TAINT, 'effect': 'NoExecute'})
        self.assertEqual(self.run_fence(), 0)
        self.assertEqual(len(self.posts()), 1)
        self.assertEqual(len(self.kube.actions), 1)

    def test_inventory_check_does_not_require_failed_hosts_or_bmc_access(self):
        self.kube.nodes[0] = node(1)
        for target in self.kube.nodes: target['metadata']['annotations'].clear()
        with patch.object(F, 'Redfish', side_effect=AssertionError('Unexpected BMC access')):
            F.validate_current_inventory(self.inventory, self.kube.nodes)

    def test_network_partition_is_fenced_before_storage_recovery(self):
        self.assertEqual(self.run_fence(),1)
        self.assertEqual(len(self.posts()),1)
        self.assertEqual(self.posts()[0][2],{'ResetType':'ForceOff'})
        self.assertEqual(self.bmc.power,'Off')
        self.assertEqual(len(self.kube.actions),1)
        self.assertGreaterEqual(self.kube.snapshots,4)

    def test_fresh_lease_despite_not_ready_never_powers_off(self):
        self.kube.leases[0]=lease(1,20)
        self.assertEqual(self.run_fence(),0)
        self.assertEqual(self.bmc.requests,[])
        self.assertEqual(self.kube.actions,[])

    def test_ready_node_with_stale_lease_is_not_a_fencing_signal(self):
        self.kube.nodes[0]=node(1)
        self.assertEqual(self.run_fence(),0)
        self.assertEqual(self.bmc.requests,[])

    def test_no_control_plane_majority_never_contacts_bmc(self):
        self.kube.nodes[1]=node(2,False)
        with self.assertRaisesRegex(F.Refusal,'majority'): self.run_fence()
        self.assertEqual(self.bmc.requests,[])

    def test_two_total_control_planes_are_rejected(self):
        self.kube.nodes.pop(); self.kube.leases.pop()
        with self.assertRaisesRegex(F.Refusal,'membership'): self.run_fence()
        self.assertEqual(self.bmc.requests,[])

    def test_ready_survivors_with_stale_leases_do_not_count(self):
        self.kube.leases[1]=lease(2,100)
        with self.assertRaisesRegex(F.Refusal,'majority'): self.run_fence()
        self.assertEqual(self.bmc.requests,[])

    def test_missing_wrong_uid_or_future_lease_never_authorizes_fencing(self):
        for kind in ('missing','wrong_uid','future'):
            with self.subTest(kind=kind):
                self.kube=FakeKubernetes()
                if kind=='missing': self.kube.leases.pop(0)
                elif kind=='wrong_uid': self.kube.leases[0]['metadata']['ownerReferences'][0]['uid']=UIDS[3]
                else: self.kube.leases[0]=lease(1,-1)
                with self.assertRaises(F.Refusal): self.run_fence()
                self.assertEqual(self.posts(),[])

    def test_wrong_bmc_uuid_is_rejected_before_power_request(self):
        self.bmc.system_uuid=SYSTEMS[3]
        with self.assertRaisesRegex(F.Refusal,'ComputerSystem UUID'): self.run_fence()
        self.assertEqual(self.posts(),[])
        self.assertEqual(self.kube.actions,[])

    def test_uid_replacement_before_power_is_rejected(self):
        self.kube.on_snapshot=lambda count: self.kube.nodes[0]['metadata'].update(uid=UIDS[3]) if count==2 else None
        with self.assertRaises(F.Refusal): self.run_fence()
        self.assertEqual(self.posts(),[])
        self.assertEqual(self.kube.actions,[])

    def test_uid_replacement_after_power_is_never_tainted(self):
        self.kube.on_snapshot=lambda count: self.kube.nodes[0]['metadata'].update(uid=UIDS[3]) if count==4 else None
        with self.assertRaises(F.Refusal): self.run_fence()
        self.assertEqual(len(self.posts()),1)
        self.assertEqual(self.kube.actions,[])

    def test_lost_quorum_before_or_after_power_is_rejected(self):
        for changed_at in (3,4):
            with self.subTest(changed_at=changed_at):
                self.kube=FakeKubernetes(); self.bmc=FakeRedfish(self.entry,Path('.'))
                self.kube.on_snapshot=lambda count: self.kube.nodes[1].update(status=node(2,False)['status']) if count==changed_at else None
                with self.assertRaisesRegex(F.Refusal,'majority'): self.run_fence()
                self.assertEqual(len(self.posts()),int(changed_at==4))
                self.assertEqual(self.kube.actions,[])

    def test_target_recovery_during_preflight_prevents_forceoff(self):
        self.kube.on_snapshot=lambda count: self.kube.nodes[0].update(status=node(1)['status']) if count==3 else None
        with self.assertRaisesRegex(F.Refusal,'recovered'): self.run_fence()
        self.assertEqual(self.posts(),[])

    def test_off_verification_failure_never_taints(self):
        self.bmc.never_off=True
        with self.assertRaisesRegex(F.Refusal,'PowerState Off'): self.run_fence()
        self.assertEqual(len(self.posts()),1)
        self.assertEqual(self.kube.actions,[])

    def test_unreachable_bmc_fails_closed(self):
        self.bmc.fail=True
        with self.assertRaises(F.Refusal): self.run_fence()
        self.assertEqual(self.posts(),[])
        self.assertEqual(self.kube.actions,[])

    def test_kubernetes_api_failure_never_contacts_bmc(self):
        self.kube.snapshot=lambda: (_ for _ in ()).throw(F.Refusal('API unavailable'))
        with self.assertRaises(F.Refusal): self.run_fence()
        self.assertEqual(self.bmc.requests,[])

    def test_check_only_verifies_without_power_or_kubernetes_writes(self):
        self.assertEqual(self.run_fence(False),0)
        self.assertEqual(self.posts(),[])
        self.assertEqual(self.kube.actions,[])

    def test_already_off_host_needs_no_extra_power_request(self):
        self.bmc.power='Off'
        self.assertEqual(self.run_fence(),1)
        self.assertEqual(self.posts(),[])
        self.assertEqual(len(self.kube.actions),1)

    def test_cross_origin_or_different_system_reset_is_rejected(self):
        for target in ('https://evil.test/redfish/v1/Systems/1/Actions/ComputerSystem.Reset',
                       'https://bmc.example.test/redfish/v1/Systems/2/Actions/ComputerSystem.Reset'):
            self.bmc.action=target
            with self.assertRaisesRegex(F.Refusal,'same HTTPS ComputerSystem'): self.run_fence()
            self.assertEqual(self.posts(),[])

    def test_missing_forceoff_support_is_rejected(self):
        self.bmc.allowed=['GracefulShutdown']
        with self.assertRaisesRegex(F.Refusal,'ForceOff support'): self.run_fence()
        self.assertEqual(self.posts(),[])

    def test_guarded_taint_patch_preserves_unrelated_taints_and_checks_uid_version(self):
        requests=[]
        client=object.__new__(F.Kubernetes); client.base='https://kubernetes.default.svc'
        client.http=type('HTTP',(),{'request':lambda _,*args: requests.append(args)})()
        client.taint(self.kube.nodes[0])
        method,url,body,ctype=requests[0]
        self.assertEqual((method,ctype),('PATCH','application/json-patch+json'))
        self.assertEqual([p['path'] for p in body[:3]],['/metadata/uid','/metadata/resourceVersion','/status/nodeInfo/systemUUID'])
        self.assertEqual(body[-1]['value'][0],{'key':'keep-existing','effect':'NoSchedule'})
        self.assertEqual(body[-1]['value'][-1],{'key':F.TAINT,'value':'redfish-fenced','effect':'NoExecute'})


class InputTests(FencingFixture):
    def test_inventory_missing_empty_or_mismatched_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'inventory.json'
            with self.assertRaises(F.Refusal): F.load_inventory(path,['cp1'])
            (path.parent/'ca.pem').write_text('fixture CA')
            path.write_text(json.dumps(dict(self.inventory,nodes=[])))
            with self.assertRaises(F.Refusal): F.load_inventory(path,['cp1'])
            path.write_text(json.dumps(self.inventory))
            with self.assertRaises(F.Refusal): F.load_inventory(path,['cp2'])
            self.assertEqual(F.load_inventory(path,['cp1'])['nodes'][0]['name'],'cp1')

    def test_https_rejects_userinfo_http_queries_and_encoded_paths(self):
        for url in ('http://bmc.test/redfish/v1/Systems/1','https://user:pw@bmc.test/x',
                    'https://@bmc.test/x','https://bmc.test/x?token=secret',
                    'https://bmc.test/%2e%2e/x','https://bmc.test/../x'):
            with self.subTest(url=url),self.assertRaises(F.Refusal): F.https_url(url)

    def test_redirect_handler_never_forwards_authorization(self):
        with self.assertRaisesRegex(F.Refusal,'redirects'):
            F.NoRedirect().redirect_request(None,None,302,'','', 'https://evil.test/')

    def test_https_certificate_validation_is_mandatory(self):
        context=ssl.create_default_context()
        with patch.object(F.ssl,'create_default_context',return_value=context) as creator:
            client=F.HTTPS('https://bmc.test','/mounted/ca.pem',lambda:'Basic fixture-secret')
        creator.assert_called_once_with(cafile='/mounted/ca.pem')
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode,ssl.CERT_REQUIRED)
        self.assertTrue(any(isinstance(h,F.NoRedirect) for h in client.opener.handlers))

    def test_provider_error_body_and_credentials_are_redacted(self):
        client=object.__new__(F.HTTPS); client.origin=('bmc.test',443)
        client.authorization=lambda:'Basic fixture-password'
        def fail(*args,**kwargs):
            raise urllib.error.HTTPError('https://bmc.test/',401,'fixture-password in response',{},None)
        client.opener=type('Opener',(),{'open':fail})()
        with self.assertRaises(F.Refusal) as caught: client.request('GET','https://bmc.test/')
        self.assertEqual(str(caught.exception),'HTTPS request failed with status 401')

    def test_inventory_check_cli_uses_only_local_read_only_kubectl(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'inventory.json'
            path.write_text(json.dumps(self.inventory))
            (path.parent/'ca.pem').write_text('fixture CA')
            result = subprocess.CompletedProcess([], 0, json.dumps({'items': self.kube.nodes}), '')
            with patch.object(F.sys, 'argv', ['fencing', '--check-inventory', '--inventory', str(path), '--allowed-nodes', 'cp1']), \
                    patch.object(F.subprocess, 'run', return_value=result) as command, \
                    patch.object(F, 'Redfish', side_effect=AssertionError('Unexpected BMC access')):
                self.assertEqual(F.main(), 0)
            self.assertEqual(command.call_args.args[0], ['kubectl', '--request-timeout=10s', 'get', 'nodes', '-o', 'json'])


class ChartTests(unittest.TestCase):
    def test_opt_in_and_least_privilege_resources(self):
        import yaml
        def render(extra):
            result = subprocess.run(['helm', 'template', 'bm-cluster', str(ROOT/'k8s'),
                                     '--set', 'publicDomain=example.test', '--set', 'internalDnsZone=internal.example.test',
                                     '--set', 'gitopsRepositoryURL=https://example.test/platform.git',
                                     '--set', 'cloudflareAccessTeamName=example',
                                     '--show-only', 'templates/node-fencing.yaml', *extra],
                                    text=True, capture_output=True)
            return result
        for extra in ([], ['--set', 'nodeFencing.enabled=true', '--set', 'nodeFencing.nodeNames={cp1}']):
            result = render(extra)
            self.assertNotIn('kind: CronJob', result.stdout)
        result = render(['--set', 'highAvailabilityEnabled=true', '--set', 'nodeFencing.enabled=true',
                         '--set', 'nodeFencing.inventorySecret=node-fencing-inventory', '--set', 'nodeFencing.nodeNames={cp1,worker1}'])
        self.assertEqual(result.returncode, 0, result.stderr)
        objects = list(yaml.safe_load_all(result.stdout))
        role = next(o for o in objects if o['kind']=='ClusterRole')
        self.assertEqual(role['rules'], [
            {'apiGroups':[''], 'resources':['nodes'], 'verbs':['list']},
            {'apiGroups':[''], 'resources':['nodes'], 'resourceNames':['cp1','worker1'], 'verbs':['patch']}])
        cron = next(o for o in objects if o['kind']=='CronJob')['spec']
        self.assertEqual(cron['concurrencyPolicy'], 'Forbid')
        self.assertEqual(cron['jobTemplate']['spec']['backoffLimit'], 0)
        pod = cron['jobTemplate']['spec']['template']['spec']
        self.assertEqual(pod['containers'][0]['args'], ['--apply', '--allowed-nodes', 'cp1,worker1'])
        self.assertEqual(pod['volumes'][1]['secret']['secretName'], 'node-fencing-inventory')
        self.assertTrue(pod['containers'][0]['securityContext']['readOnlyRootFilesystem'])
        self.assertTrue(pod['securityContext']['runAsNonRoot'])
        self.assertIn('@sha256:', pod['containers'][0]['image'])
        script = next(o for o in objects if o['kind']=='ConfigMap')['data']['fence-unresponsive-nodes.py']
        self.assertEqual(script.rstrip(), (ROOT/'k8s/scripts/fence-unresponsive-nodes.py').read_text().rstrip())


if __name__=='__main__': unittest.main()
