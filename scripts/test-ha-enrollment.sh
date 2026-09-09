#!/usr/bin/env bash
# Exercise real server/agent installation entrypoints with isolated host mocks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$SCRIPT_DIR" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
mock = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
record = {"tool": name, "args": args}
if name == "mock-k3s-install":
    record.update(token_present=bool(os.environ.get("K3S_TOKEN")),
                  version=os.environ.get("INSTALL_K3S_VERSION"),
                  node_name=os.environ.get("K3S_NODE_NAME"))
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
if name == "ip":
    if "route" in args and "get" in args:
        print("10.40.0.1 dev eno2 src 10.40.0.2")
    elif "route" in args:
        print("default via 203.0.113.1 dev eno1")
    else:
        print("2: eno2 inet 10.40.0.2/24 scope global eno2")
elif name == "systemctl" and args[0] == "cat":
    sys.exit(0 if args[1] == os.environ.get("MOCK_EXISTING_SERVICE") else 1)
elif name == "sudo":
    args = [arg for arg in args if not arg.startswith("--preserve-env=")]
    if args == ["-v"]:
        sys.exit(0)
    sys.exit(subprocess.call(args))
elif name == "curl" and "--output" in args:
    pathlib.Path(args[args.index("--output") + 1]).write_text(
        '#!/bin/sh\nexec mock-k3s-install "$@"\n')
