#!/bin/bash
set -euo pipefail
# A caller may have exported shell tracing; never trace token handling.
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_INSTALLER="$SCRIPT_DIR/install-k3s-worker.sh"
K3S_APPARMOR_INSTALLER="$SCRIPT_DIR/configure-k3s-apparmor.sh"
K3S_APPARMOR_PROFILE="$SCRIPT_DIR/../apparmor/cri-containerd.apparmor.d"
SECURITY_HARDENER="$SCRIPT_DIR/configure-node-security.sh"
WORKER_HOSTS=""
SERVER_URL=""
SSH_USER="${USER:-}"
SSH_PORT="22"
IDENTITY_FILE=""
NODE_NETWORK_CIDR=""
COMMON_LABELS=""
COMMON_TAINTS=""
K3S_VERSION=""
WORKER_EXPOSURE="${K3S_WORKER_EXPOSURE:-}"
NON_INTERACTIVE=false
JOIN_TOKEN=""
LOCAL_SUDO=()

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Add one or more Debian/Ubuntu machines to this K3s cluster as workers.

Interactive usage (run on the K3s control-plane node):
  ./install-worker.sh --control-plane

Non-interactive host selection:
  ./install-worker.sh --control-plane \
    --hosts ubuntu@10.0.0.12,ubuntu@10.0.0.13 \
    --node-network-cidr 10.0.0.0/24 \
    --worker-exposure local \
    --identity-file ~/.ssh/id_ed25519

Options:
  --hosts CSV               Worker SSH hosts; user@host overrides --ssh-user
  --server-url URL          K3s control-plane URL (default: this node's private IP)
  --ssh-user USER           Common SSH user (default: current user)
  --ssh-port PORT           Common SSH port (default: 22)
  --identity-file PATH      SSH private key (default: SSH agent/config)
  --node-network-cidr CIDR  Trusted private network shared by cluster nodes
  --labels CSV              Labels applied to every newly registered worker
  --taints CSV              Taints applied to every newly registered worker
  --k3s-version VERSION     Worker K3s version (default: exact server version)
  --worker-exposure MODE    Worker exposure: internet or local (default: local)
  --harden-workers          Compatibility alias for --worker-exposure internet
  --skip-worker-hardening   Compatibility alias for --worker-exposure local; UFW is still applied
  --non-interactive         Fail instead of prompting; implied by --hosts
  -h, --help                Show this help

SSH key authentication and either root access or passwordless sudo are required.
Internet-facing worker hardening requires a non-root SSH account with
passwordless sudo because that policy disables direct root login. Local workers
may be enrolled as root, but still receive the UFW baseline.
The join token is never placed in command-line arguments or copied to disk.

Token commands, if this script is not run on the control plane:
  sudo cat /var/lib/rancher/k3s/server/node-token
  sudo k3s token create --ttl 1h --description worker-join
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hosts)            shift; [[ $# -gt 0 ]] || error "Missing value for --hosts"; WORKER_HOSTS="$1"; NON_INTERACTIVE=true ;;
        --hosts=*)          WORKER_HOSTS="${1#*=}"; NON_INTERACTIVE=true ;;
        --server-url)       shift; [[ $# -gt 0 ]] || error "Missing value for --server-url"; SERVER_URL="$1" ;;
        --server-url=*)     SERVER_URL="${1#*=}" ;;
        --ssh-user)         shift; [[ $# -gt 0 ]] || error "Missing value for --ssh-user"; SSH_USER="$1" ;;
        --ssh-user=*)       SSH_USER="${1#*=}" ;;
        --ssh-port)         shift; [[ $# -gt 0 ]] || error "Missing value for --ssh-port"; SSH_PORT="$1" ;;
        --ssh-port=*)       SSH_PORT="${1#*=}" ;;
        --identity-file)    shift; [[ $# -gt 0 ]] || error "Missing value for --identity-file"; IDENTITY_FILE="$1" ;;
        --identity-file=*)  IDENTITY_FILE="${1#*=}" ;;
        --node-network-cidr) shift; [[ $# -gt 0 ]] || error "Missing value for --node-network-cidr"; NODE_NETWORK_CIDR="$1" ;;
        --node-network-cidr=*) NODE_NETWORK_CIDR="${1#*=}" ;;
        --labels)           shift; [[ $# -gt 0 ]] || error "Missing value for --labels"; COMMON_LABELS="$1" ;;
        --labels=*)         COMMON_LABELS="${1#*=}" ;;
        --taints)           shift; [[ $# -gt 0 ]] || error "Missing value for --taints"; COMMON_TAINTS="$1" ;;
        --taints=*)         COMMON_TAINTS="${1#*=}" ;;
        --k3s-version)      shift; [[ $# -gt 0 ]] || error "Missing value for --k3s-version"; K3S_VERSION="$1" ;;
        --k3s-version=*)    K3S_VERSION="${1#*=}" ;;
        --worker-exposure)  shift; [[ $# -gt 0 ]] || error "Missing value for --worker-exposure"; WORKER_EXPOSURE="$1" ;;
        --worker-exposure=*) WORKER_EXPOSURE="${1#*=}" ;;
        --harden-workers)   WORKER_EXPOSURE=internet ;;
        --skip-worker-hardening) WORKER_EXPOSURE=local ;;
        --non-interactive)  NON_INTERACTIVE=true ;;
        -h|--help)          usage; exit 0 ;;
        *)                  error "Unknown option: $1 (use --help)" ;;
    esac
    shift
