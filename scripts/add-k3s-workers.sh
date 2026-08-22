#!/bin/bash
set -euo pipefail
# A caller may have exported shell tracing; never trace token handling.
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_LIBRARY="$SCRIPT_DIR/lib/network.sh"
if [[ ! -r "$NETWORK_LIBRARY" ]]; then
    echo "[ERROR] Shared network library not found: $NETWORK_LIBRARY" >&2
    exit 1
fi
# shellcheck source=lib/network.sh
source "$NETWORK_LIBRARY"

PLATFORM_CONFIG="$SCRIPT_DIR/../config/platform.env"
if [[ -r "$PLATFORM_CONFIG" ]]; then
    # shellcheck source=../config/platform.env
    source "$PLATFORM_CONFIG"
fi

WORKER_INSTALLER="$SCRIPT_DIR/install-k3s-worker.sh"
K3S_APPARMOR_INSTALLER="$SCRIPT_DIR/configure-k3s-apparmor.sh"
K3S_APPARMOR_PROFILE="$SCRIPT_DIR/../apparmor/cri-containerd.apparmor.d"
SECURITY_HARDENER="$SCRIPT_DIR/configure-node-security.sh"
K3S_NETWORK_CONFIGURATOR="$SCRIPT_DIR/configure-k3s-control-plane-network.sh"
TAILSCALE_CONFIGURATOR="$SCRIPT_DIR/configure-tailscale.sh"
OVH_VRACK_CONFIGURATOR="$SCRIPT_DIR/configure-ovh-vrack.sh"
WORKER_IPS="${K3S_WORKER_IPS:-}"
WORKER_HOSTS="${K3S_WORKER_HOSTS:-}"
NODE_TRANSPORT="${K3S_NODE_TRANSPORT:-}"
SERVER_URL=""
SSH_USER="${USER:-}"
SSH_PORT="22"
IDENTITY_FILE=""
NODE_NETWORK_CIDR=""
COMMON_LABELS=""
COMMON_TAINTS=""
K3S_VERSION=""
NON_INTERACTIVE=false
TAILSCALE_API_TOKEN_STDIN=false
TAILSCALE_API_TOKEN="${TAILSCALE_API_TOKEN:-}"
TAILSCALE_TAILNET="${TAILSCALE_TAILNET:-${DEFAULT_TAILSCALE_TAILNET:--}}"
TAILSCALE_MESH_NAME="${TAILSCALE_MESH_NAME:-${DEFAULT_TAILSCALE_MESH_NAME:-bm-cluster}}"
TAILSCALE_NODE_HOSTNAME="${TAILSCALE_NODE_HOSTNAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
TAILSCALE_AUTH_KEY_EXPIRY_SECONDS="${TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-${DEFAULT_TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-3600}}"
TAILSCALE_CONFIG_PREPARED="${TAILSCALE_CONFIG_PREPARED:-false}"
OVH_VRACK_AUTOMATE_ACCOUNT="${OVH_VRACK_AUTOMATE_ACCOUNT:-}"
OVH_VRACK_CONFIG_PREPARED="${OVH_VRACK_CONFIG_PREPARED:-false}"
OVH_API_ENDPOINT="${OVH_API_ENDPOINT:-ovh-eu}"
OVH_APPLICATION_KEY="${OVH_APPLICATION_KEY:-}"
OVH_APPLICATION_SECRET="${OVH_APPLICATION_SECRET:-}"
OVH_CONSUMER_KEY="${OVH_CONSUMER_KEY:-}"
OVH_VRACK_SERVICE_NAME="${OVH_VRACK_SERVICE_NAME:-}"
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

Non-interactive worker selection:
  ./install-worker.sh --control-plane \
    --transport vrack \
    --worker-ips 10.0.0.12,10.0.0.13 \
    --node-network-cidr 10.0.0.0/24 \
    --identity-file ~/.ssh/id_ed25519

Options:
  --transport MODE          OVHcloud-only vrack, or hybrid/non-OVH tailscale
  --worker-ips CSV          Preconfigured OVHcloud vRack worker addresses
  --worker-hosts CSV        Tailscale bootstrap SSH hosts/IPs (one or more)
  --server-url URL          K3s URL using this control plane's private IPv4
  --ssh-user USER           Default SSH user (each server can override it)
  --ssh-port PORT           Default SSH port (each server can override it)
  --identity-file PATH      Default private key (each server can override it)
  --node-network-cidr CIDR  RFC1918 network or Tailscale 100.64.0.0/10
  --labels CSV              Labels applied to every newly registered worker
  --taints CSV              Taints applied to every newly registered worker
  --k3s-version VERSION     Worker K3s version (default: exact server version)
  --tailscale-api-token-stdin
                            Read a personal tskey-api access token from stdin
  --tailscale-tailnet NAME  Tailnet name; "-" uses the token's tailnet
  --tailscale-mesh NAME     Unique mesh name used to isolate policy tags
  --tailscale-hostname NAME Tailscale hostname for this control plane
  --tailscale-key-expiry SEC
                            One-use node auth-key validity in seconds
  --worker-exposure local   Deprecated compatibility option; any other value is rejected
  --skip-worker-hardening   Deprecated no-op; the local-worker firewall is always enforced
  --non-interactive         Fail instead of prompting; implied by either worker list
  -h, --help                Show this help

SSH key authentication and either root access or passwordless sudo are required.
OVHcloud vRack mode can attach server interfaces through the OVHcloud API,
configure each private NIC over bootstrap SSH, prove private SSH, and only then
apply UFW. Tailscale mode asks for temporary
SSH bootstrap hosts, installs and tags Tailscale automatically, then switches
all enrollment traffic to tailscale0. Public bootstrap interfaces receive no
inbound UFW allowance after enrollment. SSH is allowed only from the exact
Tailscale control-plane address.
The join token is never placed in command-line arguments or copied to disk.

