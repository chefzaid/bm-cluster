#!/usr/bin/env bash
# Refresh private-node administration from the authenticated cluster inventory.
# This changes only managed SSH allowances; it never restarts K3s or resets UFW.
set -euo pipefail
set +x
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/network.sh
source "$SCRIPT_DIR/lib/network.sh"
# shellcheck source=lib/control-plane-access.sh
source "$SCRIPT_DIR/lib/control-plane-access.sh"

NODE_CIDR="${K3S_NODE_NETWORK_CIDR:-}"
SOURCE_IP="${K3S_PRIVATE_ADDRESS:-}"
SSH_USER="${K3S_NODE_SSH_USER:-${USER:-}}"
SSH_PORT="${K3S_NODE_SSH_PORT:-22}"
IDENTITY_FILE="${K3S_NODE_SSH_IDENTITY_FILE:-}"
error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: reconcile-control-plane-access.sh [options]
  --node-network-cidr CIDR  Trusted RFC1918 or Tailscale node network
  --control-plane-ip IP    This control plane's private SSH source address
  --ssh-user USER          SSH account on existing private nodes
  --ssh-port PORT          SSH port (default: 22)
  --identity-file PATH     Optional SSH private key

Run on any registered control plane. The current Kubernetes inventory selects
control-plane SSH sources and private node targets. Nodes with a recorded
node.bm-cluster.io/ssh-user annotation use that account instead of --ssh-user.
Existing SSH keys and passwordless sudo are required. Public-entry nodes retain
their existing administration policy. Unreachable private nodes fail the run.
EOF
}
while (( $# )); do
    case "$1" in
        --node-network-cidr|--control-plane-ip|--ssh-user|--ssh-port|--identity-file)
            option="$1"; shift; (( $# )) || error "Missing value for $option"
            case "$option" in
                --node-network-cidr) NODE_CIDR="$1" ;;
                --control-plane-ip) SOURCE_IP="$1" ;;
                --ssh-user) SSH_USER="$1" ;;
                --ssh-port) SSH_PORT="$1" ;;
                --identity-file) IDENTITY_FILE="$1" ;;
            esac ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1" ;;
    esac
    shift
done
if ! command -v kubectl >/dev/null || ! command -v jq >/dev/null; then error "kubectl and jq are required"; fi
trusted_private_cidr "$NODE_CIDR" || error "A private node CIDR is required"
[[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]] || error "Invalid SSH port"
[[ -z "$IDENTITY_FILE" || -f "$IDENTITY_FILE" ]] || error "SSH identity file does not exist"
nodes="$(kubectl get nodes -o json)"
addresses="$(control_plane_private_ips "$nodes" "$NODE_CIDR")" || error "Control-plane addresses must be private InternalIPs in the node network"
control_plane_address_member "$addresses" "$SOURCE_IP" || error "The SSH source is not a registered control-plane private address"
[[ -n "$(interface_owning_ip "$SOURCE_IP")" ]] || error "The SSH source must belong to this host"

ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
scp_options=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -P "$SSH_PORT")
if [[ -n "$IDENTITY_FILE" ]]; then ssh_options+=(-i "$IDENTITY_FILE"); scp_options+=(-i "$IDENTITY_FILE"); fi
targets="$(jq -r --arg source "$SOURCE_IP" '
  .items[] | . as $node |
  ([.status.addresses[]? | select(.type == "InternalIP") | .address][0] // "") as $ip |
  select($ip != $source) |
  ((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
   (.metadata.labels | has("node-role.kubernetes.io/master"))) as $cp |
  select(($cp | not) or .metadata.labels["node.bm-cluster.io/exposure"] == "local") |
  [.metadata.name, $ip, (if $cp then "control-plane" else "worker" end),
   (.metadata.annotations["node.bm-cluster.io/ssh-user"] // "-")] | @tsv
' <<< "$nodes")"

remote_dir=""; target=""
cleanup() {
    if [[ "$remote_dir" == /tmp/bm-node-access.* && -n "$target" ]]; then
        ssh -n "${ssh_options[@]}" "$target" "rm -rf -- $(printf '%q' "$remote_dir")" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT HUP INT TERM
while IFS=$'\t' read -r name address role recorded_user; do
    [[ -n "$name" ]] || continue
    if ! trusted_private_ipv4 "$address" || ! cidr_contains_ip "$NODE_CIDR" "$address"; then error "Node $name has no usable private address"; fi
    account="$SSH_USER"; [[ "$recorded_user" == - ]] || account="$recorded_user"
    [[ "$account" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] || error "Invalid SSH account for node $name"
    target="$account@$address"
    connection="$(ssh -n "${ssh_options[@]}" "$target" '(test "$(id -u)" -eq 0 || sudo -n true) && printf "%s" "$SSH_CONNECTION"')"
    read -r actual_source _ actual_target actual_port <<< "$connection"
    [[ "$actual_source" == "$SOURCE_IP" && "$actual_target" == "$address" && "$actual_port" == "$SSH_PORT" ]] || error "Private SSH identity check failed for $name"
    remote_dir="$(ssh -n "${ssh_options[@]}" "$target" 'mktemp -d /tmp/bm-node-access.XXXXXX')"
    [[ "$remote_dir" =~ ^/tmp/bm-node-access\.[A-Za-z0-9]+$ ]] || error "Invalid remote temporary directory"
    quoted_dir="$(printf '%q' "$remote_dir")"
    ssh -n "${ssh_options[@]}" "$target" "mkdir -m 700 $quoted_dir/lib"
    scp "${scp_options[@]}" "$SCRIPT_DIR/configure-node-security.sh" "$target:$remote_dir/"
    scp "${scp_options[@]}" "$SCRIPT_DIR/lib/network.sh" "$target:$remote_dir/lib/"
    args=(--apply --reconcile-control-plane-ssh --server-exposure local --node-role "$role"
          --control-plane-ip "$SOURCE_IP" --control-plane-ssh-ips "$addresses" --ssh-port "$SSH_PORT")
    [[ "$role" != control-plane ]] || args+=(--private-control-plane)
    printf -v command 'K3S_NODE_NETWORK_CIDR=%q bash %q' "$NODE_CIDR" "$remote_dir/configure-node-security.sh"
    for arg in "${args[@]}"; do printf -v quoted ' %q' "$arg"; command+="$quoted"; done
    ssh -n "${ssh_options[@]}" "$target" "$command"
    ssh -n "${ssh_options[@]}" "$target" true
    cleanup; remote_dir=""
    printf '[INFO] Control-plane SSH access reconciled on %s\n' "$name"
done <<< "$targets"
