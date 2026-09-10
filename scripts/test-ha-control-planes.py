#!/usr/bin/env python3
"""Exercise controller storage policy writes and fleet restarts with isolated hosts."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT/'scripts/configure-ha-control-planes.sh'
MOCK = r'''#!/usr/bin/env python3
import datetime,json,os,pathlib,subprocess,sys
name=pathlib.Path(sys.argv[0]).name; args=sys.argv[1:]
root=pathlib.Path(os.environ['FIXTURE']); state=json.loads((root/'state.json').read_text())
with (root/'calls').open('a') as log: log.write(json.dumps([name,args])+'\n')
if name=='sudo':
 if args[:2]==['systemctl','restart']:
  state['verified'].append('cp1'); (root/'state.json').write_text(json.dumps(state)); sys.exit(0)
 if args[0]=='install': args=[a for i,a in enumerate(args) if a not in ('-o','-g') and (i==0 or args[i-1] not in ('-o','-g'))]
 args=[str(root/'host'/a.removeprefix('/')) if a.startswith(('/etc/systemd/','/etc/default/','/etc/sysconfig/')) else a for a in args]
 sys.exit(subprocess.call(args))
if name=='ip': print('3: eno2 inet 10.40.0.1/24 scope global eno2')
if name=='systemctl' and args[0]=='show':
 print(state.get('started','2020-01-01 00:00:00 UTC') if '--property=ExecMainStartTimestamp' in args else 'a'*32)
if name=='journalctl': print('Running kube-controller-manager --disable-force-detach-on-timeout='+state.get('runningPolicy','true'))
if name=='ssh':
 target,command=args[-2:]; node='cp'+target.split('@')[-1].split('.')[-1]
 if 'SSH_CONNECTION' in command: print('10.40.0.1 50000 '+target.split('@')[-1]+' 22')
 elif 'mktemp' in command: print('/tmp/bm-ha-control-plane.fixture')
 elif 'systemctl restart' in command:
  state['verified'].append(node); (root/'state.json').write_text(json.dumps(state))
 elif '--verify-local' in command: sys.exit(0 if node in state['verified'] else 1)
if name=='kubectl':
 now=datetime.datetime.now(datetime.timezone.utc)
 nodes=[]; leases=[]
 for i in range(1,4):
  node='cp'+str(i); uid='00000000-0000-0000-0000-00000000000'+str(i)
  ready=not (state.get('bad')=='quorum' and i==1)
  age=100 if state.get('bad')=='lease' and i==1 else 0
  nodes.append({'metadata':{'name':node,'uid':uid,'labels':{'node-role.kubernetes.io/control-plane':'true'}},
   'status':{'addresses':[{'type':'InternalIP','address':'10.40.0.'+str(i)}],
    'conditions':[{'type':'Ready','status':'True' if ready else 'Unknown'}]}})
  leases.append({'metadata':{'name':node,'ownerReferences':[{'kind':'Node','uid':uid}]},
   'spec':{'holderIdentity':node,'renewTime':(now-datetime.timedelta(seconds=age)).strftime('%Y-%m-%dT%H:%M:%SZ')}})
 if 'nodes' in args: print(json.dumps({'items':nodes}))
 elif 'leases' in args: print(json.dumps({'items':leases}))
 elif 'get' in args and 'node' in args: print(json.dumps(next(n for n in nodes if n['metadata']['name']==args[args.index('node')+1])))
 elif 'get' in args and 'lease' in args: print(json.dumps(next(n for n in leases if n['metadata']['name']==args[args.index('lease')+1])))
'''


class ControlPlaneTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='bm-ha-controller-test.')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        (self.root/'bin').mkdir()
        (self.root/'host/etc/systemd/system').mkdir(parents=True)
        (self.root/'host/etc/systemd/system/k3s.service').write_text('[Service]\nExecStart=/usr/local/bin/k3s server\n')
        (self.root/'state.json').write_text(json.dumps({'verified':[]}))
        (self.root/'calls').write_text('')
        for name in ('sudo','kubectl','ip','ssh','scp','sleep','systemctl','journalctl'):
            script=self.root/'bin'/name; script.write_text(MOCK); script.chmod(0o700)
        self.env=dict(os.environ, FIXTURE=str(self.root), PATH=f"{self.root/'bin'}:{os.environ['PATH']}",
                      HIGH_AVAILABILITY_ENABLED='true')

    def shell(self, body):
        return subprocess.run(['bash','-c', 'source "$1"\n'+body, 'fixture', str(HELPER)],
                              env=self.env,text=True,capture_output=True,timeout=30)

    def calls(self): return [json.loads(line) for line in (self.root/'calls').read_text().splitlines()]

    def test_prepare_is_additive_idempotent_and_never_restarts(self):
        body='''CONFIG_ROOT="$FIXTURE/config"
CONFIG_PATH="$CONFIG_ROOT/config.yaml.d/99-bm-ha-storage-safety.yaml"
mkdir -p "$CONFIG_ROOT"
printf 'kube-controller-manager-arg:\\n  - concurrent-deployment-syncs=6\\n' > "$CONFIG_ROOT/config.yaml"
prepare_local
prepare_local
'''
        result=self.shell(body)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual((self.root/'config/config.yaml').read_text(), 'kube-controller-manager-arg:\n  - concurrent-deployment-syncs=6\n')
        self.assertIn('kube-controller-manager-arg+:\n  - disable-force-detach-on-timeout=true',
                      (self.root/'config/config.yaml.d/99-bm-ha-storage-safety.yaml').read_text())
        installs=[args for name,args in self.calls() if name=='sudo' and args[0]=='install']
        self.assertEqual(len(installs),1)
        self.assertFalse(any('restart' in args for _,args in self.calls()))

    def test_custom_cli_and_later_overrides_fail_before_writes(self):
        for kind in ('cli','later'):
            with self.subTest(kind=kind):
                if kind=='cli':
                    (self.root/'host/etc/systemd/system/k3s.service').write_text('ExecStart=k3s server --kube-controller-manager-arg=foo\n')
                else:
                    (self.root/'host/etc/systemd/system/k3s.service').write_text('ExecStart=k3s server\n')
                    (self.root/'config/config.yaml.d').mkdir(parents=True,exist_ok=True)
                    (self.root/'config/config.yaml.d/zz-custom.yaml').write_text('kube-controller-manager-arg:\n  - foo=true\n')
                result=self.shell('CONFIG_ROOT="$FIXTURE/config"\nCONFIG_PATH="$CONFIG_ROOT/config.yaml.d/99-bm-ha-storage-safety.yaml"\nprepare_local')
                self.assertNotEqual(result.returncode,0)
                self.assertFalse((self.root/'config/config.yaml.d/99-bm-ha-storage-safety.yaml').exists())

    def test_verification_requires_the_current_controller_startup_flag(self):
        (self.root/'policy.yaml').write_text('kube-controller-manager-arg+:\n  - disable-force-detach-on-timeout=true\n')
        for policy in ('true', 'false'):
            with self.subTest(policy=policy):
                (self.root/'state.json').write_text(json.dumps({'verified': [], 'runningPolicy': policy}))
                result=self.shell('CONFIG_PATH="$FIXTURE/policy.yaml"\nverify_local')
                self.assertEqual(result.returncode == 0, policy == 'true', result.stderr)
        commands=[args for name,args in self.calls() if name=='sudo' and args[0]=='journalctl']
        self.assertTrue(all('_SYSTEMD_INVOCATION_ID='+'a'*32 in args for args in commands))

    def test_unchanged_configuration_cannot_authorize_a_restart(self):
        policy=self.root/'policy.yaml'; policy.write_text('fixture')
        for started, expected in (('2020-01-01 00:00:00 UTC', True), ('2100-01-01 00:00:00 UTC', False)):
            with self.subTest(started=started):
                (self.root/'state.json').write_text(json.dumps({'verified': [], 'started': started}))
                result=self.shell('CONFIG_PATH="$FIXTURE/policy.yaml"\nrestart_pending_local')
                self.assertEqual(result.returncode == 0, expected, result.stderr)

    def fleet(self):
        return self.shell('''prepare_local() { :; }
restart_pending_local() { return 0; }
verify_local() { python3 -c 'import json,os,pathlib,sys;sys.exit(0 if "cp1" in json.loads((pathlib.Path(os.environ["FIXTURE"])/"state.json").read_text())["verified"] else 1)'; }
main --reconcile --node-network-cidr 10.40.0.0/24 --control-plane-ip 10.40.0.1 --ssh-user admin
''')

    def test_fleet_restarts_sequentially_rechecks_heartbeats_and_is_idempotent(self):
        result=self.fleet(); self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        actions=self.calls()
        restarts=[(name,args) for name,args in actions if 'systemctl restart' in ' '.join(args)]
        self.assertEqual(len(restarts),3)
        self.assertIn('admin@10.40.0.2',restarts[0][1]); self.assertIn('admin@10.40.0.3',restarts[1][1])
        self.assertEqual(restarts[2],('sudo',['systemctl','restart','k3s']))
        patches=[args for name,args in actions if name=='kubectl' and 'patch' in args]
        self.assertEqual(len(patches),3)
        self.assertTrue(all('node.bm-cluster.io/fenced-detach-policy' in ' '.join(a) for a in patches))
        (self.root/'calls').write_text('')
        result=self.fleet(); self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse(any('systemctl restart' in ' '.join(a) for _,a in self.calls()))

    def test_restart_refused_when_ready_majority_would_be_lost(self):
        for kind in ('quorum','lease'):
            with self.subTest(kind=kind):
                (self.root/'state.json').write_text(json.dumps({'verified':[],'bad':kind}))
                (self.root/'calls').write_text('')
                result=self.fleet()
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(any(n=='ssh' and 'systemctl restart' in a[-1] for n,a in self.calls()))
                self.assertFalse(any(n=='sudo' and 'restart' in a for n,a in self.calls()))

    def test_membership_change_is_rejected(self):
        result=self.shell("FLEET_MEMBERSHIP='{}'\nfresh_majority ''")
        self.assertNotEqual(result.returncode,0)
        self.assertIn('membership changed',result.stderr)


if __name__=='__main__': unittest.main()
