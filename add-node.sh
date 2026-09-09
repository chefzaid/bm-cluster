#!/usr/bin/env bash
# Public entry point for server and agent enrollment, remotely or on a new host.
set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_LIBRARY="$SCRIPT_DIR/scripts/lib/installer-prompts.sh"
# shellcheck source=scripts/lib/installer-prompts.sh
source "$PROMPT_LIBRARY"

error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Add control-plane or worker nodes to an existing K3s cluster.

Usage: ./add-node.sh [--role control-plane|worker] [--mode remote|local] [options]

Without options, choose the new node's role, then where the assistant is running:
  remote  Run on an existing control plane and enroll nodes over private SSH.
  local   Run on the new node and join only this machine.

Remote enrollment is recommended: it verifies identities, waits for Ready nodes,
and reconciles scheduling and Longhorn. Control-plane enrollment validates an
odd final server count, backs up/converts SQLite to embedded etcd when needed,
and uses the existing server token, exact K3s version, and scheduling policy.

Common remote selectors (the role determines which nodes are added):
  --count N                 Number of new nodes to prompt for
  --hosts CSV               Tailscale bootstrap SSH hosts
  --ips CSV                 Preconfigured OVHcloud vRack addresses
  --transport vrack|tailscale
  --non-interactive         Require explicit inputs; --yes is an alias

Examples:
  ./add-node.sh
  ./add-node.sh --role control-plane --mode remote --count 2
  ./add-node.sh --role worker --mode remote --transport vrack \
    --ips 10.40.0.12 --node-network-cidr 10.40.0.0/24 \
    --control-plane-schedulable preserve
  ./add-node.sh --role worker --mode local

Both roles use private networking, UFW, AppArmor, and the cluster Registry.
Additional control planes get private API/etcd access and Lynis; workers get
agent-only peer access. Added nodes do not advertise public ingress.

Get all options for a selected role and execution mode:
  ./add-node.sh --role control-plane --mode remote --help
  ./add-node.sh --role control-plane --mode local --help
  ./add-node.sh --role worker --mode remote --help
  ./add-node.sh --role worker --mode local --help

Local control-plane joins require an already prepared embedded-etcd cluster.
Use remote mode to convert SQLite, enforce final quorum, and reconcile topology.
See docs/node-enrollment.md for the complete workflow and security differences.
EOF
}

role=""
mode=""
non_interactive=false
secret_stdin=false
show_help=false
arguments=()
while (( $# > 0 )); do
    case "$1" in
        --role|--node-role|--mode)
            option="$1"; shift
            [[ $# -gt 0 && "$1" != --* ]] || error "Missing value for $option"
            if [[ "$option" == --mode ]]; then
                [[ -z "$mode" || "$mode" == "$1" ]] || error "Conflicting execution modes"
                mode="$1"
            else
                [[ -z "$role" || "$role" == "$1" ]] || error "Conflicting node roles"
                role="$1"
            fi
            ;;
        --role=*|--node-role=*)
            value="${1#*=}"
            [[ -z "$role" || "$role" == "$value" ]] || error "Conflicting node roles"
            role="$value"
            ;;
        --mode=*)
            value="${1#*=}"
            [[ -z "$mode" || "$mode" == "$value" ]] || error "Conflicting execution modes"
            mode="$value"
            ;;
        --non-interactive|--yes)
            non_interactive=true
            arguments+=(--non-interactive)
            ;;
        --hosts|--hosts=*|--ips|--ips=*|--worker-hosts|--worker-hosts=*|--worker-ips|--worker-ips=*|--control-plane-hosts|--control-plane-hosts=*|--control-plane-ips|--control-plane-ips=*)
            non_interactive=true
            arguments+=("$1")
            ;;
        --token-stdin|--tailscale-api-token-stdin) secret_stdin=true; arguments+=("$1") ;;
        -h|--help) show_help=true ;;
        *) arguments+=("$1") ;;
    esac
    shift
done
[[ -z "$role" || "$role" =~ ^(control-plane|worker)$ ]] || error "--role must be control-plane or worker"
[[ -z "$mode" || "$mode" =~ ^(remote|local)$ ]] || error "--mode must be remote or local"
if [[ "$show_help" == true && ( -z "$role" || -z "$mode" ) ]]; then
    usage
    exit 0
fi
if [[ -z "$role" || -z "$mode" ]]; then
    [[ "$non_interactive" == false && "$secret_stdin" == false && -t 0 ]] || \
        error "Specify --role control-plane|worker and --mode remote|local before using automation or secret stdin."
fi

if [[ -z "$role" ]]; then
    installer_prompt_section "New node role" \
        "Choose what the new machine will do in the cluster."
    printf '  1) Control plane - Kubernetes API and embedded etcd\n  2) Worker - application workloads\n' >&2
    while [[ -z "$role" ]]; do
        read -rp 'Select 1 or 2 [2]: ' selection
        case "${selection:-2}" in
            1|control-plane) role=control-plane ;;
            2|worker) role=worker ;;
            *) printf 'Enter 1 for control plane or 2 for worker.\n' >&2 ;;
        esac
    done
fi
if [[ -z "$mode" ]]; then
    installer_prompt_section "Where this assistant is running" \
        "The new node's role is $role."
    printf '  1) Existing control plane - enroll remote nodes over SSH\n  2) New node - join this machine\n' >&2
    while [[ -z "$mode" ]]; do
        read -rp 'Select 1 or 2 [1]: ' selection
        case "${selection:-1}" in
            1|remote) mode=remote ;;
            2|local) mode=local ;;
            *) printf 'Enter 1 for remote enrollment or 2 for a local join.\n' >&2 ;;
        esac
    done
fi

forwarded=()
for argument in "${arguments[@]}"; do
    case "${argument%%=*}" in
        --count|--hosts|--ips)
            [[ "$mode" == remote ]] || error "${argument%%=*} requires --mode remote"
            argument="--$role-${argument#--}"
            ;;
        --worker-count|--worker-hosts|--worker-ips)
            [[ "$role" == worker && "$mode" == remote ]] || error "${argument%%=*} requires worker remote enrollment"
            ;;
        --control-plane-count|--control-plane-hosts|--control-plane-ips)
            [[ "$role" == control-plane && "$mode" == remote ]] || error "${argument%%=*} requires control-plane remote enrollment"
            ;;
    esac
    forwarded+=("$argument")
done
[[ "$show_help" != true ]] || forwarded+=(--help)

case "$role/$mode" in
    control-plane/remote) installer="$SCRIPT_DIR/scripts/add-k3s-control-planes.sh" ;;
    control-plane/local) installer="$SCRIPT_DIR/scripts/install-k3s-server.sh" ;;
    worker/remote) installer="$SCRIPT_DIR/scripts/add-k3s-workers.sh" ;;
    worker/local) installer="$SCRIPT_DIR/scripts/install-k3s-worker.sh" ;;
esac
[[ -x "$installer" ]] || error "Node enrollment implementation is missing or not executable: $installer"
# An inherited K3S_ENROLLMENT_ROLE must never override the user's selection.
K3S_ENROLLMENT_ROLE="$role" exec "$installer" "${forwarded[@]}"