done

[[ -f "$WORKER_INSTALLER" ]] || error "Worker installer not found: $WORKER_INSTALLER"
[[ -f "$K3S_APPARMOR_INSTALLER" ]] || error "AppArmor installer not found: $K3S_APPARMOR_INSTALLER"
[[ -f "$K3S_APPARMOR_PROFILE" ]] || error "AppArmor profile not found: $K3S_APPARMOR_PROFILE"
command -v ssh >/dev/null 2>&1 || error "ssh is required."
command -v scp >/dev/null 2>&1 || error "scp is required."
command -v kubectl >/dev/null 2>&1 || error "kubectl is required; run this script on a configured control-plane node."
kubectl cluster-info >/dev/null 2>&1 || error "Cannot reach the Kubernetes API with the current kubeconfig."
[[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]] || error "Invalid SSH port: $SSH_PORT"
[[ -z "$IDENTITY_FILE" || -f "$IDENTITY_FILE" ]] || error "SSH identity file does not exist: $IDENTITY_FILE"
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || error "sudo is required when not running as root."
    LOCAL_SUDO=(sudo)
fi

prompt() {
    local variable_name="$1" prompt_text="$2" default_value="${3:-}" answer=""
    read -rp "$prompt_text${default_value:+ [$default_value]}: " answer
    printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

detect_private_ip() {
    local detected=""
    detected="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
    [[ -n "$detected" ]] || detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s' "$detected"
}

normalize_worker_exposure() {
    case "${1,,}" in
        internet|internet-exposed|public|external) printf 'internet\n' ;;
        local|local-only|private|internal|lan) printf 'local\n' ;;
        *) return 1 ;;
    esac
}

default_ip="$(detect_private_ip)"
if [[ -z "$SERVER_URL" && -n "$default_ip" ]]; then
    SERVER_URL="https://${default_ip}:6443"
fi
if [[ -z "$K3S_VERSION" ]] && command -v k3s >/dev/null 2>&1; then
    K3S_VERSION="$(k3s --version 2>/dev/null | awk 'NR == 1 {print $3}')"
fi

printf '%s\n' \
    "K3s worker enrollment" \
    "Token commands on the control-plane node:" \
    "  sudo cat /var/lib/rancher/k3s/server/node-token" \
    "  sudo k3s token create --ttl 1h --description worker-join"

