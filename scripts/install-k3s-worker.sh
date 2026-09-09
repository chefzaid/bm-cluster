#!/bin/bash
set -euo pipefail
# A caller may have exported shell tracing; never trace token handling.
set +x
umask 077

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
ENROLLMENT_ROLE="${K3S_ENROLLMENT_ROLE:-worker}"
CONTROL_PLANE_SCHEDULABLE="${CONTROL_PLANE_SCHEDULABLE:-}"
HARDENING_SSH_PORT=""
NODE_TRANSPORT="${K3S_NODE_TRANSPORT:-}"
TAILSCALE_READY=false
TAILSCALE_API_TOKEN_STDIN=false
TAILSCALE_API_TOKEN="${TAILSCALE_API_TOKEN:-}"
NON_INTERACTIVE=false
INSTALLER_TEMP_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_CONFIG="$SCRIPT_DIR/../config/platform.env"
if [[ -r "$PLATFORM_CONFIG" ]]; then
    # shellcheck source=../config/platform.env
    source "$PLATFORM_CONFIG"
fi
PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-${DEFAULT_PLATFORM_DOMAIN:-}}"
REGISTRY_HOST="${K3S_REGISTRY_HOST:-${DEFAULT_K3S_REGISTRY_HOST:-${PLATFORM_DOMAIN:+registry.$PLATFORM_DOMAIN}}}"
REGISTRY_ENDPOINT="${K3S_REGISTRY_ENDPOINT:-${DEFAULT_K3S_REGISTRY_ENDPOINT:-http://10.43.255.251:5050}}"
TAILSCALE_TAILNET="${TAILSCALE_TAILNET:-${DEFAULT_TAILSCALE_TAILNET:--}}"
TAILSCALE_MESH_NAME="${TAILSCALE_MESH_NAME:-${DEFAULT_TAILSCALE_MESH_NAME:-bm-cluster}}"
TAILSCALE_NODE_HOSTNAME="${TAILSCALE_NODE_HOSTNAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
TAILSCALE_AUTH_KEY_EXPIRY_SECONDS="${TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-${DEFAULT_TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-3600}}"
NETWORK_LIBRARY="$SCRIPT_DIR/lib/network.sh"
if [[ ! -r "$NETWORK_LIBRARY" ]]; then
    echo "[ERROR] Shared network library not found: $NETWORK_LIBRARY" >&2
    exit 1
fi
# shellcheck source=lib/network.sh
source "$NETWORK_LIBRARY"
PROMPT_LIBRARY="$SCRIPT_DIR/lib/installer-prompts.sh"
if [[ ! -r "$PROMPT_LIBRARY" ]]; then
    echo "[ERROR] Shared installer prompt library not found: $PROMPT_LIBRARY" >&2
    exit 1
fi
# shellcheck source=lib/installer-prompts.sh
source "$PROMPT_LIBRARY"
TRANSPORT_GUIDE_LIBRARY="$SCRIPT_DIR/lib/transport-guide.sh"
if [[ ! -r "$TRANSPORT_GUIDE_LIBRARY" ]]; then
    echo "[ERROR] Shared transport guide not found: $TRANSPORT_GUIDE_LIBRARY" >&2
    exit 1
fi
# shellcheck source=lib/transport-guide.sh
source "$TRANSPORT_GUIDE_LIBRARY"

