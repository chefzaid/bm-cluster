#!/bin/bash
set -euo pipefail
# A caller may have exported shell tracing; never trace token handling.
set +x

SERVER_URL=""
JOIN_TOKEN=""
TOKEN_STDIN=false
NODE_NAME=""
NODE_IP=""
NODE_LABELS=""
NODE_TAINTS=""
NODE_NETWORK_CIDR=""
K3S_VERSION=""
REGISTRY_HOST="${K3S_REGISTRY_HOST:-nexus-registry.infra.svc.cluster.local:5000}"
REGISTRY_ENDPOINT="${K3S_REGISTRY_ENDPOINT:-http://10.43.255.250:5000}"
NON_INTERACTIVE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3S_APPARMOR_INSTALLER="$SCRIPT_DIR/configure-k3s-apparmor.sh"

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Install this machine as a K3s worker (agent).

Interactive usage:
  ./scripts/install-k3s-worker.sh

Automation usage (the token is deliberately accepted only through stdin):
  printf '%s\n' "$K3S_JOIN_TOKEN" | ./scripts/install-k3s-worker.sh \
    --non-interactive \
    --server-url https://10.0.0.10:6443 \
    --token-stdin \
    --node-name worker-01 \
    --node-network-cidr 10.0.0.0/24

Options:
  --server-url URL          K3s server URL; https:// and :6443 are added if omitted
  --token-stdin             Read the K3s join token as one line from standard input
  --node-name NAME          Unique Kubernetes node name (default: short hostname)
  --node-ip IP              Node address advertised to K3s
  --labels CSV              Initial Kubernetes node labels (key=value,key=value)
  --taints CSV              Initial Kubernetes node taints (key=value:effect,...)
  --node-network-cidr CIDR  Trusted private network shared by cluster nodes
  --k3s-version VERSION     Install the exact server version, for example v1.34.4+k3s1
  --non-interactive         Fail instead of prompting for missing required values
  -h, --help                Show this help

Run one of these commands on the control-plane node to obtain a join token:
  sudo cat /var/lib/rancher/k3s/server/node-token
  sudo k3s token create --ttl 1h --description worker-join
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-url)       shift; [[ $# -gt 0 ]] || error "Missing value for --server-url"; SERVER_URL="$1" ;;
        --server-url=*)     SERVER_URL="${1#*=}" ;;
        --token-stdin)      TOKEN_STDIN=true ;;
        --node-name)        shift; [[ $# -gt 0 ]] || error "Missing value for --node-name"; NODE_NAME="$1" ;;
        --node-name=*)      NODE_NAME="${1#*=}" ;;
        --node-ip)          shift; [[ $# -gt 0 ]] || error "Missing value for --node-ip"; NODE_IP="$1" ;;
        --node-ip=*)        NODE_IP="${1#*=}" ;;
        --labels)           shift; [[ $# -gt 0 ]] || error "Missing value for --labels"; NODE_LABELS="$1" ;;
        --labels=*)         NODE_LABELS="${1#*=}" ;;
        --taints)           shift; [[ $# -gt 0 ]] || error "Missing value for --taints"; NODE_TAINTS="$1" ;;
        --taints=*)         NODE_TAINTS="${1#*=}" ;;
        --node-network-cidr) shift; [[ $# -gt 0 ]] || error "Missing value for --node-network-cidr"; NODE_NETWORK_CIDR="$1" ;;
        --node-network-cidr=*) NODE_NETWORK_CIDR="${1#*=}" ;;
        --k3s-version)      shift; [[ $# -gt 0 ]] || error "Missing value for --k3s-version"; K3S_VERSION="$1" ;;
        --k3s-version=*)    K3S_VERSION="${1#*=}" ;;
        --non-interactive)  NON_INTERACTIVE=true ;;
        -h|--help)          usage; exit 0 ;;
        *)                  error "Unknown option: $1 (use --help)" ;;
    esac
    shift
done

