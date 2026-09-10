#!/usr/bin/env bash
# Exercise role selection and real SSH-policy reconciliation with isolated mocks.
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/network.sh
source "$SCRIPT_DIR/lib/network.sh"
# shellcheck source=lib/control-plane-access.sh
source "$SCRIPT_DIR/lib/control-plane-access.sh"
TEST_DIR="$(mktemp -d /tmp/bm-control-plane-access-test.XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
nodes='{"items":[
 {"metadata":{"name":"cp-01","labels":{"node-role.kubernetes.io/control-plane":"true"}},"status":{"addresses":[{"type":"InternalIP","address":"10.40.0.1"}]}},
 {"metadata":{"name":"cp-02","labels":{"node-role.kubernetes.io/control-plane":"true"}},"status":{"addresses":[{"type":"InternalIP","address":"10.40.0.2"}]}},
 {"metadata":{"name":"cp-03","labels":{"node-role.kubernetes.io/control-plane":"true"}},"status":{"addresses":[{"type":"InternalIP","address":"10.40.0.3"}]}},
 {"metadata":{"name":"worker","labels":{}},"status":{"addresses":[{"type":"InternalIP","address":"10.40.0.20"}]}}
]}'
addresses="$(control_plane_private_ips "$nodes" 10.40.0.0/24)"
[[ "$addresses" == 10.40.0.1,10.40.0.2,10.40.0.3 ]]
# API target and SSH source may be different surviving servers; workers and
# public addresses cannot become trusted administration or API sources.
control_plane_address_member "$addresses" 10.40.0.2
control_plane_address_member "$addresses" 10.40.0.3
if control_plane_address_member "$addresses" 10.40.0.20; then exit 1; fi
if control_plane_address_member "$addresses" 203.0.113.2; then exit 1; fi
bad_nodes="${nodes//10.40.0.3/203.0.113.3}"
if control_plane_private_ips "$bad_nodes" 10.40.0.0/24 >/dev/null; then exit 1; fi

load_function() {
    eval "$(awk -v name="$1" '$0 == name "() {" {active=1} active {print} active && /^}$/ {exit}' "$SCRIPT_DIR/configure-node-security.sh")"
}
for name in private_node_policy prepare_control_plane_ssh_policy persist_control_plane_ssh_policy allow_control_plane_ssh reconcile_control_plane_ssh validate_worker_private_ssh_before_firewall; do
    load_function "$name"
done
info() { :; }
err() { printf '%s\n' "$*" >&2; exit 1; }
configure_tailscale_firewall_integration() { :; }
tailscale_transport_selected() { return 1; }
ip() {
    case "$*" in
        '-4 route get '*) printf '%s dev eno2 src 10.40.0.20\n' "$4" ;;
        '-4 route show default') printf 'default via 203.0.113.1 dev eno1\n' ;;
        '-4 -o address show scope global') printf '3: eno2 inet 10.40.0.20/24 scope global eno2\n' ;;
        *) return 1 ;;
    esac
}
sudo() {
    case "$1" in
        test) [[ -f "$CONTROL_PLANE_SSH_STATE" ]] ;;
        cat) cat "$CONTROL_PLANE_SSH_STATE" ;;
        install) cp "${@: -2:1}" "$CONTROL_PLANE_SSH_STATE" ;;
        ufw)
            if [[ "$2" == status ]]; then printf 'Status: active\n'; else printf '%s\n' "$*" >> "$TEST_DIR/rules"; fi ;;
        *) return 1 ;;
    esac
}
# The helper checks executable availability; this substitute is never invoked.
ufw() { return 1; }
NODE_ROLE=worker
PRIVATE_CONTROL_PLANE=false
CONTROL_PLANE_IP=10.40.0.2
CONTROL_PLANE_SSH_IPS=10.40.0.2,10.40.0.3
CONTROL_PLANE_SSH_STATE="$TEST_DIR/sources"
K3S_NODE_NETWORK_CIDR=10.40.0.0/24
HARDENED_SSH_PORT=22
SSH_CONNECTION='10.40.0.2 50000 10.40.0.20 22'
printf '%s\n' 10.40.0.1 10.40.0.2 10.40.0.3 > "$CONTROL_PLANE_SSH_STATE"
: > "$TEST_DIR/rules"
reconcile_control_plane_ssh
grep -Fxq 'ufw allow in on eno2 from 10.40.0.2 to any port 22 proto tcp comment BM control-plane SSH' "$TEST_DIR/rules"
grep -Fxq 'ufw allow in on eno2 from 10.40.0.3 to any port 22 proto tcp comment BM control-plane SSH' "$TEST_DIR/rules"
grep -Fxq 'ufw --force delete allow in on eno2 from 10.40.0.1 to any port 22 proto tcp comment BM control-plane SSH' "$TEST_DIR/rules"
[[ "$(grep -c delete "$TEST_DIR/rules")" == 1 ]]
if grep -Eq 'reset|default|10.40.0.20|203.0.113' "$TEST_DIR/rules"; then exit 1; fi
: > "$TEST_DIR/rules"
reconcile_control_plane_ssh
if grep -q delete "$TEST_DIR/rules"; then exit 1; fi
# Rerunning full hardening from another surviving server retains the saved set.
CONTROL_PLANE_IP=10.40.0.3
CONTROL_PLANE_SSH_IPS=''
prepare_control_plane_ssh_policy
[[ "$CONTROL_PLANE_SSH_IPS" == 10.40.0.2,10.40.0.3 ]]
: > "$TEST_DIR/rules"
if (CONTROL_PLANE_SSH_IPS=203.0.113.3; reconcile_control_plane_ssh) 2>/dev/null; then exit 1; fi
if (CONTROL_PLANE_IP=10.40.0.1; reconcile_control_plane_ssh) 2>/dev/null; then exit 1; fi
if (CONTROL_PLANE_IP=10.40.0.2; SSH_CONNECTION='203.0.113.2 50000 10.40.0.20 22'; reconcile_control_plane_ssh) 2>/dev/null; then exit 1; fi
[[ ! -s "$TEST_DIR/rules" ]]
printf 'PASS: verified CP sources, surviving-server SSH, stale managed-rule removal, persistence and lockout guards\n'