'''

with tempfile.TemporaryDirectory(prefix="bm-cluster-ha-enrollment-test.") as directory:
    fixture = Path(directory)
    scripts = fixture / "scripts"
    scripts.mkdir()
    shutil.copy2(source.parent / "add-node.sh", fixture / "add-node.sh")
    shutil.copytree(source / "lib", scripts / "lib")
    for name in ("install-k3s-worker.sh", "install-k3s-server.sh", "add-k3s-control-planes.sh", "add-k3s-workers.sh"):
        shutil.copy2(source / name, scripts / name)
    commands = fixture / "bin"
    commands.mkdir()
    names = ("ip", "sudo", "systemctl", "apt-get", "dpkg", "curl", "mock-k3s-install")
    helpers = ("configure-node-security.sh", "configure-k3s-apparmor.sh", "configure-longhorn-host.sh",
               "configure-k3s-registry-mirror.sh", "configure-k3s-control-plane-network.sh",
               "configure-ovh-vrack.sh", "configure-tailscale.sh")
    for target in [commands / name for name in names] + [scripts / name for name in helpers]:
        target.write_text(mock)
        target.chmod(0o700)
    log = fixture / "calls.jsonl"
    environment = dict(os.environ, PATH=f"{commands}:{os.environ['PATH']}", MOCK_LOG=str(log))
    for key in ("K3S_ENROLLMENT_ROLE", "CONTROL_PLANE_SCHEDULABLE", "K3S_REGISTRY_HOST", "PLATFORM_DOMAIN"):
        environment.pop(key, None)
    common = ["--non-interactive", "--token-stdin", "--server-url", "https://10.40.0.1:6443",
              "--node-ip", "10.40.0.2", "--node-name", "cp-02", "--domain", "example.com",
              "--transport", "vrack", "--node-network-cidr", "10.40.0.0/24",
              "--k3s-version", "v1.35.1+k3s1"]

    def run(extra=(), role="control-plane", existing="", expected=0, arguments=None,
            input_data="fixture-secret-never-in-argv\n"):
        log.write_text("")
        current = dict(environment, K3S_ENROLLMENT_ROLE="worker" if role == "control-plane" else "control-plane",
                       MOCK_EXISTING_SERVICE=existing)
        result = subprocess.run(["bash", str(fixture / "add-node.sh"), "--role", role, "--mode", "local",
                                 *(common if arguments is None else arguments), *extra],
                                input=input_data, text=True,
                                capture_output=True, env=current)
        assert (result.returncode == 0) == (expected == 0), result.stdout + result.stderr
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        assert "fixture-secret-never-in-argv" not in log.read_text() + result.stdout + result.stderr
        return calls, result.stdout + result.stderr

    for schedulable in ("true", "false"):
        calls, _ = run(["--control-plane-schedulable", schedulable])
        installed = [call for call in calls if call["tool"] == "mock-k3s-install"]
        assert len(installed) == 1
        install = installed[0]
        args = install["args"]
        assert args[0] == "server" and "--cluster-init" not in args
        assert args[args.index("--server") + 1] == "https://10.40.0.1:6443"
        assert args[args.index("--advertise-address") + 1] == "10.40.0.2"
        assert args[args.index("--disable") + 1] == "traefik"
        assert "--secrets-encryption" in args and "--node-external-ip" not in args
        assert "svccontroller.k3s.cattle.io/enablelb=false" in args
        assert ("--node-taint" in args) == (schedulable == "false")
        assert install["token_present"] and install["version"] == "v1.35.1+k3s1"
        policies = [call for call in calls if call["tool"] == "configure-node-security.sh"]
        assert len(policies) == 2
        assert all("--private-control-plane" in call["args"] for call in policies)
        network = next(call for call in calls if call["tool"] == "configure-k3s-control-plane-network.sh")
        assert "--private-only" in network["args"]

    calls, _ = run(role="worker")
    worker = next(call for call in calls if call["tool"] == "mock-k3s-install")
    assert worker["args"][0] == "agent" and "--secrets-encryption" not in worker["args"]
    assert "node.bm-cluster.io/role=worker" in worker["args"]
    assert all("--private-control-plane" not in call["args"] for call in calls)

    for role, service in (("control-plane", "k3s-agent.service"),
                          ("control-plane", "k3s.service"), ("worker", "k3s.service")):
        calls, output = run(["--control-plane-schedulable", "true"], role, service, expected=1)
        assert "already has a K3s" in output
        assert not any(call["tool"] in helpers for call in calls), calls
        assert not any(call["tool"] == "mock-k3s-install" for call in calls)

    _, output = run(expected=1)
    assert "require --control-plane-schedulable" in output
    _, output = run(["--control-plane-schedulable", "true"], arguments=common[:-2], expected=1)
    assert "exact --k3s-version" in output
    _, output = run(["--control-plane-schedulable", "true", "--taints",
                     "node-role.kubernetes.io/control-plane=true:NoSchedule"], expected=1)
    assert "through --control-plane-schedulable" in output

    # Interactive local control planes collect required version/scheduling
    # settings before validation; transport account work is isolated here.
    with (scripts / "lib/transport-guide.sh").open("a") as guide:
        guide.write('\ntransport_guide_vrack_account() { :; }\n')
    interactive = common[2:-2]
    calls, output = run(arguments=interactive,
                        input_data="v1.35.1+k3s1\ntrue\n\nfixture-secret-never-in-argv\n\n\n")
    install = next(call for call in calls if call["tool"] == "mock-k3s-install")
    assert install["args"][0] == "server" and install["version"] == "v1.35.1+k3s1"

print("PASS: server/agent joins, exact version, private exposure, NoSchedule, secret handling, and role collision guards")
PY

# The manager's network/SSH operations are mocked; evaluate only its actual
# enrollment and count functions, never its host-changing top-level flow.
# ShellCheck 0.10 reports indirect mock calls as SC2317; 0.11 uses SC2329.
# shellcheck disable=SC2034,SC2317,SC2329
(
    TEST_DIR="$(mktemp -d /tmp/bm-cluster-enrollment-manager-test.XXXXXX)"
    trap 'rm -r -- "$TEST_DIR"' EXIT
    # shellcheck source=lib/network.sh
    source "$SCRIPT_DIR/lib/network.sh"
    load_function() {
        eval "$(awk -v name="$1" '$0 == name "() {" {active=1} active {print} active && /^}$/ {exit}' "$SCRIPT_DIR/add-k3s-workers.sh")"
    }
    info() { :; }
    error() { printf '%s\n' "$*" >&2; exit 1; }
    check_target() { :; }
    check_bootstrap_target() { :; }
    build_target() { printf '%s' "$1"; }
    remote_hostname() { printf '%s' "${1%%.*}"; }
    kubectl() {
        printf 'kubectl %s\n' "$*" >> "$TEST_DIR/calls"
        if [[ "$*" == 'get nodes -o json' ]]; then printf '%s\n' "$MOCK_NODES"; fi
    }
    ssh() {
        printf 'ssh %s\n' "$*" >> "$TEST_DIR/calls"
        case "$*" in
            *'mktemp -d'*) printf '/tmp/bm-cluster-worker.fixture\n' ;;
            *'k3s --version'*) printf '%s\n' "$K3S_VERSION" ;;
            *'--token-stdin'*)
                local secret
                read -r secret
                [[ "$secret" == "$JOIN_TOKEN" ]]
                ;;
        esac
    }
    scp() { printf 'scp %s\n' "$*" >> "$TEST_DIR/calls"; }
    load_function install_worker
    load_function preflight_control_plane_count
    ENROLLMENT_ROLE=control-plane
    NODE_TRANSPORT=vrack
    SERVER_URL=https://10.40.0.1:6443
    SERVER_PRIVATE_IP=10.40.0.1
    NODE_NETWORK_CIDR=10.40.0.0/24
    SSH_PORT=22
    ssh_options=()
    scp_options=()
    K3S_VERSION=v1.35.1+k3s1
    JOIN_CONTROL_PLANE_SCHEDULABLE=false
    PLATFORM_DOMAIN=example.com
    JOIN_TOKEN=fixture-token-never-in-arguments
    WORKER_INSTALLER="$SCRIPT_DIR/install-k3s-worker.sh"
    K3S_APPARMOR_INSTALLER="$SCRIPT_DIR/configure-k3s-apparmor.sh"
    K3S_REGISTRY_MIRROR_SCRIPT="$SCRIPT_DIR/configure-k3s-registry-mirror.sh"
    TAILSCALE_CONFIGURATOR="$SCRIPT_DIR/configure-tailscale.sh"
    OVH_VRACK_CONFIGURATOR="$SCRIPT_DIR/configure-ovh-vrack.sh"
    NETWORK_LIBRARY="$SCRIPT_DIR/lib/network.sh"
    PROMPT_LIBRARY="$SCRIPT_DIR/lib/installer-prompts.sh"
    TRANSPORT_GUIDE_LIBRARY="$SCRIPT_DIR/lib/transport-guide.sh"
    K3S_NETWORK_CONFIGURATOR="$SCRIPT_DIR/configure-k3s-control-plane-network.sh"
    K3S_APPARMOR_PROFILE="$SCRIPT_DIR/../config/apparmor/cri-containerd.apparmor.d"
    LONGHORN_HOST_CONFIGURATOR="$SCRIPT_DIR/configure-longhorn-host.sh"
    LONGHORN_MULTIPATH_CONFIG="$SCRIPT_DIR/../config/multipath/multipath-longhorn.conf"
    SECURITY_HARDENER="$SCRIPT_DIR/configure-node-security.sh"
    LYNIS_SCHEDULER="$SCRIPT_DIR/configure-lynis-schedule.sh"
    NODE_AUDITOR="$SCRIPT_DIR/audit-cluster-nodes.sh"
    MOCK_NODES='{"items":[]}'
    install_worker cp-02  cp-02 10.40.0.2 '' '' 10.40.0.1
    for expected in '--node-role control-plane' '--control-plane-schedulable false' '--domain example.com' 'lib/installer-prompts.sh' 'config/apparmor/' 'config/multipath/' 'configure-longhorn-host.sh' 'configure-lynis-schedule.sh' 'enablelb=false'; do
        grep -Fq -- "$expected" "$TEST_DIR/calls"
    done
    if grep -Fq -- "$JOIN_TOKEN" "$TEST_DIR/calls"; then exit 1; fi

    MOCK_NODES='{"items":[{"metadata":{"name":"cp-02","labels":{"node-role.kubernetes.io/control-plane":"true"}},"status":{"addresses":[{"type":"InternalIP","address":"10.40.0.2"}]}}]}'
    : > "$TEST_DIR/calls"
    install_worker cp-02 cp-02 10.40.0.2 '' '' 10.40.0.1
    if grep -q '^scp ' "$TEST_DIR/calls"; then exit 1; fi
    grep -q 'enablelb=false' "$TEST_DIR/calls"
    if (install_worker cp-02 wrong-name 10.40.0.2 '' '' 10.40.0.1) > "$TEST_DIR/error" 2>&1; then exit 1; fi
    grep -q 'collision' "$TEST_DIR/error"
    MOCK_NODES="${MOCK_NODES//node-role.kubernetes.io\/control-plane/node-role.kubernetes.io\/worker}"
    if (install_worker cp-02 cp-02 10.40.0.2 '' '' 10.40.0.1) > "$TEST_DIR/error" 2>&1; then exit 1; fi
    grep -q 'refusing to replace' "$TEST_DIR/error"

    MOCK_NODES='{"items":[{"metadata":{"name":"cp-01","labels":{"node-role.kubernetes.io/control-plane":"true"}},"status":{"addresses":[{"type":"InternalIP","address":"10.40.0.1"}]}}]}'
    NON_INTERACTIVE=true
    EXPECTED_CONTROL_PLANE_COUNT=3
    REQUESTED_WORKER_COUNT=2
    WORKER_IPS=10.40.0.2,10.40.0.3
    preflight_control_plane_count
    [[ "$EXPECTED_CONTROL_PLANE_COUNT" == 3 ]]
    # Reject an even final membership before any remote enrollment takes place.
    WORKER_IPS=10.40.0.2
    REQUESTED_WORKER_COUNT=1
    if (preflight_control_plane_count) > "$TEST_DIR/error" 2>&1; then exit 1; fi
    grep -q 'odd final count' "$TEST_DIR/error"
    WORKER_IPS=10.40.0.2,10.40.0.2
    REQUESTED_WORKER_COUNT=2
    if (preflight_control_plane_count) > "$TEST_DIR/error" 2>&1; then exit 1; fi
    grep -q 'Duplicate' "$TEST_DIR/error"
    # A partial previous run with CP 2 already joined still completes at 3.
    MOCK_NODES="$(jq '.items += [{metadata:{name:"cp-02",labels:{"node-role.kubernetes.io/control-plane":"true"}},status:{addresses:[{type:"InternalIP",address:"10.40.0.2"}]}}]' <<< "$MOCK_NODES")"
    WORKER_IPS=10.40.0.2,10.40.0.3
    preflight_control_plane_count
    [[ "$EXPECTED_CONTROL_PLANE_COUNT" == 3 ]]
    NODE_TRANSPORT=tailscale
    WORKER_HOSTS=cp-02.example.com,cp-03.example.com
    preflight_control_plane_count
    [[ "$EXPECTED_CONTROL_PLANE_COUNT" == 3 ]]

    # Only a validated server expansion can prepare the bootstrap datastore.
    load_function prepare_control_plane_datastore
    export MOCK_DATASTORE_DIR="$TEST_DIR/datastore"
    mkdir "$MOCK_DATASTORE_DIR"
    mock_privileged() {
        case "$*" in
            'test -d /var/lib/rancher/k3s/server/db/etcd/member') [[ -f "$MOCK_DATASTORE_DIR/etcd" ]] ;;
            'test -s /var/lib/rancher/k3s/server/db/state.db') [[ -f "$MOCK_DATASTORE_DIR/sqlite" ]] ;;
            'cat /var/lib/rancher/k3s/server/token') printf 'refreshed-fixture-token\n' ;;
            *) return 1 ;;
        esac
    }
    LOCAL_SUDO=(mock_privileged)
    K3S_HA_SCRIPT="$TEST_DIR/prepare-etcd.sh"
    cat > "$K3S_HA_SCRIPT" <<'MOCK'
#!/bin/sh
touch "$MOCK_DATASTORE_DIR/prepared" "$MOCK_DATASTORE_DIR/etcd"
MOCK
    chmod +x "$K3S_HA_SCRIPT"
    ENROLLMENT_ROLE=worker
    prepare_control_plane_datastore
    [[ ! -f "$MOCK_DATASTORE_DIR/prepared" ]]
    ENROLLMENT_ROLE=control-plane
    if (prepare_control_plane_datastore) > "$TEST_DIR/error" 2>&1; then exit 1; fi
    [[ ! -f "$MOCK_DATASTORE_DIR/prepared" ]]
    touch "$MOCK_DATASTORE_DIR/sqlite"
    preflight_control_plane_count
    prepare_control_plane_datastore
    [[ -f "$MOCK_DATASTORE_DIR/prepared" && "$JOIN_TOKEN" == refreshed-fixture-token ]]
    rm "$MOCK_DATASTORE_DIR/prepared"
    prepare_control_plane_datastore
    [[ ! -f "$MOCK_DATASTORE_DIR/prepared" ]]
)
printf '%s\n' 'PASS: remote dependency bundle, role collision checks, CP reuse, quorum validation, datastore preparation, and partial-run recovery'