Token commands, if this script is not run on the control plane:
  sudo cat /var/lib/rancher/k3s/server/node-token
  sudo k3s token create --ttl 1h --description worker-join
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --transport)        shift; [[ $# -gt 0 ]] || error "Missing value for --transport"; NODE_TRANSPORT="$1" ;;
        --transport=*)      NODE_TRANSPORT="${1#*=}" ;;
        --worker-ips)       shift; [[ $# -gt 0 ]] || error "Missing worker IP list"; WORKER_IPS="$1"; NON_INTERACTIVE=true ;;
        --worker-ips=*)     WORKER_IPS="${1#*=}"; NON_INTERACTIVE=true ;;
        --worker-hosts)     shift; [[ $# -gt 0 ]] || error "Missing worker host list"; WORKER_HOSTS="$1"; NON_INTERACTIVE=true ;;
        --worker-hosts=*)   WORKER_HOSTS="${1#*=}"; NON_INTERACTIVE=true ;;
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
        --tailscale-api-token-stdin) TAILSCALE_API_TOKEN_STDIN=true ;;
        --tailscale-tailnet) shift; [[ $# -gt 0 ]] || error "Missing value for --tailscale-tailnet"; TAILSCALE_TAILNET="$1" ;;
        --tailscale-tailnet=*) TAILSCALE_TAILNET="${1#*=}" ;;
        --tailscale-mesh) shift; [[ $# -gt 0 ]] || error "Missing value for --tailscale-mesh"; TAILSCALE_MESH_NAME="$1" ;;
        --tailscale-mesh=*) TAILSCALE_MESH_NAME="${1#*=}" ;;
        --tailscale-hostname) shift; [[ $# -gt 0 ]] || error "Missing value for --tailscale-hostname"; TAILSCALE_NODE_HOSTNAME="$1" ;;
        --tailscale-hostname=*) TAILSCALE_NODE_HOSTNAME="${1#*=}" ;;
        --tailscale-key-expiry) shift; [[ $# -gt 0 ]] || error "Missing value for --tailscale-key-expiry"; TAILSCALE_AUTH_KEY_EXPIRY_SECONDS="$1" ;;
        --tailscale-key-expiry=*) TAILSCALE_AUTH_KEY_EXPIRY_SECONDS="${1#*=}" ;;
        --worker-exposure)  shift; [[ $# -gt 0 ]] || error "Missing value for --worker-exposure"; [[ "${1,,}" =~ ^(local|local-only|private|internal|lan)$ ]] || error "Internet-facing workers are forbidden" ;;
        --worker-exposure=*) exposure_value="${1#*=}"; [[ "${exposure_value,,}" =~ ^(local|local-only|private|internal|lan)$ ]] || error "Internet-facing workers are forbidden" ;;
        --harden-workers)   error "Internet-facing workers are forbidden; worker hardening is always local-only" ;;
        --skip-worker-hardening) : ;;
        --non-interactive)  NON_INTERACTIVE=true ;;
        -h|--help)          usage; exit 0 ;;
        *)                  error "Unknown option: $1 (use --help)" ;;
    esac
    shift
done

[[ -f "$WORKER_INSTALLER" ]] || error "Worker installer not found: $WORKER_INSTALLER"
[[ -f "$NETWORK_LIBRARY" ]] || error "Network library not found: $NETWORK_LIBRARY"
[[ -f "$K3S_APPARMOR_INSTALLER" ]] || error "AppArmor installer not found: $K3S_APPARMOR_INSTALLER"
[[ -f "$K3S_APPARMOR_PROFILE" ]] || error "AppArmor profile not found: $K3S_APPARMOR_PROFILE"
[[ -x "$TAILSCALE_CONFIGURATOR" ]] || error "Tailscale configurator not found or not executable: $TAILSCALE_CONFIGURATOR"
[[ -x "$OVH_VRACK_CONFIGURATOR" ]] || error "OVHcloud vRack configurator not found or not executable: $OVH_VRACK_CONFIGURATOR"
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

select_transport() {
    local answer=""
    if [[ -n "$NODE_TRANSPORT" ]]; then
        NODE_TRANSPORT="$(normalize_node_transport "$NODE_TRANSPORT")" || error "Transport must be vrack or tailscale."
        return
    fi
    [[ "$NON_INTERACTIVE" != "true" ]] || error "--transport is required in non-interactive mode."
    printf '%s\n' \
        "Select the private node transport:" \
        "  1) OVHcloud vRack (OVHcloud-only)" \
        "  2) Tailscale (hybrid cloud or non-OVHcloud providers)"
    while true; do
        read -rp "Select 1 or 2 [1]: " answer
        case "${answer:-1}" in
            1|vrack|vRack|lan) NODE_TRANSPORT=vrack; return ;;
            2|tailscale|ts) NODE_TRANSPORT=tailscale; return ;;
            *) warn "Enter 1 for vRack or 2 for Tailscale." ;;
        esac
    done
}

detect_private_ip() {
    local interface candidate
    while read -r interface candidate; do
        [[ "$interface" =~ ^(lo|docker|br-|cni|flannel|veth|tailscale) ]] && continue
        candidate="${candidate%/*}"
        if trusted_private_ipv4 "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done < <(ip -4 -o address show scope global | awk '{print $2, $4}')

    return 1
}