if [[ -r /var/lib/rancher/k3s/server/node-token ]]; then
    JOIN_TOKEN="$(< /var/lib/rancher/k3s/server/node-token)"
elif [[ ${#LOCAL_SUDO[@]} -gt 0 ]] && "${LOCAL_SUDO[@]}" test -r /var/lib/rancher/k3s/server/node-token; then
    JOIN_TOKEN="$("${LOCAL_SUDO[@]}" cat /var/lib/rancher/k3s/server/node-token)"
elif [[ -n "${K3S_JOIN_TOKEN:-}" ]]; then
    JOIN_TOKEN="$K3S_JOIN_TOKEN"
else
    [[ "$NON_INTERACTIVE" != "true" ]] || error "Cannot read the server node token. Set K3S_JOIN_TOKEN or run on the control plane."
    read -rsp "K3s join token (input hidden): " JOIN_TOKEN
    printf '\n'
fi
[[ -n "$JOIN_TOKEN" ]] || error "The K3s join token is empty."
trap 'JOIN_TOKEN=""; unset JOIN_TOKEN K3S_JOIN_TOKEN 2>/dev/null || true' EXIT

if [[ "$NON_INTERACTIVE" != "true" ]]; then
    prompt SERVER_URL "Control-plane URL" "$SERVER_URL"
    prompt SSH_USER "Default worker SSH user" "$SSH_USER"
    prompt SSH_PORT "Worker SSH port" "$SSH_PORT"
    prompt IDENTITY_FILE "SSH private key path (blank for agent/config)" "$IDENTITY_FILE"
    [[ -z "$IDENTITY_FILE" || -f "$IDENTITY_FILE" ]] || error "SSH identity file does not exist: $IDENTITY_FILE"
    prompt NODE_NETWORK_CIDR "Trusted private node CIDR required for worker UFW (e.g. 10.0.0.0/24)" "$NODE_NETWORK_CIDR"
    prompt COMMON_LABELS "Labels for every worker, comma-separated (optional)" "$COMMON_LABELS"
    prompt COMMON_TAINTS "Taints for every worker, comma-separated (optional)" "$COMMON_TAINTS"
    prompt K3S_VERSION "Exact worker K3s version" "$K3S_VERSION"
    [[ -n "$WORKER_EXPOSURE" ]] || prompt WORKER_EXPOSURE "Are these workers internet-exposed or local/private? [internet/local]" "local"
    while [[ -z "$NODE_NETWORK_CIDR" ]]; do
        prompt NODE_NETWORK_CIDR "Trusted private node CIDR required for worker UFW (e.g. 10.0.0.0/24)"
    done

    worker_count=""
    while [[ ! "$worker_count" =~ ^[1-9][0-9]*$ ]]; do
        prompt worker_count "Number of workers to add"
        [[ "$worker_count" =~ ^[1-9][0-9]*$ ]] || warn "Enter a positive whole number."
    done
else
    [[ -n "$WORKER_HOSTS" ]] || error "--hosts is required in non-interactive mode."
fi
WORKER_EXPOSURE="${WORKER_EXPOSURE:-local}"
WORKER_EXPOSURE="$(normalize_worker_exposure "$WORKER_EXPOSURE")" || error "Worker exposure must be 'internet' or 'local'."
[[ -n "$SERVER_URL" ]] || error "Could not detect the control-plane address; provide --server-url."
[[ -n "$NODE_NETWORK_CIDR" ]] || error "--node-network-cidr is required for worker UFW."
[[ "$NODE_NETWORK_CIDR" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] || error "Invalid node network CIDR: $NODE_NETWORK_CIDR"
[[ -f "$SECURITY_HARDENER" ]] || error "Security policy script not found: $SECURITY_HARDENER"

if command -v ufw >/dev/null 2>&1 && "${LOCAL_SUDO[@]}" ufw status | grep -q '^Status: active'; then
    [[ -n "$NODE_NETWORK_CIDR" ]] || error "UFW is active on the control plane. Provide --node-network-cidr to open only the trusted private network."
    info "Allowing K3s node traffic from $NODE_NETWORK_CIDR on the control plane..."
    "${LOCAL_SUDO[@]}" sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    "${LOCAL_SUDO[@]}" ufw allow from "$NODE_NETWORK_CIDR" to any port 6443 proto tcp >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow from "$NODE_NETWORK_CIDR" to any port 8472 proto udp >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow from "$NODE_NETWORK_CIDR" to any port 10250 proto tcp >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow from 10.42.0.0/16 to any >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow from 10.43.0.0/16 to any >/dev/null
    "${LOCAL_SUDO[@]}" ufw reload >/dev/null
fi

ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
scp_options=(-q -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -P "$SSH_PORT")
if [[ -n "$IDENTITY_FILE" ]]; then
    ssh_options+=(-i "$IDENTITY_FILE")
    scp_options+=(-i "$IDENTITY_FILE")
fi

build_target() {
    local host="$1"
    if [[ "$host" == *@* || -z "$SSH_USER" ]]; then
        printf '%s' "$host"
    else
        printf '%s@%s' "$SSH_USER" "$host"
    fi
}

check_target() {
    local target="$1"
    [[ "$target" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ || "$target" =~ ^[A-Za-z0-9._:-]+$ ]] || \
        error "Invalid SSH target: $target"
    ssh "${ssh_options[@]}" "$target" \
        'test "$(id -u)" -eq 0 || (command -v sudo >/dev/null 2>&1 && sudo -n true)' >/dev/null || \
        error "Cannot use passwordless sudo on $target. Configure SSH keys and NOPASSWD sudo, or connect as root."
    if [[ "$WORKER_EXPOSURE" == "internet" ]] && [[ "$(ssh "${ssh_options[@]}" "$target" 'id -u')" == "0" ]]; then
        error "Refusing to configure an internet-facing worker through root-only SSH because the policy disables root login. Use a non-root account with passwordless sudo."
    fi
}

remote_hostname() {
    ssh "${ssh_options[@]}" "$1" "hostname -s | tr '[:upper:]' '[:lower:]'"
}

install_worker() {
    local target="$1" node_name="$2" node_ip="$3" labels="$4" taints="$5"
    local remote_dir="" remote_installer="" remote_hardener=""
    local remote_command quoted quoted_dir quoted_installer quoted_hardener argument
    local worker_args=(
        --non-interactive
        --server-url "$SERVER_URL"
        --token-stdin
        --node-name "$node_name"
        --ssh-port "$SSH_PORT"
    )

    [[ -z "$node_ip" ]] || worker_args+=(--node-ip "$node_ip")
    [[ -z "$labels" ]] || worker_args+=(--labels "$labels")
    [[ -z "$taints" ]] || worker_args+=(--taints "$taints")
    [[ -z "$NODE_NETWORK_CIDR" ]] || worker_args+=(--node-network-cidr "$NODE_NETWORK_CIDR")
    [[ -z "$K3S_VERSION" ]] || worker_args+=(--k3s-version "$K3S_VERSION")
    worker_args+=(--worker-exposure "$WORKER_EXPOSURE")

    remote_dir="$(ssh "${ssh_options[@]}" "$target" 'mktemp -d /tmp/bm-cluster-worker.XXXXXX')"
    [[ "$remote_dir" == /tmp/bm-cluster-worker.* ]] || error "Could not create a safe temporary directory on $target."
    printf -v quoted_dir '%q' "$remote_dir"
    ssh "${ssh_options[@]}" "$target" "mkdir -m 700 $quoted_dir/scripts $quoted_dir/apparmor"
    info "Copying the worker installer and enforced AppArmor profile to $target..."
    scp "${scp_options[@]}" "$WORKER_INSTALLER" "$K3S_APPARMOR_INSTALLER" "$target:$remote_dir/scripts/"
    scp "${scp_options[@]}" "$K3S_APPARMOR_PROFILE" "$target:$remote_dir/apparmor/"
    info "Copying the worker host-security policy to $target..."
    scp "${scp_options[@]}" "$SECURITY_HARDENER" "$target:$remote_dir/scripts/"
    remote_installer="$remote_dir/scripts/install-k3s-worker.sh"

    printf -v quoted_installer '%q' "$remote_installer"
    remote_command="chmod 700 $quoted_installer && $quoted_installer"
    remote_hardener="$remote_dir/scripts/configure-node-security.sh"
    printf -v quoted_hardener '%q' "$remote_hardener"
    remote_command="chmod 700 $quoted_installer $quoted_hardener && $quoted_installer"
    for argument in "${worker_args[@]}"; do
        printf -v quoted '%q' "$argument"
        remote_command+=" $quoted"
    done

    info "Installing '$node_name' through $target..."
    if ! printf '%s\n' "$JOIN_TOKEN" | ssh "${ssh_options[@]}" "$target" "$remote_command"; then
        ssh "${ssh_options[@]}" "$target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true
        error "Worker installation failed on $target."
    fi
    ssh "${ssh_options[@]}" "$target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true

    info "Waiting for Kubernetes node '$node_name' to become Ready..."
    node_registered=false
    for _ in {1..30}; do
        if kubectl get "node/$node_name" >/dev/null 2>&1; then
            node_registered=true
            break
        fi
        sleep 2
    done
    [[ "$node_registered" == "true" ]] || error "Worker '$node_name' did not register within 60 seconds."
    kubectl wait --for=condition=Ready "node/$node_name" --timeout=5m
}

if [[ "$NON_INTERACTIVE" == "true" ]]; then
    IFS=',' read -r -a hosts <<< "$WORKER_HOSTS"
    [[ ${#hosts[@]} -gt 0 ]] || error "No worker hosts were provided."
    for host in "${hosts[@]}"; do
        host="${host#"${host%%[![:space:]]*}"}"
        host="${host%"${host##*[![:space:]]}"}"
        [[ -n "$host" ]] || error "--hosts contains an empty item."
        target="$(build_target "$host")"
        info "Checking SSH access to $target..."
        check_target "$target"
        node_name="$(remote_hostname "$target")"
        [[ -n "$node_name" ]] || error "Could not determine the hostname of $target."
        install_worker "$target" "$node_name" "" "$COMMON_LABELS" "$COMMON_TAINTS"
    done
else
    for ((index=1; index<=worker_count; index++)); do
        printf '\nWorker %d of %d\n' "$index" "$worker_count"
        worker_host=""
        prompt worker_host "SSH hostname or IP"
        [[ -n "$worker_host" ]] || error "A worker hostname or IP is required."
        target="$(build_target "$worker_host")"
        info "Checking SSH access to $target..."
        check_target "$target"

        detected_name="$(remote_hostname "$target")"
        worker_name=""
        worker_ip=""
        worker_labels=""
        worker_taints=""
        prompt worker_name "Unique Kubernetes node name" "$detected_name"
        prompt worker_ip "Advertised private node IP (blank for automatic detection)"
        prompt worker_labels "Node labels, comma-separated (optional)" "$COMMON_LABELS"
        prompt worker_taints "Node taints, comma-separated (optional)" "$COMMON_TAINTS"
        install_worker "$target" "$worker_name" "$worker_ip" "$worker_labels" "$worker_taints"
    done
fi

ready_nodes="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ {count++} END {print count+0}')"
replica_count="$ready_nodes"
(( replica_count > 3 )) && replica_count=3
(( replica_count < 1 )) && replica_count=1
if kubectl -n longhorn-system get settings.longhorn.io default-replica-count >/dev/null 2>&1; then
    kubectl -n longhorn-system patch settings.longhorn.io default-replica-count \
        --type=merge -p "{\"value\":\"$replica_count\"}" >/dev/null
    info "Longhorn's default for new volumes is now $replica_count replica(s)."
fi

info "Worker enrollment complete."
kubectl get nodes -o wide
