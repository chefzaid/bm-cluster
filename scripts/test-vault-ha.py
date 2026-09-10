#!/usr/bin/env python3
"""Offline HA recovery and migration boundary tests. No cluster or real keys."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

MOCK_KUBECTL = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
stdin = sys.stdin.read() if '-i' in args or ('--raw' in args and '-f' in args) else ''
root = pathlib.Path(os.environ['FIXTURE'])
with (root/'calls').open('a') as f:
    f.write(json.dumps({'tool':'kubectl','args':args,'stdin':stdin})+'\n')
args = [a for a in args if not a.startswith('--request-timeout=')]
data = json.loads((root/'state.json').read_text())
def save(): (root/'state.json').write_text(json.dumps(data))
def pod_obj(name, value):
    return {'metadata':{'name':name,'uid':value.get('uid',name+'-uid'),
      'labels':{'controller-revision-hash':value.get('revision','revision-new')},
      'ownerReferences':[{'kind':'StatefulSet','name':'vault' if value.get('owned',True) else 'other'}]},
      'spec':{'nodeName':value.get('node',name)},
      'status':{'phase':value.get('phase','Running'),
        'conditions':[{'type':'Ready','status':'True' if value.get('ready',True) else 'False'}]}}
if args[:2] == ['get','pods']:
    print(json.dumps({'items':[pod_obj(n,v) for n,v in data['pods'].items()]}))
elif args[:2] == ['get','nodes']:
    print(json.dumps({'items':data.get('nodes',[])}))
elif args[:2] == ['get','storageclass']:
    pass
elif args[:2] == ['get','statefulset']:
    if data.get('unobserved_controller'):
      data['statefulset']['status']['observedGeneration']=1
    print(json.dumps(data['statefulset']))
elif args[:2] == ['get','pod']:
    name=args[2]
    if data.get('rollout'):
      result=pod_obj(name,data['pods'][name])
      result['spec']['volumes']=[{'name':'audit','persistentVolumeClaim':{'claimName':'audit-'+name}}]
      print(json.dumps(result))
    elif 'jsonpath={.metadata.uid}' in args:
      print('original-pod')
    else:
      print(json.dumps({'metadata':{'uid':'replacement' if data.get('deleted_pod') else 'original-pod'},
       'status':{'phase':'Running'},'spec':{'volumes':[{'name':'audit','persistentVolumeClaim':
       {'claimName':'audit-vault-0' if data.get('deleted_pod') else 'vault-audit'}}]}}))
elif args[0] == 'delete':
    body=json.loads(stdin)
    assert body['preconditions']['uid']
    if '/statefulsets/' in args[args.index('--raw')+1]:
      assert body['propagationPolicy']=='Orphan'
      data['deleted_controller']=True
    else:
      if data.get('rollout'):
        name=args[args.index('--raw')+1].rsplit('/',1)[1]
        value=data['pods'][name]
        assert body['preconditions']['uid']==value.get('uid',name+'-uid')
        value.update(uid=body['preconditions']['uid']+'-replacement',revision=data['statefulset']['status']['updateRevision'])
        data.setdefault('replaced',[]).append(name)
        if data.get('fail_after_replacement'): data['unhealthy']=True
      else:
        assert body['preconditions']['uid']=='original-pod'
        data['deleted_pod']=True
    save()
elif args[0] == 'wait':
    pass
elif args[0] == 'exec':
    pod=args[args.index('-n')+2]
    value=data['pods'].get(pod,{})
    if 'status' in args:
      if value.get('unreachable'):
        import time
        time.sleep(60)
      print(json.dumps({'initialized':value.get('initialized',True),'sealed':value.get('sealed',False),
                       'is_self':not value.get('standby',True)}))
      sys.exit(2 if value.get('sealed') else 0)
    elif 'join' in args:
      assert 'init' not in args
      value['joined']=True; save()
    elif 'sys/unseal' in args:
      assert json.loads(stdin)=={'key':'fixture-key+/=='}
      if value.get('fail_unseal'): sys.exit(1)
      if value.get('initialized') is False: assert value.get('joined')
      value.update(initialized=True,sealed=False); save()
    elif 'list-peers' in args:
      print(json.dumps({'data':{'config':{'servers':[
       {'address':n+'.vault-internal:8201','voter':not data.get('nonvoter')} for n in data['pods']]}}}))
    elif 'autopilot' in args:
      print(json.dumps({'healthy':not data.get('unhealthy'),'failure_tolerance':1,
       'voters':list(data['pods']), 'servers':{n:{'healthy':True} for n in data['pods']}}))
    else: raise AssertionError(args)
else: raise AssertionError(args)
'''


class VaultFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vault-ha-test-')
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.env = dict(os.environ, FIXTURE=str(self.dir), PATH=str(self.dir)+os.pathsep+os.environ['PATH'],
                        VAULT_NAMESPACE='infra', VAULT_UNSEAL_KEY_FILE=str(self.dir/'vault-unseal-key'),
                        VAULT_STATE_DIR=str(self.dir), VAULT_EXEC_TIMEOUT='1s')
        self.env.pop('VAULT_POD', None)
        for name, value in [('vault-unseal-key','fixture-key+/=='), ('vault-bootstrap-token','fixture-root-token')]:
            (self.dir/name).write_text(value+'\n')
        self.tool('kubectl', MOCK_KUBECTL)
        self.tool('sudo', '#!/bin/bash\nif [[ "$1" == install ]]; then exit 0; fi\nexec "$@"\n')
        self.tool('sleep', '#!/bin/bash\nexit 0\n')
        self.tool('helm', '''#!/usr/bin/env python3
import json,os,pathlib,sys
p=pathlib.Path(os.environ['FIXTURE'])
state=json.loads((p/'state.json').read_text())
state['statefulset']['metadata']['generation']=2
state['statefulset']['status']={'observedGeneration':2,'updateRevision':'revision-new'}
(p/'state.json').write_text(json.dumps(state))
with (p/'calls').open('a') as f: f.write(json.dumps({'tool':'helm','args':sys.argv[1:]})+'\\n')
''')
        self.state = {'pods':{f'vault-{i}':{'initialized':True,'sealed':False,'standby':i!=0} for i in range(3)},
          'nodes':[{'metadata':{'name':f'cp{i}'},'status':{'conditions':[{'type':'Ready','status':'True'}]}} for i in range(3)],
          'statefulset':{'metadata':{'uid':'original-controller'},'spec':{'replicas':1,
           'volumeClaimTemplates':[{'metadata':{'name':'data'}}],
           'template':{'spec':{'volumes':[{'name':'audit','persistentVolumeClaim':{'claimName':'vault-audit'}}]}}}}}
        self.save()

    def tool(self, name, source):
        path=self.dir/name; path.write_text(source); path.chmod(0o755)

    def save(self): (self.dir/'state.json').write_text(json.dumps(self.state))

    def calls(self):
        path=self.dir/'calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def shell(self, source):
        return subprocess.run(['bash','-euo','pipefail','-c',source],env=self.env,capture_output=True,text=True,timeout=15)

    def unseal(self): return self.shell(f'bash {ROOT}/scripts/vault-unseal.sh')

    def verify(self): return self.shell(f'{ROOT}/scripts/configure-vault-ha.sh --verify')


class VaultHATests(VaultFixture):
    def test_unseals_survivors_when_original_node_is_absent(self):
        del self.state['pods']['vault-0']
        for p in self.state['pods'].values(): p['sealed']=True
        self.save(); result=self.unseal()
        self.assertEqual(result.returncode,0,result.stderr)
        writes=[c for c in self.calls() if 'sys/unseal' in c['args']]
        self.assertEqual(len(writes),2)
        self.assertNotIn('fixture-key',json.dumps([c['args'] for c in self.calls()]))
        self.assertNotIn('fixture-key',result.stdout+result.stderr)

    def test_empty_replacement_joins_survivor_before_unseal(self):
        self.state['pods']['vault-0'].update(initialized=False,sealed=True)
        self.save(); result=self.unseal()
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.calls(); join=next(i for i,c in enumerate(calls) if 'join' in c['args'])
        write=next(i for i,c in enumerate(calls) if 'sys/unseal' in c['args'])
        self.assertLess(join,write)
        self.assertIn('http://vault-2.vault-internal.infra.svc:8200',calls[join]['args'])
        self.assertFalse(any('init' in c['args'] for c in calls))

    def test_unreachable_first_peer_does_not_block_survivor_recovery(self):
        self.state['pods']['vault-0']['unreachable']=True
        self.state['pods']['vault-1']['sealed']=True
        self.save()
        result=self.unseal()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(any('sys/unseal' in c['args'] and 'vault-1' in c['args'] for c in self.calls()))
        result=self.shell(f'source {ROOT}/scripts/lib/vault-access.sh; vault_runtime_pod infra')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(result.stdout.strip(),('vault-1','vault-2'))

    def test_no_initialized_peer_never_initializes_or_sends_key(self):
        for p in self.state['pods'].values(): p.update(initialized=False,sealed=True)
        self.save(); self.assertEqual(self.unseal().returncode,0)
        self.assertFalse(any('join' in c['args'] or 'sys/unseal' in c['args'] or 'init' in c['args'] for c in self.calls()))

    def test_one_failure_does_not_skip_other_survivors(self):
        for p in self.state['pods'].values(): p['sealed']=True
        self.state['pods']['vault-0']['fail_unseal']=True
        self.save(); self.assertNotEqual(self.unseal().returncode,0)
        self.assertEqual(sum('sys/unseal' in c['args'] for c in self.calls()),3)

    def test_unowned_pod_never_receives_recovery_key(self):
        self.state['pods']['vault-9']={'sealed':True,'owned':False}
        self.save(); self.assertEqual(self.unseal().returncode,0)
        self.assertFalse(any('vault-9' in c['args'] for c in self.calls()))

    def test_active_selector_uses_surviving_leader(self):
        del self.state['pods']['vault-0']
        self.state['pods']['vault-2']['standby']=False
        self.save()
        result=self.shell(f'source {ROOT}/scripts/lib/vault-access.sh; vault_runtime_pod infra')
        self.assertEqual(result.stdout.strip(),'vault-2',result.stderr)

    def test_quorum_requires_three_healthy_voters_on_distinct_nodes(self):
        self.assertEqual(self.verify().returncode,0)
        for change in ('unhealthy','nonvoter','same_node'):
            with self.subTest(change=change):
                self.state[change]=True
                if change=='same_node': self.state['pods']['vault-2']['node']='vault-1'
                self.save(); self.assertNotEqual(self.verify().returncode,0)
                self.state.pop(change)

    def test_existing_storage_requires_gate_before_any_mutation(self):
        result=self.shell(f'{ROOT}/scripts/configure-vault-ha.sh')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('maintenance migration',result.stderr)
        self.assertFalse(any(c['tool']=='helm' or c['args'][0]=='delete' for c in self.calls()))

    def test_migration_orphans_controller_then_checks_quorum_before_pod_replacement(self):
        # Replace only backup and polling boundaries; main uses real guarded
        # deletes, real quorum checks, and its actual migration orchestration.
        result=self.shell(f'''source {ROOT}/scripts/configure-vault-ha.sh
save_migration_backup() {{ echo snapshot >> "$FIXTURE/events"; }}
wait_healthy() {{ verify_ha; echo quorum >> "$FIXTURE/events"; }}
main --migrate-existing
''')
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.calls()
        deletes=[(i,c) for i,c in enumerate(calls) if c['args'][0]=='delete']
        self.assertEqual(len(deletes),2)
        self.assertIn('/statefulsets/vault',deletes[0][1]['args'][2])
        self.assertEqual(json.loads(deletes[0][1]['stdin'])['propagationPolicy'],'Orphan')
        helm=next(i for i,c in enumerate(calls) if c['tool']=='helm')
        quorum=next(i for i,c in enumerate(calls) if 'autopilot' in c['args'])
        self.assertLess(deletes[0][0],helm)
        self.assertLess(helm,quorum)
        self.assertLess(quorum,deletes[1][0])
        self.assertFalse(any('pvc' in c['args'] and c['args'][0]=='delete' for c in calls))

    def test_unhealthy_new_peers_preserve_original_pod(self):
        self.state['unhealthy']=True; self.save()
        result=self.shell(f'''source {ROOT}/scripts/configure-vault-ha.sh
save_migration_backup() {{ :; }}
wait_healthy() {{ verify_ha; }}
main --migrate-existing
''')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c['args'][0]=='delete' and '/pods/' in ' '.join(c['args']) for c in self.calls()))


    def setup_routine_rollout(self, changed=True):
        self.state['rollout']=True
        self.state['statefulset']['spec']['replicas']=3
        self.state['statefulset']['spec']['volumeClaimTemplates'].append({'metadata':{'name':'audit'}})
        for pod in self.state['pods'].values():
            pod['revision']='revision-old' if changed else 'revision-new'
        self.save()

    def routine_rollout(self):
        # Real orchestration, quorum checks and UID deletes; fail a broken
        # health poll immediately instead of waiting on an offline fixture.
        return self.shell(f'''source {ROOT}/scripts/configure-vault-ha.sh
wait_healthy() {{ verify_ha; }}
main
''')

    def test_unchanged_template_does_not_replace_healthy_peers(self):
        self.setup_routine_rollout(changed=False)
        result=self.routine_rollout()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(any(c['args'][0]=='delete' for c in self.calls()))

    def test_changed_template_replaces_standbys_then_active_with_health_between(self):
        self.setup_routine_rollout()
        result=self.routine_rollout()
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.calls()
        deletes=[(i,c) for i,c in enumerate(calls) if c['args'][0]=='delete']
        self.assertEqual([c['args'][2].rsplit('/',1)[1] for _,c in deletes],['vault-1','vault-2','vault-0'])
        for index,(position,call) in enumerate(deletes):
            self.assertTrue(json.loads(call['stdin'])['preconditions']['uid'].endswith('-uid'))
            previous=deletes[index-1][0] if index else 0
            self.assertTrue(any('autopilot' in c['args'] for c in calls[previous:position]))
        final=json.loads((self.dir/'state.json').read_text())
        self.assertTrue(all(p['revision']=='revision-new' for p in final['pods'].values()))
        self.assertFalse(any('pvc' in c['args'] and c['args'][0]=='delete' for c in calls))

    def test_changed_template_stops_after_replacement_loses_health(self):
        self.setup_routine_rollout()
        self.state['fail_after_replacement']=True
        self.save()
        result=self.routine_rollout()
        self.assertNotEqual(result.returncode,0)
        deletes=[c for c in self.calls() if c['args'][0]=='delete']
        self.assertEqual(len(deletes),1)
        self.assertTrue(deletes[0]['args'][2].endswith('/vault-1'))

    def test_unobserved_controller_template_never_replaces_peers(self):
        self.setup_routine_rollout()
        self.state['unobserved_controller']=True
        self.state['statefulset']['status']={'observedGeneration':1,'updateRevision':'revision-old'}
        self.save()
        result=self.routine_rollout()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('has not observed',result.stderr)
        self.assertFalse(any(c['args'][0]=='delete' for c in self.calls()))


class RecoveryDistributionTests(VaultFixture):
    def setUp(self):
        super().setUp()
        self.state['nodes']=[]
        for i,role in [(1,'control-plane'),(2,'control-plane'),(3,'worker')]:
            self.state['nodes'].append({'metadata':{'name':f'node-{i}',
                'labels':{f'node-role.kubernetes.io/{role}':'true'},
                'annotations':{'node.bm-cluster.io/ssh-user':f'admin{i}'}},
                'status':{'addresses':[{'type':'InternalIP','address':f'10.40.0.{i}'}]}})
        self.save()
        self.tool('ip','#!/bin/bash\necho "2: private inet 10.40.0.1/24 scope global private"\n')
        self.tool('sudo',r"""#!/bin/bash