K3S_APPARMOR_INSTALLER="$SCRIPT_DIR/configure-k3s-apparmor.sh"
LONGHORN_HOST_CONFIGURATOR="$SCRIPT_DIR/configure-longhorn-host.sh"
K3S_REGISTRY_MIRROR_SCRIPT="$SCRIPT_DIR/configure-k3s-registry-mirror.sh"
K3S_NETWORK_CONFIGURATOR="$SCRIPT_DIR/configure-k3s-control-plane-network.sh"
SECURITY_HARDENER="$SCRIPT_DIR/configure-node-security.sh"
TAILSCALE_CONFIGURATOR="$SCRIPT_DIR/configure-tailscale.sh"
OVH_VRACK_CONFIGURATOR="$SCRIPT_DIR/configure-ovh-vrack.sh"
VRACK_INTERFACE="${K3S_PRIVATE_INTERFACE:-}"
VRACK_INTERFACE_MAC="${K3S_PRIVATE_INTERFACE_MAC:-}"
VRACK_VLAN_ID="${K3S_VRACK_VLAN_ID:-}"
# Used by the sourced transport guide, which intentionally mutates caller state.
# shellcheck disable=SC2034
OVH_VRACK_AUTOMATE_ACCOUNT=false
OVH_API_ENDPOINT="${OVH_API_ENDPOINT:-ovh-eu}"
OVH_APPLICATION_KEY="${OVH_APPLICATION_KEY:-}"
OVH_APPLICATION_SECRET="${OVH_APPLICATION_SECRET:-}"
OVH_CONSUMER_KEY="${OVH_CONSUMER_KEY:-}"
OVH_VRACK_SERVICE_NAME="${OVH_VRACK_SERVICE_NAME:-}"

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup_private_credentials() {
    JOIN_TOKEN=""
    TAILSCALE_API_TOKEN=""
    unset JOIN_TOKEN K3S_JOIN_TOKEN K3S_TOKEN TAILSCALE_API_TOKEN 2>/dev/null || true
    if [[ -n "$INSTALLER_TEMP_DIR" && "$INSTALLER_TEMP_DIR" == /tmp/bm-cluster-worker-installers.* && -d "$INSTALLER_TEMP_DIR" ]]; then
        rm -r -- "$INSTALLER_TEMP_DIR"
    fi
}
trap cleanup_private_credentials EXIT HUP INT TERM