prompt() {
    local variable_name="$1" prompt_text="$2" default_value="${3:-}" answer=""
    read -rp "$prompt_text${default_value:+ [$default_value]}: " answer
    printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

normalize_server_url() {
    local value="${1%/}" authority

    [[ "$value" =~ ^https:// ]] || value="https://$value"
    authority="${value#https://}"
    [[ -n "$authority" && "$authority" != */* && "$authority" != *[[:space:]]* ]] || return 1
    if [[ "$authority" != *:* || "$authority" =~ ^\[[^]]+\]$ ]]; then
        value="${value}:6443"
    fi
    printf '%s\n' "$value"
}

valid_node_name() {
    [[ ${#1} -le 253 && "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
}

valid_cidr() {
    [[ "$1" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]]
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

info "K3s worker enrollment"
printf '%s\n' \
    "On the control-plane node, obtain a token with one of:" \
    "  sudo cat /var/lib/rancher/k3s/server/node-token" \
    "  sudo k3s token create --ttl 1h --description worker-join"

if [[ "$TOKEN_STDIN" == "true" ]]; then
    IFS= read -r JOIN_TOKEN || error "Could not read the join token from stdin."
fi

if [[ "$NON_INTERACTIVE" != "true" ]]; then
    [[ -n "$SERVER_URL" ]] || prompt SERVER_URL "Control-plane IP, hostname, or URL"
    if [[ -z "$JOIN_TOKEN" ]]; then
        read -rsp "K3s join token (input hidden): " JOIN_TOKEN
        printf '\n'
    fi
    [[ -n "$NODE_NAME" ]] || prompt NODE_NAME "Unique node name" "$(hostname -s | tr '[:upper:]' '[:lower:]')"
    [[ -n "$NODE_IP" ]] || prompt NODE_IP "Node private IP (blank for automatic detection)"
    [[ -n "$NODE_LABELS" ]] || prompt NODE_LABELS "Initial labels, comma-separated (optional)"
    [[ -n "$NODE_TAINTS" ]] || prompt NODE_TAINTS "Initial taints, comma-separated (optional)"
    [[ -n "$NODE_NETWORK_CIDR" ]] || prompt NODE_NETWORK_CIDR "Trusted private node CIDR (required when UFW is active; e.g. 10.0.0.0/24)"
    [[ -n "$K3S_VERSION" ]] || prompt K3S_VERSION "Exact K3s version (blank to use the current stable release)"
fi

[[ -n "$SERVER_URL" ]] || error "A control-plane URL is required."
SERVER_URL="$(normalize_server_url "$SERVER_URL")" || error "Invalid control-plane URL: $SERVER_URL"
[[ -n "$JOIN_TOKEN" ]] || error "A K3s join token is required; use --token-stdin or run interactively."
NODE_NAME="${NODE_NAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
valid_node_name "$NODE_NAME" || error "Invalid node name '$NODE_NAME'. Use lower-case DNS characters and a unique name."
[[ -z "$NODE_NETWORK_CIDR" ]] || valid_cidr "$NODE_NETWORK_CIDR" || error "Invalid node network CIDR: $NODE_NETWORK_CIDR"
[[ -z "$K3S_VERSION" || "$K3S_VERSION" != *[[:space:]]* ]] || error "The K3s version cannot contain whitespace."

if [[ $EUID -eq 0 ]]; then
    SUDO=()
else
    command -v sudo >/dev/null 2>&1 || error "sudo is required when not running as root."
    SUDO=(sudo)
    "${SUDO[@]}" -v
fi

if "${SUDO[@]}" systemctl cat k3s.service >/dev/null 2>&1; then
    error "This machine has a K3s server service. Refusing to replace it with a worker."
fi

UFW_ACTIVE=false
if command -v ufw >/dev/null 2>&1 && "${SUDO[@]}" ufw status | grep -q '^Status: active'; then
    UFW_ACTIVE=true
    [[ -n "$NODE_NETWORK_CIDR" ]] || error "UFW is active. Provide --node-network-cidr so K3s traffic is allowed only from the trusted private network."
fi

command -v apt-get >/dev/null 2>&1 || error "This installer currently supports Debian/Ubuntu workers (apt-get is required)."
missing_packages=()
for package in ca-certificates curl open-iscsi nfs-common; do
    dpkg -s "$package" >/dev/null 2>&1 || missing_packages+=("$package")
done
if [[ ${#missing_packages[@]} -gt 0 ]]; then
    info "Installing worker prerequisites: ${missing_packages[*]}"
    "${SUDO[@]}" apt-get update -qq
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing_packages[@]}" >/dev/null
fi
"${SUDO[@]}" systemctl enable --now iscsid >/dev/null 2>&1

if [[ -x "$K3S_APPARMOR_INSTALLER" ]]; then
    info "Installing the enforced K3s AppArmor runtime profile..."
    "$K3S_APPARMOR_INSTALLER"
else
    warn "K3s AppArmor installer was not found next to this script; the runtime default will be used unchanged."
fi

if [[ "$UFW_ACTIVE" == "true" ]]; then
    info "Allowing K3s node traffic from $NODE_NETWORK_CIDR and the default pod/service networks."
    "${SUDO[@]}" sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    "${SUDO[@]}" ufw allow from "$NODE_NETWORK_CIDR" to any port 8472 proto udp >/dev/null
    "${SUDO[@]}" ufw allow from "$NODE_NETWORK_CIDR" to any port 10250 proto tcp >/dev/null
    "${SUDO[@]}" ufw allow from 10.42.0.0/16 to any >/dev/null
    "${SUDO[@]}" ufw allow from 10.43.0.0/16 to any >/dev/null
    "${SUDO[@]}" ufw reload >/dev/null
fi

info "Checking access to $SERVER_URL..."
curl -kfsS --connect-timeout 10 --max-time 20 "$SERVER_URL/cacerts" >/dev/null || \
    error "Cannot reach $SERVER_URL. Check routing and TCP port 6443 on the control-plane firewall."

agent_args=(agent)
[[ -z "$NODE_IP" ]] || agent_args+=(--node-ip "$NODE_IP")
if [[ -n "$NODE_LABELS" ]]; then
    IFS=',' read -r -a label_values <<< "$NODE_LABELS"
    for value in "${label_values[@]}"; do
        value="$(trim "$value")"
        [[ -n "$value" ]] || error "Labels cannot contain an empty item."
        agent_args+=(--node-label "$value")
    done
fi
if [[ -n "$NODE_TAINTS" ]]; then
    IFS=',' read -r -a taint_values <<< "$NODE_TAINTS"
    for value in "${taint_values[@]}"; do
        value="$(trim "$value")"
        [[ -n "$value" ]] || error "Taints cannot contain an empty item."
        agent_args+=(--node-taint "$value")
    done
fi

install_environment=(env "K3S_URL=$SERVER_URL" "K3S_TOKEN=$JOIN_TOKEN" "K3S_NODE_NAME=$NODE_NAME")
[[ -z "$K3S_VERSION" ]] || install_environment+=("INSTALL_K3S_VERSION=$K3S_VERSION")

info "Installing K3s agent '$NODE_NAME'..."
if ! "${SUDO[@]}" test -f /etc/rancher/k3s/registries.yaml; then
    printf 'mirrors:\n  "%s":\n    endpoint:\n      - "%s"\n' "$REGISTRY_HOST" "$REGISTRY_ENDPOINT" | \
        "${SUDO[@]}" install -D -o root -g root -m 0600 /dev/stdin /etc/rancher/k3s/registries.yaml
elif ! "${SUDO[@]}" grep -Fq "$REGISTRY_HOST" /etc/rancher/k3s/registries.yaml; then
    error "/etc/rancher/k3s/registries.yaml exists without the internal Nexus mirror; merge $REGISTRY_HOST before enrolling this worker."
fi
curl -sfL https://get.k3s.io | "${SUDO[@]}" "${install_environment[@]}" sh -s - "${agent_args[@]}"
JOIN_TOKEN=""
unset JOIN_TOKEN

"${SUDO[@]}" systemctl is-active --quiet k3s-agent || error "k3s-agent did not become active; inspect: sudo journalctl -u k3s-agent"
info "Worker '$NODE_NAME' is running. On the control plane, verify it with:"
printf '  kubectl wait --for=condition=Ready node/%s --timeout=5m\n' "$NODE_NAME"
printf '  kubectl get nodes -o wide\n'
