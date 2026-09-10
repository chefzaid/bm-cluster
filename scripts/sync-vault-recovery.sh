#!/usr/bin/env bash
# Explicitly replicate host recovery material only to authenticated control planes.
set -euo pipefail
set +x
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${VAULT_STATE_DIR:-/var/lib/bm-cluster}"
error() { echo "[ERROR] $*" >&2; exit 1; }

check_secret_file() {
  local file="$1"
  sudo test ! -L "$file" && sudo test -s "$file" && \
    [[ "$(sudo stat -c '%u:%g:%a' "$file")" == 0:0:600 ]] || \
    error "Recovery files must be nonempty, root-owned regular files with mode 0600"
  sudo test -f "$file" || error "Recovery material must be a regular file"
}

receive_material() {
  local name="$1" address="$2" nodes key token temporary file
  (( EUID == 0 )) || error "Recovery receiver must run as root"
  [[ "$STATE_DIR" == /var/lib/bm-cluster ]] || error "Receiver uses the standard root-only recovery directory"
  [[ -d /var/lib/rancher/k3s/server && -r /etc/rancher/k3s/k3s.yaml ]] || error "Receiver is not a K3s server"
  nodes="$(KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get node "$name" -o json)"
  jq -e --arg ip "$address" '((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
    (.metadata.labels | has("node-role.kubernetes.io/master"))) and
    any(.status.addresses[]?; .type == "InternalIP" and .address == $ip)' <<< "$nodes" >/dev/null || \
    error "Receiver does not match the verified control-plane inventory"
  ip -j address show | jq -e --arg ip "$address" 'any(.[].addr_info[]?; .local == $ip)' >/dev/null || \
    error "Verified control-plane address does not belong to this host"
  [[ ! -L "$STATE_DIR" ]] || error "Recovery directory must not be a symlink"
  install -d -o root -g root -m 0700 "$STATE_DIR"
  exec 9> "$STATE_DIR/vault-recovery.lock"
  flock -x 9
  if ! IFS= read -r key || ! IFS= read -r token; then error "Incomplete recovery input"; fi
  [[ -n "$key" && -n "$token" ]] || error "Empty recovery input"
  temporary="$(mktemp -d "$STATE_DIR/.vault-recovery.XXXXXX")"
  trap 'rm -rf -- "${temporary:-}"' EXIT
  printf '%s' "$key" > "$temporary/vault-unseal-key"
  printf '%s' "$token" > "$temporary/vault-bootstrap-token"
  unset key token
  # Validate both before writing either; existing different material is never
  # replaced, since that could belong to another initialized Vault cluster.
  for file in vault-unseal-key vault-bootstrap-token; do
    if [[ -e "$STATE_DIR/$file" || -L "$STATE_DIR/$file" ]]; then
      check_secret_file "$STATE_DIR/$file"
      cmp -s "$temporary/$file" "$STATE_DIR/$file" || error "Existing recovery material differs; refusing to overwrite it"
    fi
  done
  for file in vault-unseal-key vault-bootstrap-token; do
    install -o root -g root -m 0600 "$temporary/$file" "$temporary/$file.ready"
    mv -f "$temporary/$file.ready" "$STATE_DIR/$file"
  done
  install -o root -g root -m 0750 "$SCRIPT_DIR/vault-unseal.sh" /usr/local/sbin/bm-vault-unseal
  install -o root -g root -m 0644 "$SCRIPT_DIR/bm-vault-unseal.service" /etc/systemd/system/bm-vault-unseal.service
  install -o root -g root -m 0644 "$SCRIPT_DIR/bm-vault-unseal.timer" /etc/systemd/system/bm-vault-unseal.timer
  systemctl daemon-reload
  systemctl enable --now bm-vault-unseal.timer >/dev/null
  rm -rf -- "$temporary"
  trap - EXIT
}