usage() {
    if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
        cat <<'EOF'
Join this host to an existing embedded-etcd K3s cluster as a control plane.

Prefer ./add-node.sh --role control-plane --mode remote on the bootstrap control plane.
For direct use, provide the server token through stdin and the exact cluster
version, and run through private SSH from the bootstrap control plane:
  ./add-node.sh --role control-plane --mode local --token-stdin --non-interactive \
    --server-url https://10.0.0.10:6443 --node-ip 10.0.0.11 \
    --node-name cp-02 --domain example.com --transport vrack \
    --node-network-cidr 10.0.0.0/24 --k3s-version vX.Y.Z+k3s1 \
    --control-plane-schedulable false

Required server token: sudo cat /var/lib/rancher/k3s/server/token
  --control-plane-schedulable true|false  Whether this control plane accepts workloads

  --server-url URL           Private IPv4 API endpoint of the bootstrap server
  --token-stdin              Read the existing server token from stdin
  --node-name NAME           Unique Kubernetes node name
  --node-ip IP               This server's private IPv4
  --domain DOMAIN            Cluster domain for the container Registry
  --k3s-version VERSION      Exact K3s server version (required)
  --node-network-cidr CIDR   RFC1918 subnet or Tailscale 100.64.0.0/10
  --control-plane-ip IP      Bootstrap private SSH source (default: server URL IP)
  --transport MODE           vrack or tailscale
  --vrack-interface NAME     Physical private NIC if not configured
  --vrack-interface-mac MAC  Expected private NIC MAC
  --vrack-vlan-id ID         Optional vRack VLAN ID
  --tailscale-ready          Tailscale was already provisioned by the bootstrap
  --tailscale-api-token-stdin
                             Read Tailscale API credentials from stdin before joining
  --tailscale-tailnet NAME   Tailnet name
  --tailscale-mesh NAME      Cluster mesh name
  --tailscale-hostname NAME  This server's Tailscale hostname
  --tailscale-key-expiry N   One-use Tailscale auth-key validity in seconds
  --labels CSV               Additional node labels
  --taints CSV               Additional taints (use scheduling mode for NoSchedule)
  --ssh-port PORT            Private SSH port
  --non-interactive          Fail instead of prompting
  -h, --help                 Show this help

This installs a private server with embedded etcd, Traefik disabled, and secrets
encryption enabled. It does not initialize a new cluster or install platform
services. Existing K3s services require the enrollment manager's identity checks.
Interactive use asks for the exact cluster version and whether this server may
run workloads. Local joins do not convert the bootstrap datastore or validate
the final cluster count; use remote enrollment for those steps.
EOF
        return
    fi
    cat <<'EOF'
Install this machine as a K3s worker (agent).

Interactive usage:
  ./add-node.sh --role worker --mode local

Automation usage (the token is deliberately accepted only through stdin):
  printf '%s\n' "$K3S_JOIN_TOKEN" | ./add-node.sh --role worker --mode local \
    --non-interactive \
    --transport vrack \
    --server-url https://10.0.0.10:6443 \
    --token-stdin \
    --node-name worker-01 \
    --node-network-cidr 10.0.0.0/24 \
    --control-plane-ip 10.0.0.10

Options:
  --server-url URL          K3s server URL; https:// and :6443 are added if omitted
  --token-stdin             Read the K3s join token as one line from standard input
  --node-name NAME          Unique Kubernetes node name (default: short hostname)
  --domain DOMAIN           Public cluster domain used to derive the Registry host
  --node-ip IP              This worker's RFC1918 or Tailscale IPv4 address
  --labels CSV              Initial Kubernetes node labels (key=value,key=value)
  --taints CSV              Initial Kubernetes node taints (key=value:effect,...)
  --node-network-cidr CIDR  RFC1918 network or Tailscale 100.64.0.0/10
  --control-plane-ip IP     Exact private control-plane source allowed to SSH here
  --k3s-version VERSION     Install the control plane's exact K3s version
  --transport MODE          OVHcloud-only vrack, or hybrid/non-OVH tailscale
  --vrack-interface NAME    OVHcloud physical private NIC (if not configured)
  --vrack-interface-mac MAC Expected OVHcloud private NIC MAC
  --vrack-vlan-id ID        Optional vRack VLAN ID (1-4094)
  --tailscale-api-token-stdin
                            Read a tskey-api access token from stdin and automate Tailscale
  --tailscale-tailnet NAME  Tailnet name; "-" uses the token's tailnet
  --tailscale-mesh NAME     Unique mesh name used to isolate policy tags
  --tailscale-hostname NAME Tailscale hostname for this worker
  --tailscale-key-expiry SEC
                            One-use node auth-key validity in seconds
  --tailscale-ready         Tailscale was already provisioned by the control plane
  --worker-exposure local   Deprecated compatibility option; any other value is rejected
  --skip-security-hardening Deprecated no-op; the local-worker firewall is always enforced
  --ssh-port PORT           SSH port allowed only from the control plane (default: current session or 22)
  --non-interactive         Fail instead of prompting for missing required values
  -h, --help                Show this help

Run one of these commands on the control-plane node to obtain a join token:
  sudo cat /var/lib/rancher/k3s/server/node-token
  sudo k3s token create --ttl 1h --description worker-join

Workers never accept public ingress. Both transports may retain a provider
interface for bootstrap and outbound updates, but UFW adds no inbound rule to
it. Final hardening is refused unless this installer is running through private
SSH from the exact control-plane address to the worker's vRack/Tailscale IP.
Prefer running add-node.sh --role worker --mode remote so that path is proven first.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-url)       shift; [[ $# -gt 0 ]] || error "Missing value for --server-url"; SERVER_URL="$1" ;;
        --server-url=*)     SERVER_URL="${1#*=}" ;;
        --token-stdin)      TOKEN_STDIN=true ;;
        --node-name)        shift; [[ $# -gt 0 ]] || error "Missing value for --node-name"; NODE_NAME="$1" ;;
        --node-name=*)      NODE_NAME="${1#*=}" ;;
        --domain)           shift; [[ $# -gt 0 ]] || error "Missing value for --domain"; PLATFORM_DOMAIN="$1" ;;
        --domain=*)         PLATFORM_DOMAIN="${1#*=}" ;;
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
        --node-role)        shift; [[ $# -gt 0 ]] || error "Missing node role"; ENROLLMENT_ROLE="$1" ;;
        --node-role=*)      ENROLLMENT_ROLE="${1#*=}" ;;
        --control-plane-schedulable) shift; [[ $# -gt 0 ]] || error "Missing scheduling mode"; CONTROL_PLANE_SCHEDULABLE="$1" ;;
        --control-plane-schedulable=*) CONTROL_PLANE_SCHEDULABLE="${1#*=}" ;;
        --transport)        shift; [[ $# -gt 0 ]] || error "Missing value for --transport"; NODE_TRANSPORT="$1" ;;
        --transport=*)      NODE_TRANSPORT="${1#*=}" ;;
        --vrack-interface) shift; [[ $# -gt 0 ]] || error "Missing value for --vrack-interface"; VRACK_INTERFACE="$1" ;;
        --vrack-interface=*) VRACK_INTERFACE="${1#*=}" ;;
        --vrack-interface-mac) shift; [[ $# -gt 0 ]] || error "Missing value for --vrack-interface-mac"; VRACK_INTERFACE_MAC="$1" ;;
        --vrack-interface-mac=*) VRACK_INTERFACE_MAC="${1#*=}" ;;
        --vrack-vlan-id) shift; [[ $# -gt 0 ]] || error "Missing value for --vrack-vlan-id"; VRACK_VLAN_ID="$1" ;;
        --vrack-vlan-id=*) VRACK_VLAN_ID="${1#*=}" ;;
        --tailscale-api-token-stdin) TAILSCALE_API_TOKEN_STDIN=true ;;
        --tailscale-tailnet) shift; [[ $# -gt 0 ]] || error "Missing value for --tailscale-tailnet"; TAILSCALE_TAILNET="$1" ;;
        --tailscale-tailnet=*) TAILSCALE_TAILNET="${1#*=}" ;;
        --tailscale-mesh) shift; [[ $# -gt 0 ]] || error "Missing value for --tailscale-mesh"; TAILSCALE_MESH_NAME="$1" ;;
        --tailscale-mesh=*) TAILSCALE_MESH_NAME="${1#*=}" ;;
        --tailscale-hostname) shift; [[ $# -gt 0 ]] || error "Missing value for --tailscale-hostname"; TAILSCALE_NODE_HOSTNAME="$1" ;;
        --tailscale-hostname=*) TAILSCALE_NODE_HOSTNAME="${1#*=}" ;;
        --tailscale-key-expiry) shift; [[ $# -gt 0 ]] || error "Missing value for --tailscale-key-expiry"; TAILSCALE_AUTH_KEY_EXPIRY_SECONDS="$1" ;;
        --tailscale-key-expiry=*) TAILSCALE_AUTH_KEY_EXPIRY_SECONDS="${1#*=}" ;;
        --tailscale-ready)  TAILSCALE_READY=true ;;
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

