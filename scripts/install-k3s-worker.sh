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
CONTROL_PLANE_IP=""
K3S_VERSION=""
HARDENING_SSH_PORT=""
REGISTRY_HOST="${K3S_REGISTRY_HOST:-nexus-registry.infra.svc.cluster.local:5000}"
REGISTRY_ENDPOINT="${K3S_REGISTRY_ENDPOINT:-http://10.43.255.250:5000}"
NON_INTERACTIVE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3S_APPARMOR_INSTALLER="$SCRIPT_DIR/configure-k3s-apparmor.sh"
SECURITY_HARDENER="$SCRIPT_DIR/configure-node-security.sh"

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Install this machine as a K3s worker (agent).

Interactive usage:
  ./install-worker.sh --worker

Automation usage (the token is deliberately accepted only through stdin):
  printf '%s\n' "$K3S_JOIN_TOKEN" | ./install-worker.sh --worker \
    --non-interactive \
    --server-url https://10.0.0.10:6443 \
    --token-stdin \
    --node-name worker-01 \
    --node-network-cidr 10.0.0.0/24 \
    --control-plane-ip 10.0.0.10

Options:
  --server-url URL          K3s server URL; https:// and :6443 are added if omitted
  --token-stdin             Read the K3s join token as one line from standard input
  --node-name NAME          Unique Kubernetes node name (default: short hostname)
  --node-ip IP              Node address advertised to K3s
  --labels CSV              Initial Kubernetes node labels (key=value,key=value)
  --taints CSV              Initial Kubernetes node taints (key=value:effect,...)
  --node-network-cidr CIDR  Trusted private network shared by cluster nodes
  --control-plane-ip IP     Exact private control-plane source allowed to SSH here
  --k3s-version VERSION     Install the exact server version, for example v1.36.3+k3s1
  --worker-exposure local   Deprecated compatibility option; any other value is rejected
  --skip-security-hardening Deprecated no-op; the local-worker firewall is always enforced
  --ssh-port PORT           SSH port allowed only from the control plane (default: current session or 22)
  --non-interactive         Fail instead of prompting for missing required values
  -h, --help                Show this help

Run one of these commands on the control-plane node to obtain a join token:
  sudo cat /var/lib/rancher/k3s/server/node-token
  sudo k3s token create --ttl 1h --description worker-join