# Execute the fleet entrypoint with fake Kubernetes/SSH commands. No remote
# commands or local privileged writes are performed by this fixture.
python3 - "$SCRIPT_DIR" "$TEST_DIR" <<'PY'
import json, os, pathlib, subprocess, sys
source, root = map(pathlib.Path, sys.argv[1:])
commands = root / "bin"
commands.mkdir()
mock = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
tool=pathlib.Path(sys.argv[0]).name; args=sys.argv[1:]
with open(os.environ["CALLS"],"a") as f: f.write(json.dumps([tool,args])+"\n")
if tool=="kubectl": print(pathlib.Path(os.environ["NODES"]).read_text())
elif tool=="ip": print("3: eno2 inet 10.40.0.2/24 scope global eno2")
elif tool=="ssh":
 target=args[-2]; command=args[-1]
 if "SSH_CONNECTION" in command: print("10.40.0.2 50000 "+target.split("@")[-1]+" 22")
 elif "mktemp" in command: print("/tmp/bm-node-access.fixture")
'''
for name in ("kubectl","ip","ssh","scp"):
    p=commands/name; p.write_text(mock); p.chmod(0o700)
def node(name, ip, role, lb="false", account=None, exposure="local"):
    labels={"svccontroller.k3s.cattle.io/enablelb":lb,"node.bm-cluster.io/exposure":exposure}
    if role=="cp": labels["node-role.kubernetes.io/control-plane"]="true"
    return {"metadata":{"name":name,"labels":labels,"annotations":
             {"node.bm-cluster.io/ssh-user":account} if account else {}},
            "status":{"addresses":[{"type":"InternalIP","address":ip}]}}
nodes=[node("cp1","10.40.0.1","cp","false",exposure="internet"),node("cp2","10.40.0.2","cp"),
       node("cp3","10.40.0.3","cp"),node("worker","10.40.0.20","worker",account="worker-admin")]
inventory=root/"nodes.json"; inventory.write_text(json.dumps({"items":nodes}))
calls=root/"fleet-calls.jsonl"
env=dict(os.environ,PATH=f"{commands}:{os.environ['PATH']}",CALLS=str(calls),NODES=str(inventory))
command=["bash",str(source/"reconcile-control-plane-access.sh"),"--node-network-cidr","10.40.0.0/24",
         "--control-plane-ip","10.40.0.2","--ssh-user","admin"]
result=subprocess.run(command,env=env,capture_output=True,text=True)
assert result.returncode==0,result.stdout+result.stderr
records=[json.loads(line) for line in calls.read_text().splitlines()]
refresh=[a for tool,a in records if tool=="ssh" and "--reconcile-control-plane-ssh" in a[-1]]
assert len(refresh)==2
assert {a[-2] for a in refresh}=={"admin@10.40.0.3","worker-admin@10.40.0.20"}
assert all("--control-plane-ip 10.40.0.2" in a[-1] and
           "--control-plane-ssh-ips 10.40.0.1\\,10.40.0.2\\,10.40.0.3" in a[-1] for a in refresh),refresh
for bad in ("10.40.0.20","203.0.113.2"):
    calls.write_text("")
    bad_command=[bad if item=="10.40.0.2" else item for item in command]
    result=subprocess.run(bad_command,env=env,capture_output=True,text=True)
    assert result.returncode!=0
    assert not any(json.loads(line)[0] in ("ssh","scp") for line in calls.read_text().splitlines())
print("PASS: fleet refresh from surviving CP, public-node exclusion, per-node SSH account and source rejection")
PY