if [[ "$1" == stat ]]; then echo "${MOCK_MODE:-0:0:600}"; exit; fi
exec "$@"
""")
        self.tool('ssh',r"""#!/usr/bin/env python3
import json,os,pathlib,sys
args=sys.argv[1:]; command=args[-1]
stdin=sys.stdin.read() if '--receive-stdin' in command else ''
p=pathlib.Path(os.environ['FIXTURE'])
with (p/'calls').open('a') as f: f.write(json.dumps({'tool':'ssh','args':args,'stdin':stdin})+'\n')
if 'SSH_CONNECTION' in command: print(os.environ.get('MOCK_CONNECTION','10.40.0.1 5555 10.40.0.2 22'))
elif 'mktemp' in command: print('/tmp/bm-vault-recovery.fixture')
""")
        self.tool('scp',r"""#!/usr/bin/env python3
import json,os,pathlib,sys
p=pathlib.Path(os.environ['FIXTURE'])
with (p/'calls').open('a') as f: f.write(json.dumps({'tool':'scp','args':sys.argv[1:]})+'\n')
""")

    def distribute(self, extra='--all-control-planes', source='10.40.0.1'):
        return self.shell(f'{ROOT}/scripts/sync-vault-recovery.sh {extra} --node-network-cidr 10.40.0.0/24 --control-plane-ip {source}')

    def test_distribution_targets_only_verified_control_planes_and_streams_secrets(self):
        result=self.distribute()
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.calls()
        transfers=[c for c in calls if c['tool']=='ssh' and '--receive-stdin' in c['args'][-1]]
        self.assertEqual(len(transfers),1)
        self.assertIn('admin2@10.40.0.2',transfers[0]['args'])
        self.assertEqual(transfers[0]['stdin'],'fixture-key+/==\nfixture-root-token\n')
        self.assertNotIn('10.40.0.3',json.dumps([c['args'] for c in calls if c['tool'] in ('ssh','scp')]))
        self.assertNotIn('fixture-key',json.dumps([c['args'] for c in calls]))
        self.assertNotIn('fixture-root-token',result.stdout+result.stderr)
        self.assertFalse(any(any(str(self.dir/name) in a for a in c['args']) for c in calls if c['tool']=='scp'
                             for name in ('vault-unseal-key','vault-bootstrap-token')))

    def test_distribution_requires_explicit_selection(self):
        self.assertNotEqual(self.distribute(extra='').returncode,0)
        self.assertFalse(any(c['tool']=='ssh' for c in self.calls()))

    def test_distribution_rejects_worker_or_public_source(self):
        for source in ('10.40.0.3','203.0.113.1'):
            self.assertNotEqual(self.distribute(source=source).returncode,0)
        self.assertFalse(any(c['tool']=='ssh' for c in self.calls()))

    def test_distribution_rejects_actual_ssh_source_mismatch_before_secret_transfer(self):
        self.env['MOCK_CONNECTION']='10.40.0.3 5555 10.40.0.2 22'
        self.assertNotEqual(self.distribute().returncode,0)
        self.assertFalse(any(c['tool']=='ssh' and '--receive-stdin' in c['args'][-1] for c in self.calls()))

    def test_distribution_rejects_exposed_recovery_files(self):
        self.env['MOCK_MODE']='1000:1000:644'
        self.assertNotEqual(self.distribute().returncode,0)
        self.assertFalse(any(c['tool']=='ssh' for c in self.calls()))

if __name__=='__main__': unittest.main()