Workers are local-only. The installer rejects public IP interfaces and a
public K3s server URL, and configures UFW so SSH is accepted only from the exact
private control-plane address. Outbound traffic remains enabled for updates,
image pulls, and workloads.
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
        --control-plane-ip) shift; [[ $# -gt 0 ]] || error "Missing value for --control-plane-ip"; CONTROL_PLANE_IP="$1" ;;
        --control-plane-ip=*) CONTROL_PLANE_IP="${1#*=}" ;;
        --k3s-version)      shift; [[ $# -gt 0 ]] || error "Missing value for --k3s-version"; K3S_VERSION="$1" ;;
        --k3s-version=*)    K3S_VERSION="${1#*=}" ;;
        --worker-exposure)  shift; [[ $# -gt 0 ]] || error "Missing value for --worker-exposure"; [[ "${1,,}" =~ ^(local|local-only|private|internal|lan)$ ]] || error "Internet-facing workers are forbidden" ;;
        --worker-exposure=*) exposure_value="${1#*=}"; [[ "${exposure_value,,}" =~ ^(local|local-only|private|internal|lan)$ ]] || error "Internet-facing workers are forbidden" ;;
        --harden-security)  error "Internet-facing workers are forbidden; local-worker security is mandatory" ;;
        --skip-security-hardening) : ;;
        --ssh-port)         shift; [[ $# -gt 0 ]] || error "Missing value for --ssh-port"; HARDENING_SSH_PORT="$1" ;;
        --ssh-port=*)       HARDENING_SSH_PORT="${1#*=}" ;;
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

valid_ipv4() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

trusted_private_ipv4() {
    local ip="$1" a b _
    valid_ipv4 "$ip" || return 1
    IFS='.' read -r a b _ <<< "$ip"
    a=$((10#$a)); b=$((10#$b))
    (( a == 10 )) ||
        (( a == 172 && b >= 16 && b <= 31 )) ||
        (( a == 192 && b == 168 )) ||
        (( a == 100 && b >= 64 && b <= 127 ))
}

trusted_private_cidr() {
    local cidr="$1" ip prefix a b _
    [[ "$cidr" == */* ]] || return 1
    ip="${cidr%/*}"; prefix="${cidr#*/}"
    trusted_private_ipv4 "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    prefix=$((10#$prefix))
    (( prefix >= 1 && prefix <= 32 )) || return 1
    IFS='.' read -r a b _ <<< "$ip"
    a=$((10#$a)); b=$((10#$b))
    if (( a == 10 )); then (( prefix >= 8 ))
    elif (( a == 172 && b >= 16 && b <= 31 )); then (( prefix >= 12 ))
    elif (( a == 192 && b == 168 )); then (( prefix >= 16 ))
    else (( a == 100 && b >= 64 && b <= 127 && prefix >= 10 ))
    fi
}

ipv4_to_int() {
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    printf '%u' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

cidr_contains_ip() {
    local cidr="$1" ip="$2" network prefix mask ip_value network_value
    trusted_private_cidr "$cidr" && trusted_private_ipv4 "$ip" || return 1
    network="${cidr%/*}"; prefix=$((10#${cidr#*/}))
    ip_value="$(ipv4_to_int "$ip")"; network_value="$(ipv4_to_int "$network")"
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    (( (ip_value & mask) == (network_value & mask) ))
}

server_url_ipv4() {
    local value="${1%/}" authority host
    value="${value#https://}"
    authority="${value%%/*}"
    [[ -n "$authority" && "$authority" == "$value" ]] || return 1
    host="${authority%%:*}"
    trusted_private_ipv4 "$host" || return 1
    printf '%s' "$host"
}

detect_node_ip() {
    ip -4 route get "$1" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}'
}

detect_node_interface() {
    ip -4 route get "$1" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

reject_public_ip_interfaces() {
    local interface address
    while read -r interface address; do
        address="${address%/*}"
        trusted_private_ipv4 "$address" || \
            error "Interface $interface has public IPv4 address $address. This machine cannot be enrolled as a worker."
    done < <(ip -4 -o address show scope global | awk '{print $2, $4}')

    while read -r interface address; do
        address="${address%/*}"
        [[ "${address,,}" =~ ^f[cd] ]] || \
            error "Interface $interface has public IPv6 address $address. This machine cannot be enrolled as a worker."
    done < <(ip -6 -o address show scope global | awk '{print $2, $4}')
}

valid_node_name() {
    [[ ${#1} -le 253 && "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
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
    SERVER_URL="$(normalize_server_url "$SERVER_URL")" || error "Invalid control-plane URL: $SERVER_URL"
    SERVER_PRIVATE_IP="$(server_url_ipv4 "$SERVER_URL")" || \
        error "Use the control plane's RFC1918 or Tailscale IPv4 address, not a public address or hostname."
    [[ -n "$CONTROL_PLANE_IP" ]] || prompt CONTROL_PLANE_IP "Private control-plane IP allowed to SSH to this worker" "$SERVER_PRIVATE_IP"
    if [[ -z "$JOIN_TOKEN" ]]; then
        read -rsp "K3s join token (input hidden): " JOIN_TOKEN
        printf '\n'
    fi
    [[ -n "$NODE_NAME" ]] || prompt NODE_NAME "Unique node name" "$(hostname -s | tr '[:upper:]' '[:lower:]')"
    [[ -n "$NODE_IP" ]] || prompt NODE_IP "Node private IP" "$(detect_node_ip "$SERVER_PRIVATE_IP")"
    [[ -n "$NODE_LABELS" ]] || prompt NODE_LABELS "Initial labels, comma-separated (optional)"
    [[ -n "$NODE_TAINTS" ]] || prompt NODE_TAINTS "Initial taints, comma-separated (optional)"
    [[ -n "$NODE_NETWORK_CIDR" ]] || prompt NODE_NETWORK_CIDR "Trusted RFC1918/Tailscale node CIDR (e.g. 10.0.0.0/24)"
    [[ -n "$K3S_VERSION" ]] || prompt K3S_VERSION "Exact K3s version (blank to use the current stable release)"
    while [[ -z "$NODE_NETWORK_CIDR" ]]; do
        prompt NODE_NETWORK_CIDR "Trusted private node CIDR required for the worker firewall (e.g. 10.0.0.0/24)"
    done
fi

if [[ -z "$HARDENING_SSH_PORT" && -n "${SSH_CONNECTION:-}" ]]; then
    read -r _ _ _ HARDENING_SSH_PORT <<< "$SSH_CONNECTION"
fi
HARDENING_SSH_PORT="${HARDENING_SSH_PORT:-22}"

[[ -n "$SERVER_URL" ]] || error "A control-plane URL is required."
SERVER_URL="$(normalize_server_url "$SERVER_URL")" || error "Invalid control-plane URL: $SERVER_URL"
SERVER_PRIVATE_IP="$(server_url_ipv4 "$SERVER_URL")" || \
    error "The K3s URL must use the control plane's RFC1918 or Tailscale IPv4 address: $SERVER_URL"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-$SERVER_PRIVATE_IP}"
trusted_private_ipv4 "$CONTROL_PLANE_IP" || error "Control-plane SSH source must be RFC1918 or Tailscale: $CONTROL_PLANE_IP"
[[ -n "$JOIN_TOKEN" ]] || error "A K3s join token is required; use --token-stdin or run interactively."
NODE_NAME="${NODE_NAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
valid_node_name "$NODE_NAME" || error "Invalid node name '$NODE_NAME'. Use lower-case DNS characters and a unique name."
[[ -n "$NODE_NETWORK_CIDR" ]] || error "A trusted node network CIDR is required for the worker firewall."
trusted_private_cidr "$NODE_NETWORK_CIDR" || error "Node network must be an RFC1918 or Tailscale IPv4 CIDR: $NODE_NETWORK_CIDR"
NODE_IP="${NODE_IP:-$(detect_node_ip "$SERVER_PRIVATE_IP")}"
NODE_INTERFACE="$(detect_node_interface "$SERVER_PRIVATE_IP")"
trusted_private_ipv4 "$NODE_IP" || error "Worker node IP must be RFC1918 or Tailscale: ${NODE_IP:-unavailable}"
[[ -n "$NODE_INTERFACE" ]] || error "Could not determine the private interface used to reach $SERVER_PRIVATE_IP"
cidr_contains_ip "$NODE_NETWORK_CIDR" "$SERVER_PRIVATE_IP" || error "K3s server address $SERVER_PRIVATE_IP is outside $NODE_NETWORK_CIDR"
cidr_contains_ip "$NODE_NETWORK_CIDR" "$CONTROL_PLANE_IP" || error "Control-plane SSH source $CONTROL_PLANE_IP is outside $NODE_NETWORK_CIDR"
cidr_contains_ip "$NODE_NETWORK_CIDR" "$NODE_IP" || error "Worker node IP $NODE_IP is outside $NODE_NETWORK_CIDR"
reject_public_ip_interfaces
[[ -z "$K3S_VERSION" || "$K3S_VERSION" != *[[:space:]]* ]] || error "The K3s version cannot contain whitespace."
[[ "$HARDENING_SSH_PORT" =~ ^[0-9]+$ && "$HARDENING_SSH_PORT" -ge 1 && "$HARDENING_SSH_PORT" -le 65535 ]] || \
    error "SSH port must be an integer from 1 to 65535."
[[ -x "$SECURITY_HARDENER" ]] || error "Security policy script not found or not executable: $SECURITY_HARDENER"

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

info "Enforcing the local-only firewall before K3s enrollment..."
K3S_NODE_NETWORK_CIDR="$NODE_NETWORK_CIDR" \
CONTROL_PLANE_IP="$CONTROL_PLANE_IP" \
    "$SECURITY_HARDENER" --apply --server-exposure local --node-role worker \
    --control-plane-ip "$CONTROL_PLANE_IP" --ssh-port "$HARDENING_SSH_PORT"

info "Checking access to $SERVER_URL..."
curl -kfsS --connect-timeout 10 --max-time 20 "$SERVER_URL/cacerts" >/dev/null || \
    error "Cannot reach $SERVER_URL. Check routing and TCP port 6443 on the control-plane firewall."

agent_args=(agent --node-ip "$NODE_IP" --flannel-iface "$NODE_INTERFACE")
if [[ -n "$NODE_LABELS" ]]; then
    IFS=',' read -r -a label_values <<< "$NODE_LABELS"
    for value in "${label_values[@]}"; do
        value="$(trim "$value")"
        [[ -n "$value" ]] || error "Labels cannot contain an empty item."
        case "${value%%=*}" in
            svccontroller.k3s.cattle.io/enablelb|node-role.kubernetes.io/control-plane|node.swirlit.dev/role|node.swirlit.dev/exposure)
                error "Reserved topology label cannot be set on a worker: ${value%%=*}"
                ;;
        esac
        agent_args+=(--node-label "$value")
    done
fi
agent_args+=(
    --node-label node.swirlit.dev/role=worker
    --node-label node.swirlit.dev/exposure=local
)
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

info "Applying the mandatory local-only worker security policy..."
K3S_NODE_NETWORK_CIDR="$NODE_NETWORK_CIDR" \
CONTROL_PLANE_IP="$CONTROL_PLANE_IP" \
    "$SECURITY_HARDENER" --apply --server-exposure local --node-role worker \
    --control-plane-ip "$CONTROL_PLANE_IP" --ssh-port "$HARDENING_SSH_PORT"

info "Worker '$NODE_NAME' is running. On the control plane, verify it with:"
printf '  kubectl wait --for=condition=Ready node/%s --timeout=5m\n' "$NODE_NAME"
printf '  kubectl get nodes -o wide\n'