select_transport
if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
    if [[ "$NON_INTERACTIVE" != "true" && "$TAILSCALE_CONFIG_PREPARED" != "true" ]]; then
        prompt TAILSCALE_TAILNET "Tailnet name/login domain ('-' uses the token's tailnet)" "$TAILSCALE_TAILNET"
        prompt TAILSCALE_MESH_NAME "Unique Tailscale mesh/cluster name" "$TAILSCALE_MESH_NAME"
        prompt TAILSCALE_NODE_HOSTNAME "Tailscale hostname for this control plane" "$TAILSCALE_NODE_HOSTNAME"
        [[ "$TAILSCALE_AUTH_KEY_EXPIRY_SECONDS" =~ ^[0-9]+$ ]] || error "Auth-key expiry must be a number of seconds."
        tailscale_expiry_minutes="$((TAILSCALE_AUTH_KEY_EXPIRY_SECONDS / 60))"
        prompt tailscale_expiry_minutes "One-use node auth-key lifetime in minutes" "$tailscale_expiry_minutes"
        [[ "$tailscale_expiry_minutes" =~ ^[1-9][0-9]*$ ]] || error "Auth-key lifetime must be a positive whole number of minutes."
        TAILSCALE_AUTH_KEY_EXPIRY_SECONDS="$((tailscale_expiry_minutes * 60))"
    fi
    if [[ "$TAILSCALE_API_TOKEN_STDIN" == "true" ]]; then
        IFS= read -r TAILSCALE_API_TOKEN || error "Could not read the Tailscale API access token from stdin."
    elif [[ -z "$TAILSCALE_API_TOKEN" ]]; then
        [[ "$NON_INTERACTIVE" != "true" ]] || error "Set TAILSCALE_API_TOKEN or use --tailscale-api-token-stdin."
        read -rsp "Tailscale personal API access token (tskey-api-..., Admin Console -> Settings -> Keys): " TAILSCALE_API_TOKEN
        printf '\n'
    fi
    [[ "$TAILSCALE_API_TOKEN" =~ ^tskey-api-[A-Za-z0-9_-]+$ ]] || \
        error "Expected a Tailscale API access token beginning with tskey-api-."
    info "Reconciling the tailnet policy and control-plane role."
    default_ip="$(printf '%s\n' "$TAILSCALE_API_TOKEN" | \
        "$TAILSCALE_CONFIGURATOR" --role control-plane \
            --tailnet "$TAILSCALE_TAILNET" \
            --mesh-name "$TAILSCALE_MESH_NAME" \
            --hostname "$TAILSCALE_NODE_HOSTNAME" \
            --auth-key-expiry "$TAILSCALE_AUTH_KEY_EXPIRY_SECONDS" \
            --api-token-stdin)"
    NODE_NETWORK_CIDR="${NODE_NETWORK_CIDR:-100.64.0.0/10}"
else
    if [[ "$OVH_VRACK_CONFIG_PREPARED" != "true" ]]; then
        if [[ -z "$OVH_VRACK_AUTOMATE_ACCOUNT" ]]; then
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                if [[ -n "$OVH_APPLICATION_KEY$OVH_APPLICATION_SECRET$OVH_CONSUMER_KEY$OVH_VRACK_SERVICE_NAME" ]]; then
                    OVH_VRACK_AUTOMATE_ACCOUNT=true
                else
                    OVH_VRACK_AUTOMATE_ACCOUNT=false
                fi
            else
                read -rp "Use the OVHcloud API to attach worker interfaces to an existing vRack? [Y/n]: " ovh_answer
                [[ "${ovh_answer:-Y}" =~ ^[Yy]$ ]] && OVH_VRACK_AUTOMATE_ACCOUNT=true || OVH_VRACK_AUTOMATE_ACCOUNT=false
            fi
        fi
        if [[ "$OVH_VRACK_AUTOMATE_ACCOUNT" == "true" && "$NON_INTERACTIVE" != "true" ]]; then
            prompt OVH_API_ENDPOINT "OVHcloud API region endpoint (ovh-eu, ovh-ca, or ovh-us)" "$OVH_API_ENDPOINT"
            prompt OVH_VRACK_SERVICE_NAME "Existing OVHcloud vRack service name (pn-...)" "$OVH_VRACK_SERVICE_NAME"
            [[ -n "$OVH_APPLICATION_KEY" ]] || prompt OVH_APPLICATION_KEY "OVHcloud API application key"
            if [[ -z "$OVH_APPLICATION_SECRET" ]]; then
                read -rsp "OVHcloud API application secret (input hidden): " OVH_APPLICATION_SECRET
                printf '\n'
            fi
            if [[ -z "$OVH_CONSUMER_KEY" ]]; then
                read -rsp "OVHcloud API consumer key (input hidden): " OVH_CONSUMER_KEY
                printf '\n'
            fi
        fi
    fi
    OVH_VRACK_AUTOMATE_ACCOUNT="${OVH_VRACK_AUTOMATE_ACCOUNT:-false}"
    [[ "$OVH_VRACK_AUTOMATE_ACCOUNT" =~ ^(true|false)$ ]] || error "OVH_VRACK_AUTOMATE_ACCOUNT must be true or false."
    if [[ "$OVH_VRACK_AUTOMATE_ACCOUNT" == "true" ]]; then
        [[ -n "$OVH_APPLICATION_KEY" && -n "$OVH_APPLICATION_SECRET" && -n "$OVH_CONSUMER_KEY" && -n "$OVH_VRACK_SERVICE_NAME" ]] || \
            error "OVHcloud API credentials and OVH_VRACK_SERVICE_NAME are required for automated vRack attachment."
        info "OVHcloud vRack account attachment automation is enabled."
    else
        warn "OVHcloud API attachment is disabled; every server must already belong to the same vRack."
    fi
    default_ip="$(detect_private_ip || true)"
fi
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
cleanup_credentials() {
    JOIN_TOKEN=""
    TAILSCALE_API_TOKEN=""
    OVH_APPLICATION_KEY=""
    OVH_APPLICATION_SECRET=""
    OVH_CONSUMER_KEY=""
    unset JOIN_TOKEN K3S_JOIN_TOKEN TAILSCALE_API_TOKEN OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY 2>/dev/null || true
}
trap cleanup_credentials EXIT HUP INT TERM