[[ "$ENROLLMENT_ROLE" =~ ^(worker|control-plane)$ ]] || error "Invalid enrollment role: $ENROLLMENT_ROLE"
# Reject role collisions before transport/account setup or any host changes.
if systemctl cat k3s.service >/dev/null 2>&1; then
    error "This machine already has a K3s server service. Use the control-plane enrollment manager to validate and reuse an existing server."
fi
if [[ "$ENROLLMENT_ROLE" == "control-plane" ]] && systemctl cat k3s-agent.service >/dev/null 2>&1; then
    error "This machine already has a K3s worker service; refusing to change its role."
fi
if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
    if [[ "$NON_INTERACTIVE" != true ]]; then
        installer_prompt_section "Control-plane join settings" \
            "The existing cluster must already use embedded etcd; match its version and scheduling policy." \
            "Use remote enrollment to prepare the datastore and complete an odd final server count."
        [[ -n "$K3S_VERSION" ]] || installer_prompt_value K3S_VERSION \
            "Exact K3s version on the existing control plane (sudo k3s --version)"
        [[ -n "$CONTROL_PLANE_SCHEDULABLE" ]] || installer_prompt_value CONTROL_PLANE_SCHEDULABLE \
            "May this control plane run workloads? Enter true or false to match the cluster"
    fi
    [[ "$CONTROL_PLANE_SCHEDULABLE" =~ ^(true|false)$ ]] || \
        error "Server joins require --control-plane-schedulable true|false."
    [[ -n "$K3S_VERSION" ]] || error "Server joins require the bootstrap server's exact --k3s-version."
fi
if [[ -z "$REGISTRY_HOST" && -n "$PLATFORM_DOMAIN" ]]; then
    REGISTRY_HOST="registry.${PLATFORM_DOMAIN,,}"