main() {
  # Receiver flags are only used by the authenticated SSH sender below.
  if [[ "${1:-}" == --receive-stdin ]]; then
    [[ $# == 3 ]] || error "Receiver needs node name and private address"
    receive_material "$2" "$3"
    return
  fi
  # shellcheck source=lib/network.sh
  source "$SCRIPT_DIR/lib/network.sh"
  # shellcheck source=lib/control-plane-access.sh
  source "$SCRIPT_DIR/lib/control-plane-access.sh"
  local cidr="${K3S_NODE_NETWORK_CIDR:-}" source_ip="${K3S_PRIVATE_ADDRESS:-}" all=false option
  local account="${K3S_NODE_SSH_USER:-${USER:-}}" port="${K3S_NODE_SSH_PORT:-22}" identity="${K3S_NODE_SSH_IDENTITY_FILE:-}"
  local nodes addresses name address recorded_user target_user connection actual_source actual_target actual_port command quoted
  while (( $# )); do
    case "$1" in
      --all-control-planes) all=true ;;
      --node-network-cidr|--control-plane-ip|--ssh-user|--ssh-port|--identity-file)
        option="$1"; shift; (( $# )) || error "Missing value for $option"
        case "$option" in
          --node-network-cidr) cidr="$1" ;; --control-plane-ip) source_ip="$1" ;;
          --ssh-user) account="$1" ;; --ssh-port) port="$1" ;; --identity-file) identity="$1" ;;
        esac ;;
      -h|--help)
        echo 'Usage: sync-vault-recovery.sh --all-control-planes --node-network-cidr CIDR --control-plane-ip LOCAL_IP [--ssh-user USER] [--ssh-port PORT] [--identity-file FILE]'
        echo 'Run on a registered control plane after configuring Vault. Copies root-only recovery files and installs the unseal timer on verified control planes; workers are excluded.'
        return ;;
      *) error "Unknown option: $1" ;;
    esac
    shift
  done
  [[ "$all" == true ]] || error "Explicit --all-control-planes selection is required"
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || error "Invalid SSH port"
  [[ -z "$identity" || -f "$identity" ]] || error "SSH identity file does not exist"
  nodes="$(kubectl get nodes -o json)"
  addresses="$(control_plane_private_ips "$nodes" "$cidr")" || error "Control-plane addresses must belong to the trusted private node network"
  control_plane_address_member "$addresses" "$source_ip" || error "Source must be a registered control plane"
  [[ -n "$(interface_owning_ip "$source_ip")" ]] || error "Source private address must belong to this host"
  for name in vault-unseal-key vault-bootstrap-token; do check_secret_file "$STATE_DIR/$name"; done
  local -a ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$port")
  local -a scp_options=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -P "$port")
  if [[ -n "$identity" ]]; then ssh_options+=(-i "$identity"); scp_options+=(-i "$identity"); fi
  # Global cleanup variables survive EXIT even when main has returned.
  remote_dir=""; target=""
  cleanup() {
    if [[ "$remote_dir" == /tmp/bm-vault-recovery.* && -n "$target" ]]; then
      ssh -n "${ssh_options[@]}" "$target" "rm -rf -- $(printf '%q' "$remote_dir")" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup EXIT
  while IFS=$'\t' read -r name address recorded_user; do
    [[ -n "$name" && "$address" != "$source_ip" ]] || continue
    control_plane_address_member "$addresses" "$address" || error "Target is not a verified control plane"
    target_user="$account"; [[ "$recorded_user" == - ]] || target_user="$recorded_user"
    [[ "$target_user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] || error "Invalid control-plane SSH account"
    target="$target_user@$address"
    connection="$(ssh -n "${ssh_options[@]}" "$target" 'sudo -n true && printf "%s" "$SSH_CONNECTION"')"
    read -r actual_source _ actual_target actual_port <<< "$connection"
    [[ "$actual_source" == "$source_ip" && "$actual_target" == "$address" && "$actual_port" == "$port" ]] || error "Private SSH source or destination verification failed"
    remote_dir="$(ssh -n "${ssh_options[@]}" "$target" 'mktemp -d /tmp/bm-vault-recovery.XXXXXX')"
    [[ "$remote_dir" =~ ^/tmp/bm-vault-recovery\.[A-Za-z0-9]+$ ]] || error "Invalid remote staging directory"
    # Only scripts and unit files use SCP. Recovery values are never staged in
    # the SSH account's home or temporary directory.
    scp "${scp_options[@]}" "$SCRIPT_DIR/sync-vault-recovery.sh" "$SCRIPT_DIR/vault-unseal.sh" \
      "$SCRIPT_DIR/../config/systemd/bm-vault-unseal.service" "$SCRIPT_DIR/../config/systemd/bm-vault-unseal.timer" \
      "$target:$remote_dir/"
    printf -v command 'sudo -n bash %q --receive-stdin' "$remote_dir/sync-vault-recovery.sh"
    for quoted in "$name" "$address"; do printf -v quoted ' %q' "$quoted"; command+="$quoted"; done
    { sudo jq -j -Rs 'sub("\n+$"; "")' "$STATE_DIR/vault-unseal-key"; printf '\n';
      sudo jq -j -Rs 'sub("\n+$"; "")' "$STATE_DIR/vault-bootstrap-token"; printf '\n'; } |
      ssh "${ssh_options[@]}" "$target" "$command"
    cleanup; remote_dir=""
    echo "[INFO] Vault recovery files and unseal timer installed on $name"
  done < <(jq -r '.items[] |
    select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
           (.metadata.labels | has("node-role.kubernetes.io/master"))) |
    [.metadata.name, ([.status.addresses[] | select(.type == "InternalIP") | .address][0]),
     (.metadata.annotations["node.bm-cluster.io/ssh-user"] // "-")] | @tsv' <<< "$nodes")
  trap - EXIT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