if [[ "$NON_INTERACTIVE" != "true" ]]; then
    prompt SERVER_URL "K3s URL using this control plane's private IPv4 address" "$SERVER_URL"
    prompt SSH_USER "Default worker SSH user" "$SSH_USER"
    prompt SSH_PORT "Worker SSH port" "$SSH_PORT"
    prompt IDENTITY_FILE "SSH private key path (blank for agent/config)" "$IDENTITY_FILE"
    [[ -z "$IDENTITY_FILE" || -f "$IDENTITY_FILE" ]] || error "SSH identity file does not exist: $IDENTITY_FILE"
    if [[ "$NODE_TRANSPORT" == "vrack" ]]; then
        prompt NODE_NETWORK_CIDR "Trusted vRack/private node CIDR (e.g. 10.0.0.0/24)" "$NODE_NETWORK_CIDR"
    fi
    prompt COMMON_LABELS "Labels for every worker, comma-separated (optional)" "$COMMON_LABELS"
    prompt COMMON_TAINTS "Taints for every worker, comma-separated (optional)" "$COMMON_TAINTS"
    prompt K3S_VERSION "Exact worker K3s version" "$K3S_VERSION"
    while [[ -z "$NODE_NETWORK_CIDR" ]]; do
        prompt NODE_NETWORK_CIDR "Trusted private node CIDR required for worker UFW (e.g. 10.0.0.0/24)"
    done

    worker_count=""
    while [[ ! "$worker_count" =~ ^[1-9][0-9]*$ ]]; do
        prompt worker_count "Number of workers to add"
        [[ "$worker_count" =~ ^[1-9][0-9]*$ ]] || warn "Enter a positive whole number."
    done
else
    if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
        [[ -n "$WORKER_HOSTS" ]] || error "--worker-hosts is required for non-interactive Tailscale enrollment."
    else
        [[ -n "$WORKER_IPS" ]] || error "--worker-ips is required for non-interactive vRack enrollment."
    fi
fi
[[ -n "$SERVER_URL" ]] || error "Could not detect the control-plane address; provide --server-url."
[[ -n "$NODE_NETWORK_CIDR" ]] || error "--node-network-cidr is required for worker UFW."
trusted_private_cidr "$NODE_NETWORK_CIDR" || error "Node network must be RFC1918 or Tailscale 100.64.0.0/10: $NODE_NETWORK_CIDR"
SERVER_PRIVATE_IP="$(server_url_ipv4 "$SERVER_URL")" || \
    error "The worker K3s URL must use the control plane's RFC1918 or Tailscale IPv4 address: $SERVER_URL"
if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
    tailscale_ipv4 "$SERVER_PRIVATE_IP" || error "Tailscale transport requires a control-plane address in 100.64.0.0/10."
    [[ "$NODE_NETWORK_CIDR" == "100.64.0.0/10" ]] || error "Tailscale transport uses K3S_NODE_NETWORK_CIDR=100.64.0.0/10."
else
    ! tailscale_ipv4 "$SERVER_PRIVATE_IP" || error "vRack transport requires an RFC1918 control-plane address, not Tailscale."
fi
cidr_contains_ip "$NODE_NETWORK_CIDR" "$SERVER_PRIVATE_IP" || \
    error "Control-plane URL address $SERVER_PRIVATE_IP is outside $NODE_NETWORK_CIDR"
[[ -f "$SECURITY_HARDENER" ]] || error "Security policy script not found: $SECURITY_HARDENER"
[[ -x "$K3S_NETWORK_CONFIGURATOR" ]] || error "K3s network configurator not found or not executable: $K3S_NETWORK_CONFIGURATOR"
CONTROL_PLANE_CLUSTER_INTERFACE="$(interface_owning_ip "$SERVER_PRIVATE_IP")"
[[ -n "$CONTROL_PLANE_CLUSTER_INTERFACE" ]] || \
    error "Control-plane address $SERVER_PRIVATE_IP is not assigned to a local interface. Run this mode on the control-plane node."
[[ "$CONTROL_PLANE_CLUSTER_INTERFACE" == "tailscale0" ]] || [[ ! "$CONTROL_PLANE_CLUSTER_INTERFACE" =~ ^(lo|docker|br-|cni|flannel|veth) ]] || \
    error "Control-plane address $SERVER_PRIVATE_IP belongs to unsupported virtual interface $CONTROL_PLANE_CLUSTER_INTERFACE."
if [[ "$CONTROL_PLANE_CLUSTER_INTERFACE" == "tailscale0" ]]; then
    tailscale_ipv4 "$SERVER_PRIVATE_IP" || error "tailscale0 must use an address from 100.64.0.0/10"
    command -v tailscale >/dev/null 2>&1 || error "Tailscale address selected but Tailscale is not installed"
    "${LOCAL_SUDO[@]}" tailscale status >/dev/null 2>&1 || error "Tailscale address selected but this node is not connected"
    "${LOCAL_SUDO[@]}" tailscale set --ssh=false --netfilter-mode=nodivert >/dev/null || \
        error "Unable to make UFW authoritative for Tailscale traffic"
fi

info "Reconciling K3s private networking on $SERVER_PRIVATE_IP via $CONTROL_PLANE_CLUSTER_INTERFACE..."
"$K3S_NETWORK_CONFIGURATOR" \
    --private-ip "$SERVER_PRIVATE_IP" \
    --private-interface "$CONTROL_PLANE_CLUSTER_INTERFACE" \
    --restart