fi
if [[ -z "$REGISTRY_HOST" ]]; then
    [[ "$NON_INTERACTIVE" != "true" ]] || error "Set --domain or K3S_REGISTRY_HOST."
    installer_prompt_section "Cluster identity" \
        "The public domain determines this node's GitLab Registry host."
    installer_prompt_value PLATFORM_DOMAIN "Public base domain for this cluster"
    PLATFORM_DOMAIN="${PLATFORM_DOMAIN,,}"
    [[ "$PLATFORM_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || error "Invalid public domain."
    REGISTRY_HOST="registry.$PLATFORM_DOMAIN"
fi
export PLATFORM_DOMAIN K3S_REGISTRY_HOST="$REGISTRY_HOST"

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

detect_node_ip() {
    ip -4 route get "$1" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}'
}

detect_node_interface() {
    ip -4 route get "$1" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}'
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

select_transport() {
    installer_select_node_transport NODE_TRANSPORT "$NODE_TRANSPORT" vrack "$NON_INTERACTIVE" || \
        error "Set --transport to vrack or tailscale."
}

if [[ "$NON_INTERACTIVE" != "true" ]]; then
    installer_prompt_section "Private $ENROLLMENT_ROLE transport" \
        "Use the same transport as every existing cluster node."
fi
select_transport
if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
    [[ -x "$TAILSCALE_CONFIGURATOR" ]] || error "Tailscale configurator not found or not executable: $TAILSCALE_CONFIGURATOR"
    if [[ "$TAILSCALE_READY" != "true" ]]; then
        [[ "$TOKEN_STDIN" != "true" || "$TAILSCALE_API_TOKEN_STDIN" != "true" ]] || \
            error "K3s and Tailscale tokens cannot both use stdin; provision Tailscale first or use TAILSCALE_API_TOKEN."
        if [[ "$TAILSCALE_API_TOKEN_STDIN" == "true" ]]; then
            IFS= read -r TAILSCALE_API_TOKEN || error "Could not read the Tailscale API access token from stdin."
        fi
        transport_guide_tailscale_account "$NON_INTERACTIVE" "$TAILSCALE_CONFIGURATOR" || \
            error "Tailscale prerequisites are incomplete or account verification failed."
        tailscale_args=(
            --role "$ENROLLMENT_ROLE"
            --tailnet "$TAILSCALE_TAILNET"
            --mesh-name "$TAILSCALE_MESH_NAME"
            --hostname "$TAILSCALE_NODE_HOSTNAME"
            --auth-key-expiry "$TAILSCALE_AUTH_KEY_EXPIRY_SECONDS"
        )
        tailscale_args+=(--api-token-stdin --non-interactive)
        info "Automating the Tailscale account, role policy, and this $ENROLLMENT_ROLE node."
        printf '%s\n' "$TAILSCALE_API_TOKEN" | "$TAILSCALE_CONFIGURATOR" "${tailscale_args[@]}" >/dev/null
    fi
    command -v tailscale >/dev/null 2>&1 || error "Tailscale is not installed."
    tailscale status >/dev/null 2>&1 || error "Tailscale is not connected."
    NODE_IP="${NODE_IP:-$(tailscale ip -4 | head -n 1)}"
    NODE_NETWORK_CIDR="${NODE_NETWORK_CIDR:-100.64.0.0/10}"
fi

if [[ "$NODE_TRANSPORT" == "vrack" && "$NON_INTERACTIVE" != "true" ]]; then
    transport_guide_vrack_account false "$OVH_VRACK_CONFIGURATOR" || \
        error "OVHcloud vRack prerequisites are incomplete."
fi

info "K3s $ENROLLMENT_ROLE enrollment"
if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
    printf 'Obtain the server token on the bootstrap control plane:\n  sudo cat /var/lib/rancher/k3s/server/token\n'
else
    printf '%s\n' \
        "On the control-plane node, obtain a token with one of:" \
        "  sudo cat /var/lib/rancher/k3s/server/node-token" \
        "  sudo k3s token create --ttl 1h --description worker-join"
fi

if [[ "$TOKEN_STDIN" == "true" ]]; then
    IFS= read -r JOIN_TOKEN || error "Could not read the join token from stdin."
fi

if [[ "$NON_INTERACTIVE" != "true" ]]; then
    installer_prompt_section "Join endpoint and $ENROLLMENT_ROLE identity" \
        "Provide the private join endpoint, token, node network, and Kubernetes metadata."
    [[ -n "$SERVER_URL" ]] || installer_prompt_value SERVER_URL "Control-plane private IPv4 address or K3s URL"
    SERVER_URL="$(normalize_server_url "$SERVER_URL")" || error "Invalid control-plane URL: $SERVER_URL"
    SERVER_PRIVATE_IP="$(server_url_ipv4 "$SERVER_URL")" || \
        error "Use the control plane's RFC1918 or Tailscale IPv4 address, not a public address or hostname."
    [[ -n "$CONTROL_PLANE_IP" ]] || installer_prompt_value CONTROL_PLANE_IP "Control-plane private IPv4 allowed to SSH to this node" "$SERVER_PRIVATE_IP"
    if [[ -z "$JOIN_TOKEN" ]]; then
        installer_prompt_secret JOIN_TOKEN "K3s join token (input hidden)"
    fi
    [[ -n "$NODE_NAME" ]] || installer_prompt_value NODE_NAME "Unique node name" "$(hostname -s | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$NODE_IP" ]]; then
        if [[ "$NODE_TRANSPORT" == "vrack" ]]; then
            installer_prompt_value NODE_IP "This node's unique OVHcloud vRack RFC1918 address"
        else
            installer_prompt_value NODE_IP "This node's Tailscale IPv4 address" "$(detect_node_ip "$SERVER_PRIVATE_IP")"
        fi
    fi
    [[ -n "$NODE_LABELS" ]] || installer_prompt_value NODE_LABELS "Initial labels, comma-separated (optional)"
    [[ -n "$NODE_TAINTS" ]] || installer_prompt_value NODE_TAINTS "Initial taints, comma-separated (optional)"
    [[ -n "$NODE_NETWORK_CIDR" ]] || installer_prompt_value NODE_NETWORK_CIDR "RFC1918 node CIDR or Tailscale 100.64.0.0/10"
    [[ -n "$K3S_VERSION" ]] || installer_prompt_value K3S_VERSION "Exact K3s version (blank to use the current stable release)"
    while [[ -z "$NODE_NETWORK_CIDR" ]]; do
        installer_prompt_value NODE_NETWORK_CIDR "Trusted private node CIDR required for the node firewall (e.g. 10.0.0.0/24)"
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
trusted_private_cidr "$NODE_NETWORK_CIDR" || error "Node network must be RFC1918 or Tailscale 100.64.0.0/10: $NODE_NETWORK_CIDR"
NODE_IP="${NODE_IP:-$(detect_node_ip "$SERVER_PRIVATE_IP")}"
trusted_private_ipv4 "$NODE_IP" || error "Worker node IP must be RFC1918 or Tailscale: ${NODE_IP:-unavailable}"
if [[ "$NODE_TRANSPORT" == "vrack" && -z "$(interface_owning_ip "$NODE_IP")" ]]; then
    [[ -x "$OVH_VRACK_CONFIGURATOR" ]] || \
        error "OVHcloud vRack interface is not configured and the configurator is unavailable: $OVH_VRACK_CONFIGURATOR"
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        installer_prompt_section "OVHcloud private interface" \
            "Select the vRack NIC before the installer changes networking or UFW."
        ip -br link show
        [[ -n "$VRACK_INTERFACE" ]] || installer_prompt_value VRACK_INTERFACE "OVHcloud physical private/vRack NIC name"
        [[ -n "$VRACK_INTERFACE_MAC" ]] || installer_prompt_value VRACK_INTERFACE_MAC "Expected OVHcloud private NIC MAC (recommended)"
        [[ -n "$VRACK_VLAN_ID" ]] || installer_prompt_value VRACK_VLAN_ID "Optional vRack VLAN ID (blank for untagged VLAN 0)"
    fi
    vrack_args=(
        --configure-node
        --private-ip "$NODE_IP"
        --network-cidr "$NODE_NETWORK_CIDR"
        --non-interactive
    )
    [[ -z "$VRACK_INTERFACE" ]] || vrack_args+=(--interface "$VRACK_INTERFACE")
    [[ -z "$VRACK_INTERFACE_MAC" ]] || vrack_args+=(--interface-mac "$VRACK_INTERFACE_MAC")
    [[ -z "$VRACK_VLAN_ID" ]] || vrack_args+=(--vlan-id "$VRACK_VLAN_ID")
    info "Configuring OVHcloud vRack before any UFW changes..."
    "$OVH_VRACK_CONFIGURATOR" "${vrack_args[@]}" >/dev/null