if command -v ufw >/dev/null 2>&1 && "${LOCAL_SUDO[@]}" ufw status | grep -q '^Status: active'; then
    [[ -n "$NODE_NETWORK_CIDR" ]] || error "UFW is active on the control plane. Provide --node-network-cidr to open only the trusted private network."
    info "Allowing K3s node traffic from $NODE_NETWORK_CIDR on the control plane..."
    "${LOCAL_SUDO[@]}" sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 6443 proto tcp >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 8472 proto udp >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 10250 proto tcp >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 2049 proto tcp comment 'Longhorn RWX' >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 3260 proto tcp comment 'Longhorn iSCSI' >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 8000 proto tcp comment 'Longhorn backing image' >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 8002 proto tcp comment 'Longhorn backing data' >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 8500:8504 proto tcp comment 'Longhorn instance manager' >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 9500:9503 proto tcp comment 'Longhorn manager' >/dev/null
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 10000:31000 proto tcp comment 'Longhorn engines and replicas' >/dev/null
    "${LOCAL_SUDO[@]}" ufw reload >/dev/null
fi

configure_ssh_options() {
    [[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]] || error "Invalid SSH port: $SSH_PORT"
    [[ -z "$IDENTITY_FILE" || -f "$IDENTITY_FILE" ]] || error "SSH identity file does not exist: $IDENTITY_FILE"
    ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$SSH_PORT")
    scp_options=(-q -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -P "$SSH_PORT")
    if [[ -n "$IDENTITY_FILE" ]]; then
        ssh_options+=(-i "$IDENTITY_FILE")
        scp_options+=(-i "$IDENTITY_FILE")
    fi
}
configure_ssh_options

build_target() {
    local host="$1"
    if [[ "$host" == *@* || -z "$SSH_USER" ]]; then
        printf '%s' "$host"
    else
        printf '%s@%s' "$SSH_USER" "$host"
    fi
}

check_bootstrap_target() {
    local target="$1"
    [[ "$target" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ || "$target" =~ ^[A-Za-z0-9._:-]+$ ]] || \
        error "Invalid SSH bootstrap target: $target"
    ssh "${ssh_options[@]}" "$target" \
        'test "$(id -u)" -eq 0 || (command -v sudo >/dev/null 2>&1 && sudo -n true)' >/dev/null || \
        error "Cannot use passwordless sudo on $target. Configure SSH keys and NOPASSWD sudo, or connect as root."
}

provision_vrack_target() {
    local bootstrap_target="$1" worker_ip="$2" private_interface="$3" interface_mac="$4" vlan_id="$5" ovh_server="$6"
    local remote_dir quoted_dir remote_script quoted_script configured_interface detected_mac="" private_target reachable=false
    local remote_command argument quoted_argument

    info "Checking public/bootstrap SSH before OVHcloud vRack configuration on $bootstrap_target..."
    check_bootstrap_target "$bootstrap_target"
    if [[ "$OVH_VRACK_AUTOMATE_ACCOUNT" == "true" ]]; then
        [[ -n "$ovh_server" ]] || error "The OVHcloud Dedicated Server service name is required for API attachment."
        detected_mac="$(OVH_API_ENDPOINT="$OVH_API_ENDPOINT" \
            OVH_APPLICATION_KEY="$OVH_APPLICATION_KEY" \
            OVH_APPLICATION_SECRET="$OVH_APPLICATION_SECRET" \
            OVH_CONSUMER_KEY="$OVH_CONSUMER_KEY" \
            "$OVH_VRACK_CONFIGURATOR" --attach-server "$ovh_server" \
                --vrack "$OVH_VRACK_SERVICE_NAME" --ovh-endpoint "$OVH_API_ENDPOINT" --non-interactive)"
        if [[ -z "$interface_mac" && "${detected_mac,,}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
            interface_mac="$detected_mac"
        fi
    fi

    remote_dir="$(ssh "${ssh_options[@]}" "$bootstrap_target" 'mktemp -d /tmp/bm-cluster-vrack.XXXXXX')"
    [[ "$remote_dir" == /tmp/bm-cluster-vrack.* ]] || error "Could not create a safe vRack configuration directory on $bootstrap_target."
    printf -v quoted_dir '%q' "$remote_dir"
    ssh "${ssh_options[@]}" "$bootstrap_target" "mkdir -m 700 $quoted_dir/lib"
    scp "${scp_options[@]}" "$OVH_VRACK_CONFIGURATOR" "$bootstrap_target:$remote_dir/"
    scp "${scp_options[@]}" "$NETWORK_LIBRARY" "$bootstrap_target:$remote_dir/lib/"
    remote_script="$remote_dir/configure-ovh-vrack.sh"
    printf -v quoted_script '%q' "$remote_script"
    remote_args=(
        --configure-node
        --private-ip "$worker_ip"
        --network-cidr "$NODE_NETWORK_CIDR"
        --non-interactive
    )
    [[ -z "$private_interface" ]] || remote_args+=(--interface "$private_interface")
    [[ -z "$interface_mac" ]] || remote_args+=(--interface-mac "$interface_mac")
    [[ -z "$vlan_id" ]] || remote_args+=(--vlan-id "$vlan_id")
    remote_command="chmod 700 $quoted_script && $quoted_script"
    for argument in "${remote_args[@]}"; do
        printf -v quoted_argument '%q' "$argument"
        remote_command+=" $quoted_argument"
    done
    info "Configuring $worker_ip on the OVHcloud private NIC before UFW changes..."
    if ! configured_interface="$(ssh "${ssh_options[@]}" "$bootstrap_target" "$remote_command")"; then
        ssh "${ssh_options[@]}" "$bootstrap_target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true
        error "vRack NIC configuration failed on $bootstrap_target; its public firewall was not changed."
    fi
    configured_interface="$(awk 'NF {value=$0} END {print value}' <<< "$configured_interface")"
    ssh "${ssh_options[@]}" "$bootstrap_target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true

    # Prove the original bootstrap path survived before attempting the private path.
    check_bootstrap_target "$bootstrap_target"
    cidr_contains_ip "$NODE_NETWORK_CIDR" "$worker_ip" || error "$worker_ip is outside $NODE_NETWORK_CIDR."
    private_target="$(build_target "$worker_ip")"
    for _ in {1..15}; do
        if ssh "${ssh_options[@]}" "$private_target" true >/dev/null 2>&1; then
            reachable=true
            break
        fi
        sleep 2
    done
    [[ "$reachable" == "true" ]] || \
        error "Private SSH did not become reachable at $private_target; bootstrap SSH remains available at $bootstrap_target and UFW was not changed."
    info "Private SSH is proven through $configured_interface; worker UFW may now close public ingress."
    VRACK_TARGET="$private_target"
    VRACK_WORKER_IP="$worker_ip"
    VRACK_NODE_INTERFACE="$configured_interface"
}

provision_tailscale_target() {
    local bootstrap_target="$1" requested_hostname="${2:-}" remote_dir remote_script quoted_dir quoted_script node_auth_key worker_ip detected_hostname
    local tagged_target="" reachable=false

    if [[ -z "$requested_hostname" ]]; then
        info "Checking bootstrap SSH access to $bootstrap_target..."
        check_bootstrap_target "$bootstrap_target"
        detected_hostname="$(remote_hostname "$bootstrap_target")"
        TAILSCALE_NODE_NAME="$detected_hostname"
    else
        TAILSCALE_NODE_NAME="$requested_hostname"
    fi
    [[ -n "$TAILSCALE_NODE_NAME" ]] || error "Could not determine the hostname of $bootstrap_target."
    [[ "$TAILSCALE_NODE_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
        error "Invalid Tailscale hostname '$TAILSCALE_NODE_NAME'; use lower-case letters, numbers, and hyphens."

    remote_dir="$(ssh "${ssh_options[@]}" "$bootstrap_target" 'mktemp -d /tmp/bm-cluster-tailscale.XXXXXX')"
    [[ "$remote_dir" == /tmp/bm-cluster-tailscale.* ]] || error "Could not create a safe Tailscale bootstrap directory on $bootstrap_target."
    printf -v quoted_dir '%q' "$remote_dir"
    ssh "${ssh_options[@]}" "$bootstrap_target" "chmod 700 $quoted_dir"
    scp "${scp_options[@]}" "$TAILSCALE_CONFIGURATOR" "$bootstrap_target:$remote_dir/"
    remote_script="$remote_dir/configure-tailscale.sh"
    printf -v quoted_script '%q' "$remote_script"

    info "Creating a one-use Tailscale worker key for $TAILSCALE_NODE_NAME."
    node_auth_key="$(printf '%s\n' "$TAILSCALE_API_TOKEN" | \
        "$TAILSCALE_CONFIGURATOR" --role worker \
            --tailnet "$TAILSCALE_TAILNET" --mesh-name "$TAILSCALE_MESH_NAME" \
            --auth-key-expiry "$TAILSCALE_AUTH_KEY_EXPIRY_SECONDS" \
            --create-auth-key --api-token-stdin)"
    [[ "$node_auth_key" =~ ^tskey-auth-[A-Za-z0-9_-]+$ ]] || error "Could not create a Tailscale worker auth key."
    info "Installing and connecting Tailscale on $bootstrap_target."
    if ! worker_ip="$(printf '%s\n' "$node_auth_key" | ssh "${ssh_options[@]}" "$bootstrap_target" \
        "chmod 700 $quoted_script && $quoted_script --role worker --tailnet $(printf '%q' "$TAILSCALE_TAILNET") --mesh-name $(printf '%q' "$TAILSCALE_MESH_NAME") --hostname $(printf '%q' "$TAILSCALE_NODE_NAME") --auth-key-stdin")"; then
        node_auth_key=""
        ssh "${ssh_options[@]}" "$bootstrap_target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true
        error "Tailscale provisioning failed on $bootstrap_target."
    fi
    node_auth_key=""
    worker_ip="$(awk 'NF {value=$0} END {print value}' <<< "$worker_ip")"
    tailscale_ipv4 "$worker_ip" || error "The worker did not return a valid Tailscale IPv4 address: ${worker_ip:-none}"
    printf '%s\n' "$TAILSCALE_API_TOKEN" | \
        "$TAILSCALE_CONFIGURATOR" --role worker \
            --tailnet "$TAILSCALE_TAILNET" --mesh-name "$TAILSCALE_MESH_NAME" \
            --tag-ip "$worker_ip" --api-token-stdin >/dev/null
    ssh "${ssh_options[@]}" "$bootstrap_target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true

    "${LOCAL_SUDO[@]}" tailscale ping --c=3 --timeout=5s "$worker_ip" >/dev/null || \
        error "The control plane cannot reach new Tailscale peer $worker_ip."
    tagged_target="$(build_target "$worker_ip")"
    for _ in {1..15}; do
        if ssh "${ssh_options[@]}" "$tagged_target" true >/dev/null 2>&1; then
            reachable=true
            break
        fi
        sleep 2
    done
    [[ "$reachable" == "true" ]] || error "SSH did not become reachable over Tailscale at $tagged_target."
    TAILSCALE_TARGET="$tagged_target"
    TAILSCALE_WORKER_IP="$worker_ip"
}

check_target() {
    local target="$1" expected_worker_ip="$2"
    local connection_info client_ip client_port worker_ip worker_port
    [[ "$target" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ || "$target" =~ ^[A-Za-z0-9._:-]+$ ]] || \
        error "Invalid SSH target: $target"
    ssh "${ssh_options[@]}" "$target" \
        'test "$(id -u)" -eq 0 || (command -v sudo >/dev/null 2>&1 && sudo -n true)' >/dev/null || \
        error "Cannot use passwordless sudo on $target. Configure SSH keys and NOPASSWD sudo, or connect as root."
    connection_info="$(ssh "${ssh_options[@]}" "$target" 'printf "%s" "$SSH_CONNECTION"')"
    read -r client_ip client_port worker_ip worker_port <<< "$connection_info"
    trusted_private_ipv4 "$client_ip" || \
        error "SSH to $target does not originate from an RFC1918/Tailscale control-plane address (observed: ${client_ip:-unknown})."
    trusted_private_ipv4 "$worker_ip" || \
        error "SSH to $target reached a non-private worker address (${worker_ip:-unknown})."
    [[ "$worker_ip" == "$expected_worker_ip" ]] || \
        error "SSH to $target reached $worker_ip instead of the entered worker local IP $expected_worker_ip."
    cidr_contains_ip "$NODE_NETWORK_CIDR" "$client_ip" || \
        error "Control-plane source $client_ip is outside trusted node CIDR $NODE_NETWORK_CIDR."
    cidr_contains_ip "$NODE_NETWORK_CIDR" "$worker_ip" || \
        error "Worker address $worker_ip is outside trusted node CIDR $NODE_NETWORK_CIDR."
    TARGET_CONTROL_PLANE_IP="$client_ip"
    TARGET_WORKER_IP="$worker_ip"
}

remote_hostname() {
    ssh "${ssh_options[@]}" "$1" "hostname -s | tr '[:upper:]' '[:lower:]'"
}

install_worker() {
    local target="$1" node_name="$2" node_ip="$3" labels="$4" taints="$5" control_plane_ip="$6"
    local remote_dir="" remote_installer="" remote_hardener=""
    local remote_command quoted quoted_dir quoted_installer quoted_hardener argument
    local worker_args=(
        --non-interactive
        --transport "$NODE_TRANSPORT"
        --server-url "$SERVER_URL"
        --token-stdin
        --node-name "$node_name"
        --ssh-port "$SSH_PORT"
        --control-plane-ip "$control_plane_ip"
    )

    [[ "$NODE_TRANSPORT" != "tailscale" ]] || worker_args+=(--tailscale-ready)

    [[ -z "$node_ip" ]] || worker_args+=(--node-ip "$node_ip")
    [[ -z "$labels" ]] || worker_args+=(--labels "$labels")
    [[ -z "$taints" ]] || worker_args+=(--taints "$taints")
    [[ -z "$NODE_NETWORK_CIDR" ]] || worker_args+=(--node-network-cidr "$NODE_NETWORK_CIDR")
    [[ -z "$K3S_VERSION" ]] || worker_args+=(--k3s-version "$K3S_VERSION")
    remote_dir="$(ssh "${ssh_options[@]}" "$target" 'mktemp -d /tmp/bm-cluster-worker.XXXXXX')"
    [[ "$remote_dir" == /tmp/bm-cluster-worker.* ]] || error "Could not create a safe temporary directory on $target."
    printf -v quoted_dir '%q' "$remote_dir"
    ssh "${ssh_options[@]}" "$target" "mkdir -m 700 $quoted_dir/scripts $quoted_dir/scripts/lib $quoted_dir/apparmor"
    info "Copying the worker installer and enforced AppArmor profile to $target..."
    scp "${scp_options[@]}" "$WORKER_INSTALLER" "$K3S_APPARMOR_INSTALLER" "$target:$remote_dir/scripts/"
    scp "${scp_options[@]}" "$TAILSCALE_CONFIGURATOR" "$OVH_VRACK_CONFIGURATOR" "$target:$remote_dir/scripts/"
    scp "${scp_options[@]}" "$NETWORK_LIBRARY" "$target:$remote_dir/scripts/lib/"
    scp "${scp_options[@]}" "$K3S_APPARMOR_PROFILE" "$target:$remote_dir/apparmor/"
    info "Copying the worker host-security policy to $target..."
    scp "${scp_options[@]}" "$SECURITY_HARDENER" "$target:$remote_dir/scripts/"
    remote_installer="$remote_dir/scripts/install-k3s-worker.sh"

    printf -v quoted_installer '%q' "$remote_installer"
    remote_command="chmod 700 $quoted_installer && $quoted_installer"
    remote_hardener="$remote_dir/scripts/configure-node-security.sh"
    printf -v quoted_hardener '%q' "$remote_hardener"
    remote_command="chmod 700 $quoted_installer $quoted_hardener $(printf '%q' "$remote_dir/scripts/configure-tailscale.sh") $(printf '%q' "$remote_dir/scripts/configure-ovh-vrack.sh") && $quoted_installer"
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

    info "Confirming a fresh private SSH connection after worker UFW was enabled..."
    check_target "$target" "$node_ip"

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
    kubectl label "node/$node_name" \
        node.swirlit.dev/role=worker \
        node.swirlit.dev/exposure=local \
        --overwrite >/dev/null
    kubectl label "node/$node_name" svccontroller.k3s.cattle.io/enablelb- >/dev/null 2>&1 || true
}

DEFAULT_WORKER_SSH_USER="$SSH_USER"
DEFAULT_WORKER_SSH_PORT="$SSH_PORT"
DEFAULT_WORKER_IDENTITY_FILE="$IDENTITY_FILE"

if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
        IFS=',' read -r -a hosts <<< "$WORKER_HOSTS"
    else
        IFS=',' read -r -a hosts <<< "$WORKER_IPS"
    fi
    [[ ${#hosts[@]} -gt 0 ]] || error "No worker hosts were provided."
    for host in "${hosts[@]}"; do
        host="${host#"${host%%[![:space:]]*}"}"
        host="${host%"${host##*[![:space:]]}"}"
        [[ -n "$host" ]] || error "Worker host list contains an empty item."
        if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
            bootstrap_target="$(build_target "$host")"
            provision_tailscale_target "$bootstrap_target"
            target="$TAILSCALE_TARGET"
            host="$TAILSCALE_WORKER_IP"
            node_name="$TAILSCALE_NODE_NAME"
        else
            trusted_private_ipv4 "$host" && ! tailscale_ipv4 "$host" || error "vRack worker IP must be an RFC1918 IPv4 literal: $host"
            cidr_contains_ip "$NODE_NETWORK_CIDR" "$host" || error "Worker IP $host is outside $NODE_NETWORK_CIDR"
            target="$(build_target "$host")"
            node_name=""
        fi
        info "Checking SSH access to $target..."
        check_target "$target" "$host"
        node_name="${node_name:-$(remote_hostname "$target")}"
        [[ -n "$node_name" ]] || error "Could not determine the hostname of $target."
        install_worker "$target" "$node_name" "$TARGET_WORKER_IP" "$COMMON_LABELS" "$COMMON_TAINTS" "$TARGET_CONTROL_PLANE_IP"
    done
else
    for ((index=1; index<=worker_count; index++)); do
        printf '\nWorker %d of %d\n' "$index" "$worker_count"
        worker_host=""
        if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
            worker_ssh_user="$DEFAULT_WORKER_SSH_USER"
            worker_ssh_port="$DEFAULT_WORKER_SSH_PORT"
            worker_identity_file="$DEFAULT_WORKER_IDENTITY_FILE"
            prompt worker_host "Existing server IP or DNS name reachable over SSH (bootstrap only)"
            [[ -n "$worker_host" ]] || error "A worker bootstrap SSH host is required."
            prompt worker_ssh_user "SSH user for this server" "$worker_ssh_user"
            prompt worker_ssh_port "SSH port for this server" "$worker_ssh_port"
            prompt worker_identity_file "SSH private key for this server ('-' for agent/config)" "$worker_identity_file"
            [[ "$worker_identity_file" != "-" ]] || worker_identity_file=""
            SSH_USER="$worker_ssh_user"
            SSH_PORT="$worker_ssh_port"
            IDENTITY_FILE="$worker_identity_file"
            configure_ssh_options
            bootstrap_target="$(build_target "$worker_host")"
            info "Checking bootstrap SSH access to $bootstrap_target..."
            check_bootstrap_target "$bootstrap_target"
            detected_tailscale_name="$(remote_hostname "$bootstrap_target")"
            requested_tailscale_name=""
            prompt requested_tailscale_name "Tailscale hostname for this server" "$detected_tailscale_name"
            provision_tailscale_target "$bootstrap_target" "$requested_tailscale_name"
            target="$TAILSCALE_TARGET"
            worker_host="$TAILSCALE_WORKER_IP"
            detected_name="$TAILSCALE_NODE_NAME"
        else
            worker_ssh_user="$DEFAULT_WORKER_SSH_USER"
            worker_ssh_port="$DEFAULT_WORKER_SSH_PORT"
            worker_identity_file="$DEFAULT_WORKER_IDENTITY_FILE"
            prompt bootstrap_host "Existing OVHcloud server IP or DNS name reachable over SSH (bootstrap only)"
            [[ -n "$bootstrap_host" ]] || error "A worker bootstrap SSH host is required."
            prompt worker_ssh_user "SSH user for this server" "$worker_ssh_user"
            prompt worker_ssh_port "SSH port for this server" "$worker_ssh_port"
            prompt worker_identity_file "SSH private key for this server ('-' for agent/config)" "$worker_identity_file"
            [[ "$worker_identity_file" != "-" ]] || worker_identity_file=""
            SSH_USER="$worker_ssh_user"
            SSH_PORT="$worker_ssh_port"
            IDENTITY_FILE="$worker_identity_file"
            configure_ssh_options
            bootstrap_target="$(build_target "$bootstrap_host")"
            check_bootstrap_target "$bootstrap_target"
            detected_name="$(remote_hostname "$bootstrap_target")"
            ovh_server=""
            if [[ "$OVH_VRACK_AUTOMATE_ACCOUNT" == "true" ]]; then
                prompt ovh_server "OVHcloud Dedicated Server service name for this worker"
            fi
            worker_host=""
            private_interface=""
            private_interface_mac=""
            vlan_id=""
            prompt worker_host "Unique worker vRack RFC1918 address"
            trusted_private_ipv4 "$worker_host" && ! tailscale_ipv4 "$worker_host" || error "vRack worker IP must be an RFC1918 IPv4 literal: $worker_host"
            cidr_contains_ip "$NODE_NETWORK_CIDR" "$worker_host" || error "Worker IP $worker_host is outside $NODE_NETWORK_CIDR"
            printf 'Interfaces reported by %s:\n' "$bootstrap_target"
            ssh "${ssh_options[@]}" "$bootstrap_target" 'ip -br link show'
            prompt private_interface "OVHcloud private NIC name (blank to match API-reported MAC)"
            prompt private_interface_mac "Expected OVHcloud private NIC MAC (recommended if API attachment is disabled)"
            [[ -n "$private_interface" || -n "$private_interface_mac" || "$OVH_VRACK_AUTOMATE_ACCOUNT" == "true" ]] || \
                error "Provide the OVHcloud private NIC name or MAC."
            prompt vlan_id "Optional vRack VLAN ID (blank for untagged VLAN 0)"
            provision_vrack_target "$bootstrap_target" "$worker_host" "$private_interface" "$private_interface_mac" "$vlan_id" "$ovh_server"
            target="$VRACK_TARGET"
        fi
        info "Checking SSH access to $target..."
        check_target "$target" "$worker_host"

        detected_name="${detected_name:-$(remote_hostname "$target")}"
        worker_name=""
        worker_labels=""
        worker_taints=""
        prompt worker_name "Unique Kubernetes node name" "$detected_name"
        prompt worker_labels "Node labels, comma-separated (optional)" "$COMMON_LABELS"
        prompt worker_taints "Node taints, comma-separated (optional)" "$COMMON_TAINTS"
        install_worker "$target" "$worker_name" "$worker_host" "$worker_labels" "$worker_taints" "$TARGET_CONTROL_PLANE_IP"
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