fi
NODE_INTERFACE="$(detect_node_interface "$SERVER_PRIVATE_IP")"
[[ -n "$NODE_INTERFACE" ]] || error "Could not determine the private interface used to reach $SERVER_PRIVATE_IP"
[[ "$NODE_INTERFACE" == "tailscale0" ]] || [[ ! "$NODE_INTERFACE" =~ ^(lo|docker|br-|cni|flannel|veth) ]] || \
    error "The route to the control plane uses unsupported virtual interface $NODE_INTERFACE."
if [[ "$NODE_INTERFACE" == "tailscale0" ]]; then
    tailscale_ipv4 "$NODE_IP" || error "tailscale0 must use an address from 100.64.0.0/10"
    command -v tailscale >/dev/null 2>&1 || error "Tailscale is not installed"
    tailscale status >/dev/null 2>&1 || error "Tailscale is not connected"
elif [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
    error "Refusing to configure worker UFW: Tailscale must be connected and route to the control plane through tailscale0 first."
fi
ROUTE_NODE_IP="$(detect_node_ip "$SERVER_PRIVATE_IP")"
[[ "$NODE_IP" == "$ROUTE_NODE_IP" ]] || \
    error "Entered worker IP $NODE_IP is not the local route source to $SERVER_PRIVATE_IP (detected: ${ROUTE_NODE_IP:-none})."
cidr_contains_ip "$NODE_NETWORK_CIDR" "$SERVER_PRIVATE_IP" || error "K3s server address $SERVER_PRIVATE_IP is outside $NODE_NETWORK_CIDR"
cidr_contains_ip "$NODE_NETWORK_CIDR" "$CONTROL_PLANE_IP" || error "Control-plane SSH source $CONTROL_PLANE_IP is outside $NODE_NETWORK_CIDR"
cidr_contains_ip "$NODE_NETWORK_CIDR" "$NODE_IP" || error "Worker node IP $NODE_IP is outside $NODE_NETWORK_CIDR"
if [[ "$NODE_TRANSPORT" == "vrack" ]]; then
    [[ "$NODE_INTERFACE" != "$(ip -4 route show default | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')" ]] || \
        error "Refusing to use the public default-route interface as OVHcloud vRack."
fi
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

command -v apt-get >/dev/null 2>&1 || error "This installer currently supports Debian/Ubuntu nodes (apt-get is required)."
missing_packages=()
for package in ca-certificates curl open-iscsi nfs-common; do
    dpkg -s "$package" >/dev/null 2>&1 || missing_packages+=("$package")
done
if [[ ${#missing_packages[@]} -gt 0 ]]; then
    info "Installing $ENROLLMENT_ROLE prerequisites: ${missing_packages[*]}"
    "${SUDO[@]}" apt-get update -qq
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing_packages[@]}" >/dev/null
fi
"${SUDO[@]}" systemctl enable --now iscsid >/dev/null 2>&1
[[ -x "$LONGHORN_HOST_CONFIGURATOR" ]] || error "Longhorn host configurator is missing: $LONGHORN_HOST_CONFIGURATOR"
"$LONGHORN_HOST_CONFIGURATOR"

if [[ -x "$K3S_APPARMOR_INSTALLER" ]]; then
    info "Installing the enforced K3s AppArmor runtime profile..."
    "$K3S_APPARMOR_INSTALLER"
else
    warn "K3s AppArmor installer was not found next to this script; the runtime default will be used unchanged."
fi

if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
    info "Tailscale is ready on $NODE_IP; enforcing local-only UFW now."
else
    info "Enforcing the local-only firewall before K3s enrollment..."
fi
security_args=(--apply --server-exposure local --node-role "$ENROLLMENT_ROLE"
    --control-plane-ip "$CONTROL_PLANE_IP" --ssh-port "$HARDENING_SSH_PORT")
if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
    security_args+=(--private-control-plane)
    [[ -x "$K3S_NETWORK_CONFIGURATOR" ]] || error "K3s network configurator is required for server joins."
    "$K3S_NETWORK_CONFIGURATOR" --private-ip "$NODE_IP" --private-interface "$NODE_INTERFACE" --private-only
fi
K3S_NODE_NETWORK_CIDR="$NODE_NETWORK_CIDR" K3S_PRIVATE_ADDRESS="$NODE_IP" \
    "$SECURITY_HARDENER" "${security_args[@]}"

info "Checking access to $SERVER_URL..."
curl -kfsS --connect-timeout 10 --max-time 20 "$SERVER_URL/cacerts" >/dev/null || \
    error "Cannot reach $SERVER_URL. Check routing and TCP port 6443 on the control-plane firewall."

agent_args=(agent --node-ip "$NODE_IP" --flannel-iface "$NODE_INTERFACE")
K3S_SERVICE=k3s-agent
if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
    K3S_SERVICE=k3s
    agent_args=(server --server "$SERVER_URL" --node-ip "$NODE_IP"
        --advertise-address "$NODE_IP" --flannel-iface "$NODE_INTERFACE"
        --disable traefik --secrets-encryption --write-kubeconfig-mode 600
        --node-label svccontroller.k3s.cattle.io/enablelb=false)
    if [[ "$CONTROL_PLANE_SCHEDULABLE" == "false" ]]; then
        agent_args+=(--node-taint node-role.kubernetes.io/control-plane=true:NoSchedule)
    fi
fi
if [[ -n "$NODE_LABELS" ]]; then
    IFS=',' read -r -a label_values <<< "$NODE_LABELS"
    for value in "${label_values[@]}"; do
        value="$(trim "$value")"
        [[ -n "$value" ]] || error "Labels cannot contain an empty item."
        case "${value%%=*}" in
            svccontroller.k3s.cattle.io/enablelb|node-role.kubernetes.io/control-plane|node-role.kubernetes.io/master|node-role.kubernetes.io/etcd|node.bm-cluster.io/role|node.bm-cluster.io/exposure)
                error "Reserved topology label cannot be set during node enrollment: ${value%%=*}"
                ;;
        esac
        agent_args+=(--node-label "$value")
    done
fi
agent_args+=(
    --node-label "node.bm-cluster.io/role=$ENROLLMENT_ROLE"
    --node-label node.bm-cluster.io/exposure=local
)
if [[ -n "$NODE_TAINTS" ]]; then
    IFS=',' read -r -a taint_values <<< "$NODE_TAINTS"
    for value in "${taint_values[@]}"; do
        value="$(trim "$value")"
        [[ -n "$value" ]] || error "Taints cannot contain an empty item."
        case "${value%%[=:]*}" in
            node-role.kubernetes.io/control-plane|node-role.kubernetes.io/master)
                [[ "$ENROLLMENT_ROLE" != "control-plane" ]] || \
                    error "Set control-plane NoSchedule through --control-plane-schedulable, not --taints."
                ;;
        esac
        agent_args+=(--node-taint "$value")
    done
fi

# The join token travels over stdin/SSH and then in the installer's environment,
# never as a process argument. K3s itself persists its root-only service token.
export K3S_TOKEN="$JOIN_TOKEN"
install_sudo=("${SUDO[@]}")
[[ ${#SUDO[@]} -eq 0 ]] || install_sudo+=(--preserve-env=K3S_TOKEN)
install_environment=(env "K3S_URL=$SERVER_URL" "K3S_NODE_NAME=$NODE_NAME")
[[ -z "$K3S_VERSION" ]] || install_environment+=("INSTALL_K3S_VERSION=$K3S_VERSION")

info "Installing K3s $ENROLLMENT_ROLE '$NODE_NAME'..."
[[ -x "$K3S_REGISTRY_MIRROR_SCRIPT" ]] || \
    error "K3s registry mirror configurator is not executable: $K3S_REGISTRY_MIRROR_SCRIPT"
K3S_REGISTRY_HOST="$REGISTRY_HOST" K3S_REGISTRY_ENDPOINT="$REGISTRY_ENDPOINT" \
    "$K3S_REGISTRY_MIRROR_SCRIPT"
INSTALLER_TEMP_DIR="$(mktemp -d /tmp/bm-cluster-worker-installers.XXXXXX)"
chmod 700 "$INSTALLER_TEMP_DIR"
k3s_installer="$INSTALLER_TEMP_DIR/k3s-install.sh"
curl --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors \
    --connect-timeout 15 --max-time 180 \
    --output "$k3s_installer" https://get.k3s.io
chmod 700 "$k3s_installer"
"${install_sudo[@]}" "${install_environment[@]}" sh "$k3s_installer" "${agent_args[@]}"
JOIN_TOKEN=""
unset JOIN_TOKEN K3S_TOKEN

"${SUDO[@]}" systemctl is-active --quiet "$K3S_SERVICE" || error "$K3S_SERVICE did not become active; inspect: sudo journalctl -u $K3S_SERVICE"

info "Applying the mandatory private $ENROLLMENT_ROLE security policy..."
K3S_NODE_NETWORK_CIDR="$NODE_NETWORK_CIDR" K3S_PRIVATE_ADDRESS="$NODE_IP" \
    "$SECURITY_HARDENER" "${security_args[@]}"

info "$ENROLLMENT_ROLE '$NODE_NAME' is running. On the control plane, verify it with:"
printf '  kubectl wait --for=condition=Ready node/%s --timeout=5m\n' "$NODE_NAME"
printf '  kubectl get nodes -o wide\n'
