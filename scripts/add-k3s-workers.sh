#!/bin/bash
set -euo pipefail
# A caller may have exported shell tracing; never trace token handling.
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_LIBRARY="$SCRIPT_DIR/lib/network.sh"
if [[ ! -r "$NETWORK_LIBRARY" ]]; then
    echo "[ERROR] Shared network library not found: $NETWORK_LIBRARY" >&2
    exit 1
fi
# shellcheck source=lib/network.sh
source "$NETWORK_LIBRARY"
# shellcheck source=lib/control-plane-access.sh
source "$SCRIPT_DIR/lib/control-plane-access.sh"
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

PLATFORM_CONFIG="$SCRIPT_DIR/../config/platform.env"
if [[ -r "$PLATFORM_CONFIG" ]]; then
    # shellcheck source=../config/platform.env
    source "$PLATFORM_CONFIG"
fi

WORKER_INSTALLER="$SCRIPT_DIR/install-k3s-worker.sh"
K3S_APPARMOR_INSTALLER="$SCRIPT_DIR/configure-k3s-apparmor.sh"
K3S_REGISTRY_MIRROR_SCRIPT="$SCRIPT_DIR/configure-k3s-registry-mirror.sh"
K3S_APPARMOR_PROFILE="$SCRIPT_DIR/../config/apparmor/cri-containerd.apparmor.d"
LONGHORN_HOST_CONFIGURATOR="$SCRIPT_DIR/configure-longhorn-host.sh"
LONGHORN_MULTIPATH_CONFIG="$SCRIPT_DIR/../config/multipath/multipath-longhorn.conf"
SECURITY_HARDENER="$SCRIPT_DIR/configure-node-security.sh"
LYNIS_SCHEDULER="$SCRIPT_DIR/configure-lynis-schedule.sh"
NODE_AUDITOR="$SCRIPT_DIR/audit-cluster-nodes.sh"
K3S_NETWORK_CONFIGURATOR="$SCRIPT_DIR/configure-k3s-control-plane-network.sh"
TAILSCALE_CONFIGURATOR="$SCRIPT_DIR/configure-tailscale.sh"
OVH_VRACK_CONFIGURATOR="$SCRIPT_DIR/configure-ovh-vrack.sh"
CLUSTER_TOPOLOGY_RECONCILER="$SCRIPT_DIR/reconcile-cluster-topology.sh"
K3S_HA_SCRIPT="$SCRIPT_DIR/configure-k3s-ha.sh"
HA_CONTROL_PLANE_CONFIGURATOR="$SCRIPT_DIR/configure-ha-control-planes.sh"
WORKER_IPS="${K3S_WORKER_IPS:-}"
WORKER_HOSTS="${K3S_WORKER_HOSTS:-}"
REQUESTED_WORKER_COUNT="${K3S_WORKER_COUNT:-}"
ENROLLMENT_ROLE="${K3S_ENROLLMENT_ROLE:-worker}"
if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
    WORKER_IPS="${K3S_CONTROL_PLANE_IPS:-}"
    WORKER_HOSTS="${K3S_CONTROL_PLANE_HOSTS:-}"
    REQUESTED_WORKER_COUNT="${CONTROL_PLANES_TO_ADD:-}"
fi
DEFER_TOPOLOGY=false
EXPECTED_CONTROL_PLANE_COUNT="${CONTROL_PLANE_COUNT:-}"
CONTROL_PLANE_SCHEDULABLE="${CONTROL_PLANE_SCHEDULABLE:-}"
NODE_TRANSPORT="${K3S_NODE_TRANSPORT:-}"
SERVER_URL=""
CONTROL_PLANE_IP="${K3S_PRIVATE_ADDRESS:-}"
CONTROL_PLANE_SSH_IPS=""
CONTROL_PLANE_ACCESS_RECONCILER="$SCRIPT_DIR/reconcile-control-plane-access.sh"
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

control_plane_is_controller_only() {
    kubectl get nodes -o json | jq -e '
        [.items[] |
            select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
                   (.metadata.labels | has("node-role.kubernetes.io/master")))] as $control_planes |
        ($control_planes | length) > 0 and
        all($control_planes[];
            any(.spec.taints[]?;
                (.key == "node-role.kubernetes.io/control-plane" or
                 .key == "node-role.kubernetes.io/master") and
                .effect == "NoSchedule"))
    ' >/dev/null
}

usage() {
    if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
        cat <<'EOF'
Join additional Debian/Ubuntu K3s control planes over private SSH.

Run on the existing bootstrap control plane:
  ./add-node.sh --role control-plane --mode remote --count 2
  ./add-node.sh --role control-plane --mode remote --transport vrack \
    --ips 10.0.0.11,10.0.0.12 --node-network-cidr 10.0.0.0/24 \
    --control-plane-schedulable false

Control-plane options:
  --control-plane-count N   Number of additional control planes to enroll
  --control-plane-ips CSV   Additional preconfigured vRack node addresses
  --control-plane-hosts CSV Additional Tailscale bootstrap SSH hosts
  --defer-topology          Let the main installer reconcile after workers join
  --expected-control-plane-count N
                            Optional final odd control-plane count (main installer sets it)
  --control-plane-schedulable true|false|preserve
                            Scheduling mode (default: inherit existing mode)
  --transport MODE          vrack for OVHcloud-only, tailscale for hybrid nodes
  --server-url URL          Any registered control plane's private IPv4 join endpoint
  --control-plane-ip IP    This host's private SSH source (detected by default)
  --node-network-cidr CIDR  Trusted RFC1918 subnet or Tailscale 100.64.0.0/10
  --ssh-user USER           Default SSH user; requires passwordless sudo or root
  --ssh-port PORT           Default SSH port (22)
  --identity-file PATH      SSH private key; omitted to use the agent/config
  --labels CSV              Additional node labels
  --taints CSV              Additional taints; standard NoSchedule uses scheduling mode
  --k3s-version VERSION     Must equal this server's exact K3s version
  --tailscale-api-token-stdin
                            Read a personal tskey-api access token from stdin
  --tailscale-tailnet NAME  Tailnet name; "-" uses the token's tailnet
  --tailscale-mesh NAME     Cluster-specific mesh name
  --tailscale-hostname NAME This bootstrap control plane's Tailscale hostname
  --tailscale-key-expiry N  One-use auth-key validity in seconds
  --non-interactive         Fail instead of prompting; implied by either node list
  -h, --help                Show this help

The final control-plane count must be odd. After validating that plan, an
existing SQLite server is backed up and converted to embedded etcd if needed.
Existing etcd membership is preserved; external datastores are not converted.
Server joins use the existing server token and exact version,
disable Traefik, enable secrets encryption, and remain private. Already joined
nodes with matching names, roles, and private IPs are checked and reused.
Private SSH is proved before the provider-facing firewall is closed. Join
credentials are transferred through stdin and are never printed or passed as
process arguments. K3s stores its own root-only service credentials.
EOF
        return
    fi
    cat <<'EOF'
Add one or more Debian/Ubuntu machines to this K3s cluster as workers.

Interactive usage (run on the K3s control-plane node):
  ./add-node.sh --role worker --mode remote

Non-interactive worker selection:
  ./add-node.sh --role worker --mode remote \
    --transport vrack \
    --worker-ips 10.0.0.12,10.0.0.13 \
    --node-network-cidr 10.0.0.0/24 \
    --identity-file ~/.ssh/id_ed25519

Options:
  --transport MODE          OVHcloud-only vrack, or hybrid/non-OVH tailscale
  --worker-ips CSV          Preconfigured OVHcloud vRack worker addresses
  --worker-hosts CSV        Tailscale bootstrap SSH hosts/IPs (one or more)
  --worker-count COUNT      Number of workers to prompt for interactively
  --control-plane-schedulable true|false|preserve
                            Explicit post-enrollment control-plane scheduling mode
  --server-url URL          K3s URL using a registered control plane's private IPv4
  --control-plane-ip IP    This host's private SSH source (detected by default)
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
        --worker-count)     shift; [[ $# -gt 0 ]] || error "Missing worker count"; REQUESTED_WORKER_COUNT="$1" ;;
        --worker-count=*)   REQUESTED_WORKER_COUNT="${1#*=}" ;;
        --control-plane-ips) shift; [[ $# -gt 0 ]] || error "Missing control-plane IP list"; WORKER_IPS="$1"; NON_INTERACTIVE=true ;;
        --control-plane-ips=*) WORKER_IPS="${1#*=}"; NON_INTERACTIVE=true ;;
        --control-plane-hosts) shift; [[ $# -gt 0 ]] || error "Missing control-plane host list"; WORKER_HOSTS="$1"; NON_INTERACTIVE=true ;;
        --control-plane-hosts=*) WORKER_HOSTS="${1#*=}"; NON_INTERACTIVE=true ;;
        --control-plane-count) shift; [[ $# -gt 0 ]] || error "Missing additional control-plane count"; REQUESTED_WORKER_COUNT="$1" ;;
        --control-plane-count=*) REQUESTED_WORKER_COUNT="${1#*=}" ;;
        --defer-topology) DEFER_TOPOLOGY=true ;;
        --expected-control-plane-count) shift; [[ $# -gt 0 ]] || error "Missing final control-plane count"; EXPECTED_CONTROL_PLANE_COUNT="$1" ;;
        --expected-control-plane-count=*) EXPECTED_CONTROL_PLANE_COUNT="${1#*=}" ;;
        --control-plane-schedulable) shift; [[ $# -gt 0 ]] || error "Missing control-plane scheduling mode"; CONTROL_PLANE_SCHEDULABLE="$1" ;;
        --control-plane-schedulable=*) CONTROL_PLANE_SCHEDULABLE="${1#*=}" ;;
        --control-plane-ip) shift; [[ $# -gt 0 ]] || error "Missing local control-plane IP"; CONTROL_PLANE_IP="$1" ;;
        --control-plane-ip=*) CONTROL_PLANE_IP="${1#*=}" ;;
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

[[ "$ENROLLMENT_ROLE" =~ ^(worker|control-plane)$ ]] || error "Invalid enrollment role: $ENROLLMENT_ROLE"
[[ -f "$WORKER_INSTALLER" ]] || error "Worker installer not found: $WORKER_INSTALLER"
[[ -f "$NETWORK_LIBRARY" ]] || error "Network library not found: $NETWORK_LIBRARY"
[[ -f "$K3S_APPARMOR_INSTALLER" ]] || error "AppArmor installer not found: $K3S_APPARMOR_INSTALLER"
[[ -x "$K3S_REGISTRY_MIRROR_SCRIPT" ]] || error "K3s registry mirror configurator not found or not executable: $K3S_REGISTRY_MIRROR_SCRIPT"
[[ -f "$K3S_APPARMOR_PROFILE" ]] || error "AppArmor profile not found: $K3S_APPARMOR_PROFILE"
[[ -x "$LONGHORN_HOST_CONFIGURATOR" && -r "$LONGHORN_MULTIPATH_CONFIG" ]] || error "Longhorn host configurator or multipath config is missing."
[[ -x "$TAILSCALE_CONFIGURATOR" ]] || error "Tailscale configurator not found or not executable: $TAILSCALE_CONFIGURATOR"
[[ -x "$OVH_VRACK_CONFIGURATOR" ]] || error "OVHcloud vRack configurator not found or not executable: $OVH_VRACK_CONFIGURATOR"
[[ -x "$CLUSTER_TOPOLOGY_RECONCILER" ]] || error "Cluster topology reconciler not found or not executable: $CLUSTER_TOPOLOGY_RECONCILER"
[[ -z "$REQUESTED_WORKER_COUNT" || "$REQUESTED_WORKER_COUNT" =~ ^[1-9][0-9]*$ ]] || error "Requested $ENROLLMENT_ROLE count must be a positive integer."
command -v ssh >/dev/null 2>&1 || error "ssh is required."
command -v scp >/dev/null 2>&1 || error "scp is required."
command -v kubectl >/dev/null 2>&1 || error "kubectl is required; run this script on a configured control-plane node."
command -v jq >/dev/null 2>&1 || error "jq is required."
kubectl cluster-info >/dev/null 2>&1 || error "Cannot reach the Kubernetes API with the current kubeconfig."
stored_ha_mode="$(kubectl -n infra get configmap bm-cluster-topology --ignore-not-found -o jsonpath='{.data.highAvailabilityEnabled}')"
if [[ -z "${HIGH_AVAILABILITY_ENABLED:-}" ]]; then
    HIGH_AVAILABILITY_ENABLED="${stored_ha_mode:-false}"
fi
[[ "$HIGH_AVAILABILITY_ENABLED" == true || "$HIGH_AVAILABILITY_ENABLED" == false ]] || error "Invalid HA mode"
[[ "$stored_ha_mode" != true || "$HIGH_AVAILABILITY_ENABLED" == true ]] || error "Cannot disable persisted HA while adding nodes"
export HIGH_AVAILABILITY_ENABLED
if [[ -z "$CONTROL_PLANE_SCHEDULABLE" ]]; then
    if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
        CONTROL_PLANE_SCHEDULABLE=preserve
    elif control_plane_is_controller_only; then
        CONTROL_PLANE_SCHEDULABLE=false
        info "The control plane is already controller-only; preserving NoSchedule without another question."
    else
        [[ "$NON_INTERACTIVE" != "true" ]] || \
            error "Set --control-plane-schedulable true|false|preserve for non-interactive enrollment."
        installer_prompt_section "Post-enrollment control-plane role" \
            "The change is applied only after every new worker is Ready."
        if installer_prompt_yes_no \
            "Switch the control plane to controller-only (NoSchedule) and keep Longhorn storage on workers?" \
            Y false; then
            CONTROL_PLANE_SCHEDULABLE=false
        else
            CONTROL_PLANE_SCHEDULABLE=true
        fi
    fi
fi
case "${CONTROL_PLANE_SCHEDULABLE,,}" in
    1|true|yes|y|worker|controller-worker) CONTROL_PLANE_SCHEDULABLE=true ;;
    0|false|no|n|controller|controller-only) CONTROL_PLANE_SCHEDULABLE=false ;;
    preserve) CONTROL_PLANE_SCHEDULABLE=preserve ;;
    *) error "--control-plane-schedulable must be true, false, or preserve." ;;
esac
[[ "$SSH_PORT" =~ ^[0-9]+$ && "$SSH_PORT" -ge 1 && "$SSH_PORT" -le 65535 ]] || error "Invalid SSH port: $SSH_PORT"
[[ -z "$IDENTITY_FILE" || -f "$IDENTITY_FILE" ]] || error "SSH identity file does not exist: $IDENTITY_FILE"
if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || error "sudo is required when not running as root."
    LOCAL_SUDO=(sudo)
fi

if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
    # New nodes must inherit an actual scheduling mode even when the caller
    # asks to preserve the existing cluster's scheduling policy.
    JOIN_CONTROL_PLANE_SCHEDULABLE="$CONTROL_PLANE_SCHEDULABLE"
    if [[ "$JOIN_CONTROL_PLANE_SCHEDULABLE" == "preserve" ]]; then
        JOIN_CONTROL_PLANE_SCHEDULABLE=true
        if control_plane_is_controller_only; then
            JOIN_CONTROL_PLANE_SCHEDULABLE=false
        fi
    fi
fi

select_transport() {
    installer_select_node_transport NODE_TRANSPORT "$NODE_TRANSPORT" vrack "$NON_INTERACTIVE" || \
        error "Set --transport to vrack or tailscale."
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

if [[ "$NON_INTERACTIVE" != "true" ]]; then
    installer_prompt_section "Private $ENROLLMENT_ROLE transport" \
        "Use one transport consistently for every cluster node."
fi
select_transport
if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
    if [[ "$TAILSCALE_API_TOKEN_STDIN" == "true" ]]; then
        IFS= read -r TAILSCALE_API_TOKEN || error "Could not read the Tailscale API access token from stdin."
    fi
    if [[ "$TAILSCALE_CONFIG_PREPARED" != "true" ]]; then
        transport_guide_tailscale_account "$NON_INTERACTIVE" "$TAILSCALE_CONFIGURATOR" || \
            error "Tailscale prerequisites are incomplete or account verification failed."
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
        transport_guide_vrack_account "$NON_INTERACTIVE" "$OVH_VRACK_CONFIGURATOR" || \
            error "OVHcloud vRack prerequisites are incomplete or account verification failed."
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
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-$default_ip}"
if [[ -z "$SERVER_URL" && -n "$default_ip" ]]; then
    SERVER_URL="https://${default_ip}:6443"
fi
if [[ -z "$K3S_VERSION" ]] && command -v k3s >/dev/null 2>&1; then
    K3S_VERSION="$(k3s --version 2>/dev/null | awk 'NR == 1 {print $3}')"
fi
if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
    bootstrap_version="$(k3s --version 2>/dev/null | awk 'NR == 1 {print $3}')"
    [[ -n "$bootstrap_version" && "$K3S_VERSION" == "$bootstrap_version" ]] || \
        error "Control-plane joins must use the bootstrap server's exact K3s version ($bootstrap_version)."
fi

info "K3s $ENROLLMENT_ROLE enrollment"
TOKEN_FILE=/var/lib/rancher/k3s/server/node-token
[[ "$ENROLLMENT_ROLE" != "control-plane" ]] || TOKEN_FILE=/var/lib/rancher/k3s/server/token
printf 'Token command on the control-plane node:\n  sudo cat %s\n' "$TOKEN_FILE"

if [[ -r "$TOKEN_FILE" ]]; then
    JOIN_TOKEN="$(< "$TOKEN_FILE")"
elif [[ ${#LOCAL_SUDO[@]} -gt 0 ]] && "${LOCAL_SUDO[@]}" test -r "$TOKEN_FILE"; then
    JOIN_TOKEN="$("${LOCAL_SUDO[@]}" cat "$TOKEN_FILE")"
elif [[ -n "${K3S_JOIN_TOKEN:-}" ]]; then
    JOIN_TOKEN="$K3S_JOIN_TOKEN"
else
    [[ "$NON_INTERACTIVE" != "true" ]] || error "Cannot read the server node token. Set K3S_JOIN_TOKEN or run on the control plane."
    installer_prompt_secret JOIN_TOKEN "K3s join token (input hidden)"
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
    installer_prompt_section "$ENROLLMENT_ROLE enrollment defaults" \
        "These connection, network, label, and version values apply to every new node."
    installer_prompt_value SERVER_URL "K3s URL using a registered control plane's private IPv4 address" "$SERVER_URL"
    installer_prompt_value SSH_USER "Default $ENROLLMENT_ROLE SSH user" "$SSH_USER"
    installer_prompt_value SSH_PORT "$ENROLLMENT_ROLE SSH port" "$SSH_PORT"
    installer_prompt_value IDENTITY_FILE "SSH private key path (blank for agent/config)" "$IDENTITY_FILE"
    [[ -z "$IDENTITY_FILE" || -f "$IDENTITY_FILE" ]] || error "SSH identity file does not exist: $IDENTITY_FILE"
    if [[ "$NODE_TRANSPORT" == "vrack" ]]; then
        installer_prompt_value NODE_NETWORK_CIDR "Trusted vRack/private node CIDR (e.g. 10.0.0.0/24)" "$NODE_NETWORK_CIDR"
    fi
    installer_prompt_value COMMON_LABELS "Labels for every new node, comma-separated (optional)" "$COMMON_LABELS"
    installer_prompt_value COMMON_TAINTS "Additional taints for every new node, comma-separated (optional)" "$COMMON_TAINTS"
    if [[ "$ENROLLMENT_ROLE" == "worker" ]]; then
        installer_prompt_value K3S_VERSION "Exact worker K3s version" "$K3S_VERSION"
    fi
    while [[ -z "$NODE_NETWORK_CIDR" ]]; do
        installer_prompt_value NODE_NETWORK_CIDR "Trusted private node CIDR required for worker UFW (e.g. 10.0.0.0/24)"
    done

    worker_count="$REQUESTED_WORKER_COUNT"
    while [[ ! "$worker_count" =~ ^[1-9][0-9]*$ ]]; do
        installer_prompt_value worker_count "Number of $ENROLLMENT_ROLE nodes to add"
        [[ "$worker_count" =~ ^[1-9][0-9]*$ ]] || warn "Enter a positive whole number."
    done
else
    if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
        [[ -n "$WORKER_HOSTS" ]] || error "--${ENROLLMENT_ROLE}-hosts is required for non-interactive Tailscale enrollment."
    else
        [[ -n "$WORKER_IPS" ]] || error "--${ENROLLMENT_ROLE}-ips is required for non-interactive vRack enrollment."
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
CONTROL_PLANE_SSH_IPS="$(control_plane_private_ips "$(kubectl get nodes -o json)" "$NODE_NETWORK_CIDR")" || \
    error "Cannot obtain verified private control-plane addresses from Kubernetes"
control_plane_address_member "$CONTROL_PLANE_SSH_IPS" "$SERVER_PRIVATE_IP" || \
    error "The K3s join endpoint must belong to a registered control plane"
control_plane_address_member "$CONTROL_PLANE_SSH_IPS" "$CONTROL_PLANE_IP" || \
    error "The local SSH source must belong to a registered control plane"
CONTROL_PLANE_CLUSTER_INTERFACE="$(interface_owning_ip "$CONTROL_PLANE_IP")"
[[ -n "$CONTROL_PLANE_CLUSTER_INTERFACE" ]] || \
    error "Control-plane SSH source $CONTROL_PLANE_IP is not assigned to a local interface. Run this mode on the control-plane node."
[[ "$CONTROL_PLANE_CLUSTER_INTERFACE" == "tailscale0" ]] || [[ ! "$CONTROL_PLANE_CLUSTER_INTERFACE" =~ ^(lo|docker|br-|cni|flannel|veth) ]] || \
    error "Control-plane SSH source $CONTROL_PLANE_IP belongs to unsupported virtual interface $CONTROL_PLANE_CLUSTER_INTERFACE."
if [[ "$CONTROL_PLANE_CLUSTER_INTERFACE" == "tailscale0" ]]; then
    tailscale_ipv4 "$CONTROL_PLANE_IP" || error "tailscale0 must use an address from 100.64.0.0/10"
    command -v tailscale >/dev/null 2>&1 || error "Tailscale address selected but Tailscale is not installed"
    "${LOCAL_SUDO[@]}" tailscale status >/dev/null 2>&1 || error "Tailscale address selected but this node is not connected"
    "${LOCAL_SUDO[@]}" tailscale set --ssh=false --netfilter-mode=nodivert >/dev/null || \
        error "Unable to make UFW authoritative for Tailscale traffic"
fi

info "Reconciling K3s private networking on $CONTROL_PLANE_IP via $CONTROL_PLANE_CLUSTER_INTERFACE..."
"$K3S_NETWORK_CONFIGURATOR" \
    --private-ip "$CONTROL_PLANE_IP" \
    --private-interface "$CONTROL_PLANE_CLUSTER_INTERFACE" \
    --restart

if command -v ufw >/dev/null 2>&1 && "${LOCAL_SUDO[@]}" ufw status | grep -q '^Status: active'; then
    [[ -n "$NODE_NETWORK_CIDR" ]] || error "UFW is active on the control plane. Provide --node-network-cidr to open only the trusted private network."
    info "Allowing K3s node traffic from $NODE_NETWORK_CIDR on the control plane..."
    "${LOCAL_SUDO[@]}" sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 6443 proto tcp >/dev/null
    if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
        "${LOCAL_SUDO[@]}" ufw allow in on "$CONTROL_PLANE_CLUSTER_INTERFACE" from "$NODE_NETWORK_CIDR" to any port 2379:2380 proto tcp comment 'K3s embedded etcd' >/dev/null
    fi
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
        detected_mac="$(OVH_APPLICATION_KEY="$OVH_APPLICATION_KEY" \
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
    info "Private SSH is proven through $configured_interface; node UFW may now close public ingress."
    VRACK_TARGET="$private_target"
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

    info "Creating a one-use Tailscale $ENROLLMENT_ROLE key for $TAILSCALE_NODE_NAME."
    node_auth_key="$(printf '%s\n' "$TAILSCALE_API_TOKEN" | \
        "$TAILSCALE_CONFIGURATOR" --role "$ENROLLMENT_ROLE" \
            --tailnet "$TAILSCALE_TAILNET" --mesh-name "$TAILSCALE_MESH_NAME" \
            --auth-key-expiry "$TAILSCALE_AUTH_KEY_EXPIRY_SECONDS" \
            --create-auth-key --api-token-stdin)"
    [[ "$node_auth_key" =~ ^tskey-auth-[A-Za-z0-9_-]+$ ]] || error "Could not create a Tailscale worker auth key."
    info "Installing and connecting Tailscale on $bootstrap_target."
    if ! worker_ip="$(printf '%s\n' "$node_auth_key" | ssh "${ssh_options[@]}" "$bootstrap_target" \
        "chmod 700 $quoted_script && $quoted_script --role $(printf '%q' "$ENROLLMENT_ROLE") --tailnet $(printf '%q' "$TAILSCALE_TAILNET") --mesh-name $(printf '%q' "$TAILSCALE_MESH_NAME") --hostname $(printf '%q' "$TAILSCALE_NODE_NAME") --auth-key-stdin")"; then
        node_auth_key=""
        ssh "${ssh_options[@]}" "$bootstrap_target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true
        error "Tailscale provisioning failed on $bootstrap_target."
    fi
    node_auth_key=""
    worker_ip="$(awk 'NF {value=$0} END {print value}' <<< "$worker_ip")"
    tailscale_ipv4 "$worker_ip" || error "The worker did not return a valid Tailscale IPv4 address: ${worker_ip:-none}"
    printf '%s\n' "$TAILSCALE_API_TOKEN" | \
        "$TAILSCALE_CONFIGURATOR" --role "$ENROLLMENT_ROLE" \
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
    local connection_info client_ip worker_ip
    [[ "$target" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ || "$target" =~ ^[A-Za-z0-9._:-]+$ ]] || \
        error "Invalid SSH target: $target"
    ssh "${ssh_options[@]}" "$target" \
        'test "$(id -u)" -eq 0 || (command -v sudo >/dev/null 2>&1 && sudo -n true)' >/dev/null || \
        error "Cannot use passwordless sudo on $target. Configure SSH keys and NOPASSWD sudo, or connect as root."
    connection_info="$(ssh "${ssh_options[@]}" "$target" 'printf "%s" "$SSH_CONNECTION"')"
    read -r client_ip _ worker_ip _ <<< "$connection_info"
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
    [[ "$client_ip" == "$CONTROL_PLANE_IP" ]] || \
        error "SSH used $client_ip instead of the verified local control-plane source $CONTROL_PLANE_IP"
    TARGET_CONTROL_PLANE_IP="$client_ip"
    TARGET_WORKER_IP="$worker_ip"
}

remote_hostname() {
    ssh "${ssh_options[@]}" "$1" "hostname -s | tr '[:upper:]' '[:lower:]'"
}

preflight_control_plane_count() {
    [[ "$ENROLLMENT_ROLE" == "control-plane" ]] || return 0
    local nodes current_count new_count=0 planned_count host node_name existing_role selected_list
    local -a selected_hosts=()
    local -A seen_targets=()
    nodes="$(kubectl get nodes -o json)"
    current_count="$(jq '[.items[] | select(.metadata.labels | has("node-role.kubernetes.io/control-plane") or has("node-role.kubernetes.io/master"))] | length' <<< "$nodes")"
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        selected_list="$WORKER_IPS"
        [[ "$NODE_TRANSPORT" != "tailscale" ]] || selected_list="$WORKER_HOSTS"
        [[ "$selected_list" != ,* && "$selected_list" != *, && "$selected_list" != *,,* ]] || \
            error "Control-plane host list contains an empty item."
        IFS=',' read -r -a selected_hosts <<< "$selected_list"
        [[ -z "$REQUESTED_WORKER_COUNT" || ${#selected_hosts[@]} -eq "$REQUESTED_WORKER_COUNT" ]] || \
            error "The control-plane host list must contain exactly $REQUESTED_WORKER_COUNT entries."
        for host in "${selected_hosts[@]}"; do
            host="${host#"${host%%[![:space:]]*}"}"
            host="${host%"${host##*[![:space:]]}"}"
            [[ -n "$host" ]] || error "Control-plane host list contains an empty item."
            if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
                check_bootstrap_target "$(build_target "$host")"
                node_name="$(remote_hostname "$(build_target "$host")")"
                [[ -n "$node_name" ]] || error "Could not determine the hostname of $host."
                existing_role="$(jq -r --arg name "$node_name" '.items[] | select(.metadata.name == $name) | if (.metadata.labels | has("node-role.kubernetes.io/control-plane") or has("node-role.kubernetes.io/master")) then "control-plane" else "worker" end' <<< "$nodes")"
            else
                if ! trusted_private_ipv4 "$host" || tailscale_ipv4 "$host"; then
                    error "Invalid vRack control-plane IP: $host"
                fi
                cidr_contains_ip "$NODE_NETWORK_CIDR" "$host" || error "$host is outside $NODE_NETWORK_CIDR."
                [[ "$host" != "$CONTROL_PLANE_IP" ]] || error "The bootstrap control plane cannot enroll itself."
                node_name="$host"
                existing_role="$(jq -r --arg ip "$host" '.items[] | select(any(.status.addresses[]?; .type == "InternalIP" and .address == $ip)) | if (.metadata.labels | has("node-role.kubernetes.io/control-plane") or has("node-role.kubernetes.io/master")) then "control-plane" else "worker" end' <<< "$nodes")"
            fi
            [[ -z "${seen_targets[$node_name]:-}" ]] || error "Duplicate control-plane enrollment target: $node_name"
            seen_targets["$node_name"]=1
            [[ -z "$existing_role" || "$existing_role" == "control-plane" ]] || error "Target $host is already registered as a worker."
            [[ -n "$existing_role" ]] || new_count=$((new_count + 1))
        done
    else
        # Interactive counts describe new servers. List-based reruns above can
        # include already joined nodes and count only genuinely new members.
        new_count="$worker_count"
    fi
    planned_count=$((current_count + new_count))
    (( planned_count % 2 == 1 )) || \
        error "This selection would leave $planned_count control planes; choose an odd final count (1, 3, 5, ...)."
    if [[ -n "$EXPECTED_CONTROL_PLANE_COUNT" ]]; then
        if [[ ! "$EXPECTED_CONTROL_PLANE_COUNT" =~ ^[1-9][0-9]*$ ]] || (( EXPECTED_CONTROL_PLANE_COUNT % 2 != 1 )); then
            error "The expected final control-plane count must be a positive odd integer."
        fi
        [[ "$planned_count" -eq "$EXPECTED_CONTROL_PLANE_COUNT" ]] || \
            error "The selected targets produce $planned_count control planes, but $EXPECTED_CONTROL_PLANE_COUNT were requested."
    fi
    EXPECTED_CONTROL_PLANE_COUNT="$planned_count"
    info "Validated control-plane plan: $current_count existing + $new_count new = $planned_count total."
}

prepare_control_plane_datastore() {
    [[ "$ENROLLMENT_ROLE" == control-plane ]] || return 0
    if "${LOCAL_SUDO[@]}" test -d /var/lib/rancher/k3s/server/db/etcd/member; then
        info "Using the existing embedded-etcd datastore."
        return 0
    fi
    # This entry point expands an existing cluster; never initialize a fresh
    # server merely because the kubeconfig reaches some other cluster.
    "${LOCAL_SUDO[@]}" test -s /var/lib/rancher/k3s/server/db/state.db || \
        error "Run control-plane enrollment on the existing SQLite or embedded-etcd bootstrap server."
    [[ -x "$K3S_HA_SCRIPT" ]] || error "Embedded-etcd configurator is missing: $K3S_HA_SCRIPT"
    info "Backing up SQLite and preparing embedded etcd for the validated control-plane plan..."
    "$K3S_HA_SCRIPT" || error "Embedded-etcd preparation failed; no additional control planes were enrolled."
    "${LOCAL_SUDO[@]}" test -d /var/lib/rancher/k3s/server/db/etcd/member || \
        error "Embedded etcd is not ready; no additional control planes were enrolled."
    # Read again after conversion so joins use the current secure server token.
    JOIN_TOKEN="$("${LOCAL_SUDO[@]}" cat /var/lib/rancher/k3s/server/token)"
    [[ -n "$JOIN_TOKEN" ]] || error "The server token is empty after embedded-etcd preparation."
}

install_worker() {
    local target="$1" node_name="$2" node_ip="$3" labels="$4" taints="$5" control_plane_ip="$6"
    local remote_dir="" remote_installer="" remote_hardener=""
    local remote_command quoted quoted_dir quoted_installer quoted_hardener argument existing_node existing_role registered_ip
    CONTROL_PLANE_SSH_IPS="$(control_plane_private_ips "$(kubectl get nodes -o json)" "$NODE_NETWORK_CIDR")" || \
        error "Cannot verify control-plane SSH sources before enrollment"
    control_plane_address_member "$CONTROL_PLANE_SSH_IPS" "$control_plane_ip" || \
        error "The actual SSH source is not a verified control plane"
    local worker_args=(
        --non-interactive
        --node-role "$ENROLLMENT_ROLE"
        --transport "$NODE_TRANSPORT"
        --server-url "$SERVER_URL"
        --token-stdin
        --node-name "$node_name"
        --ssh-port "$SSH_PORT"
        --control-plane-ip "$control_plane_ip"
        --control-plane-ssh-ips "$CONTROL_PLANE_SSH_IPS"
    )

    [[ "$node_name" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && ${#node_name} -le 253 ]] || \
        error "Invalid Kubernetes node name: $node_name"
    [[ "$node_ip" != "$CONTROL_PLANE_IP" ]] || error "The bootstrap control plane cannot enroll itself."
    existing_node="$(kubectl get nodes -o json | jq -c --arg name "$node_name" --arg ip "$node_ip" '
        [.items[] | select(.metadata.name == $name or any(.status.addresses[]?; .type == "InternalIP" and .address == $ip))]')"
    if [[ "$(jq length <<< "$existing_node")" -gt 0 ]]; then
        [[ "$(jq length <<< "$existing_node")" -eq 1 && "$(jq -r '.[0].metadata.name' <<< "$existing_node")" == "$node_name" ]] || \
            error "Node name/IP collision for $node_name ($node_ip); resolve the existing registration first."
        existing_role="$(jq -r '.[0] | if (.metadata.labels | has("node-role.kubernetes.io/control-plane") or has("node-role.kubernetes.io/master")) then "control-plane" else "worker" end' <<< "$existing_node")"
        registered_ip="$(jq -r '.[0].status.addresses[]? | select(.type == "InternalIP") | .address' <<< "$existing_node")"
        [[ "$existing_role" == "$ENROLLMENT_ROLE" && "$registered_ip" == "$node_ip" ]] || \
            error "Existing node $node_name has role $existing_role and IP $registered_ip; refusing to replace it with $ENROLLMENT_ROLE at $node_ip."
        if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
            ssh "${ssh_options[@]}" "$target" 'systemctl is-active --quiet k3s' || \
                error "Existing control plane $node_name is not running K3s; repair it before enrollment."
            [[ "$(ssh "${ssh_options[@]}" "$target" "k3s --version | awk 'NR == 1 {print \$3}'")" == "$K3S_VERSION" ]] || \
                error "Existing control plane $node_name uses a different K3s version; upgrade servers together."
            kubectl wait --for=condition=Ready "node/$node_name" --timeout=5m
            kubectl label "node/$node_name" svccontroller.k3s.cattle.io/enablelb=false \
                node.bm-cluster.io/role=control-plane node.bm-cluster.io/exposure=local --overwrite >/dev/null
            info "Control plane '$node_name' already belongs to this cluster; keeping its existing server configuration."
            return 0
        fi
    fi
    if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
        worker_args+=(--control-plane-schedulable "$JOIN_CONTROL_PLANE_SCHEDULABLE")
    fi
    [[ -z "${PLATFORM_DOMAIN:-}" ]] || worker_args+=(--domain "$PLATFORM_DOMAIN")

    [[ "$NODE_TRANSPORT" != "tailscale" ]] || worker_args+=(--tailscale-ready)

    [[ -z "$node_ip" ]] || worker_args+=(--node-ip "$node_ip")
    [[ -z "$labels" ]] || worker_args+=(--labels "$labels")
    [[ -z "$taints" ]] || worker_args+=(--taints "$taints")
    [[ -z "$NODE_NETWORK_CIDR" ]] || worker_args+=(--node-network-cidr "$NODE_NETWORK_CIDR")
    [[ -z "$K3S_VERSION" ]] || worker_args+=(--k3s-version "$K3S_VERSION")
    remote_dir="$(ssh "${ssh_options[@]}" "$target" 'mktemp -d /tmp/bm-cluster-worker.XXXXXX')"
    [[ "$remote_dir" == /tmp/bm-cluster-worker.* ]] || error "Could not create a safe temporary directory on $target."
    printf -v quoted_dir '%q' "$remote_dir"
    ssh "${ssh_options[@]}" "$target" "mkdir -m 700 $quoted_dir/scripts $quoted_dir/scripts/lib $quoted_dir/config $quoted_dir/config/apparmor $quoted_dir/config/multipath"
    info "Copying the $ENROLLMENT_ROLE installer and enforced AppArmor profile to $target..."
    scp "${scp_options[@]}" "$WORKER_INSTALLER" "$K3S_APPARMOR_INSTALLER" "$K3S_REGISTRY_MIRROR_SCRIPT" "$target:$remote_dir/scripts/"
    scp "${scp_options[@]}" "$TAILSCALE_CONFIGURATOR" "$OVH_VRACK_CONFIGURATOR" "$target:$remote_dir/scripts/"
    scp "${scp_options[@]}" "$NETWORK_LIBRARY" "$PROMPT_LIBRARY" "$TRANSPORT_GUIDE_LIBRARY" "$target:$remote_dir/scripts/lib/"
    scp "${scp_options[@]}" "$K3S_NETWORK_CONFIGURATOR" "$target:$remote_dir/scripts/"
    scp "${scp_options[@]}" "$K3S_APPARMOR_PROFILE" "$target:$remote_dir/config/apparmor/"
    scp "${scp_options[@]}" "$LONGHORN_HOST_CONFIGURATOR" "$target:$remote_dir/scripts/"
    scp "${scp_options[@]}" "$LONGHORN_MULTIPATH_CONFIG" "$target:$remote_dir/config/multipath/"
    if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
        scp "${scp_options[@]}" "$LYNIS_SCHEDULER" "$NODE_AUDITOR" "${HA_CONTROL_PLANE_CONFIGURATOR:-$SCRIPT_DIR/configure-ha-control-planes.sh}" "$target:$remote_dir/scripts/"
        ssh "${ssh_options[@]}" "$target" "chmod 700 $(printf '%q' "$remote_dir/scripts/configure-lynis-schedule.sh") $(printf '%q' "$remote_dir/scripts/audit-cluster-nodes.sh")"
    fi
    info "Copying the worker host-security policy to $target..."
    scp "${scp_options[@]}" "$SECURITY_HARDENER" "$target:$remote_dir/scripts/"
    remote_installer="$remote_dir/scripts/install-k3s-worker.sh"

    printf -v quoted_installer '%q' "$remote_installer"
    remote_command="chmod 700 $quoted_installer && $quoted_installer"
    remote_hardener="$remote_dir/scripts/configure-node-security.sh"
    printf -v quoted_hardener '%q' "$remote_hardener"
    remote_command="chmod 700 $quoted_installer $quoted_hardener $(printf '%q' "$remote_dir/scripts/configure-k3s-apparmor.sh") $(printf '%q' "$remote_dir/scripts/configure-longhorn-host.sh") $(printf '%q' "$remote_dir/scripts/configure-k3s-registry-mirror.sh") $(printf '%q' "$remote_dir/scripts/configure-tailscale.sh") $(printf '%q' "$remote_dir/scripts/configure-ovh-vrack.sh") $(printf '%q' "$remote_dir/scripts/configure-k3s-control-plane-network.sh") && $quoted_installer"
    if [[ "$ENROLLMENT_ROLE" == control-plane && "${HIGH_AVAILABILITY_ENABLED:-false}" == true ]]; then
        remote_command="export HIGH_AVAILABILITY_ENABLED=true; $remote_command"
    fi
    for argument in "${worker_args[@]}"; do
        printf -v quoted '%q' "$argument"
        remote_command+=" $quoted"
    done

    info "Installing '$node_name' through $target..."
    if ! printf '%s\n' "$JOIN_TOKEN" | ssh "${ssh_options[@]}" "$target" "$remote_command"; then
        ssh "${ssh_options[@]}" "$target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true
        error "$ENROLLMENT_ROLE installation failed on $target."
    fi
    ssh "${ssh_options[@]}" "$target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true

    info "Confirming a fresh private SSH connection after $ENROLLMENT_ROLE UFW was enabled..."
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
    [[ "$node_registered" == "true" ]] || error "$ENROLLMENT_ROLE '$node_name' did not register within 60 seconds."
    kubectl wait --for=condition=Ready "node/$node_name" --timeout=5m
    kubectl label "node/$node_name" \
        "node.bm-cluster.io/role=$ENROLLMENT_ROLE" \
        node.bm-cluster.io/exposure=local \
        --overwrite >/dev/null
    if [[ "$target" == *@* ]]; then
        kubectl annotate "node/$node_name" "node.bm-cluster.io/ssh-user=${target%@*}" --overwrite >/dev/null
    fi
    if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
        kubectl label "node/$node_name" svccontroller.k3s.cattle.io/enablelb=false --overwrite >/dev/null
    else
        kubectl label "node/$node_name" svccontroller.k3s.cattle.io/enablelb- >/dev/null 2>&1 || true
    fi
}

DEFAULT_WORKER_SSH_USER="$SSH_USER"
DEFAULT_WORKER_SSH_PORT="$SSH_PORT"
DEFAULT_WORKER_IDENTITY_FILE="$IDENTITY_FILE"

preflight_control_plane_count
prepare_control_plane_datastore

if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
        IFS=',' read -r -a hosts <<< "$WORKER_HOSTS"
    else
        IFS=',' read -r -a hosts <<< "$WORKER_IPS"
    fi
    [[ ${#hosts[@]} -gt 0 ]] || error "No $ENROLLMENT_ROLE hosts were provided."
    [[ -z "$REQUESTED_WORKER_COUNT" || ${#hosts[@]} -eq "$REQUESTED_WORKER_COUNT" ]] || \
        error "The $ENROLLMENT_ROLE host list must contain exactly $REQUESTED_WORKER_COUNT entries."
    declare -A seen_hosts=()
    for host in "${hosts[@]}"; do
        host="${host#"${host%%[![:space:]]*}"}"
        host="${host%"${host##*[![:space:]]}"}"
        [[ -n "$host" ]] || error "$ENROLLMENT_ROLE host list contains an empty item."
        [[ -z "${seen_hosts[$host]:-}" ]] || error "Duplicate enrollment host: $host"
        seen_hosts["$host"]=1
        if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
            bootstrap_target="$(build_target "$host")"
            provision_tailscale_target "$bootstrap_target"
            target="$TAILSCALE_TARGET"
            host="$TAILSCALE_WORKER_IP"
            node_name="$TAILSCALE_NODE_NAME"
        else
            if ! trusted_private_ipv4 "$host" || tailscale_ipv4 "$host"; then
                error "vRack worker IP must be an RFC1918 IPv4 literal: $host"
            fi
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
        installer_prompt_section "$ENROLLMENT_ROLE $index of $worker_count" \
            "Configure this server's SSH bootstrap, private network, and Kubernetes identity."
        worker_host=""
        if [[ "$NODE_TRANSPORT" == "tailscale" ]]; then
            worker_ssh_user="$DEFAULT_WORKER_SSH_USER"
            worker_ssh_port="$DEFAULT_WORKER_SSH_PORT"
            worker_identity_file="$DEFAULT_WORKER_IDENTITY_FILE"
            installer_prompt_value worker_host "Existing server IP or DNS name reachable over SSH (bootstrap only)"
            [[ -n "$worker_host" ]] || error "A worker bootstrap SSH host is required."
            installer_prompt_value worker_ssh_user "SSH user for this server" "$worker_ssh_user"
            installer_prompt_value worker_ssh_port "SSH port for this server" "$worker_ssh_port"
            installer_prompt_value worker_identity_file "SSH private key for this server ('-' for agent/config)" "$worker_identity_file"
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
            installer_prompt_value requested_tailscale_name "Tailscale hostname for this server" "$detected_tailscale_name"
            provision_tailscale_target "$bootstrap_target" "$requested_tailscale_name"
            target="$TAILSCALE_TARGET"
            worker_host="$TAILSCALE_WORKER_IP"
            detected_name="$TAILSCALE_NODE_NAME"
        else
            worker_ssh_user="$DEFAULT_WORKER_SSH_USER"
            worker_ssh_port="$DEFAULT_WORKER_SSH_PORT"
            worker_identity_file="$DEFAULT_WORKER_IDENTITY_FILE"
            installer_prompt_value bootstrap_host "Existing OVHcloud server IP or DNS name reachable over SSH (bootstrap only)"
            [[ -n "$bootstrap_host" ]] || error "A worker bootstrap SSH host is required."
            installer_prompt_value worker_ssh_user "SSH user for this server" "$worker_ssh_user"
            installer_prompt_value worker_ssh_port "SSH port for this server" "$worker_ssh_port"
            installer_prompt_value worker_identity_file "SSH private key for this server ('-' for agent/config)" "$worker_identity_file"
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
                installer_prompt_value ovh_server "OVHcloud Dedicated Server service name for this $ENROLLMENT_ROLE"
            fi
            worker_host=""
            private_interface=""
            private_interface_mac=""
            vlan_id=""
            installer_prompt_value worker_host "Unique $ENROLLMENT_ROLE vRack RFC1918 address"
            if ! trusted_private_ipv4 "$worker_host" || tailscale_ipv4 "$worker_host"; then
                error "vRack worker IP must be an RFC1918 IPv4 literal: $worker_host"
            fi
            cidr_contains_ip "$NODE_NETWORK_CIDR" "$worker_host" || error "Worker IP $worker_host is outside $NODE_NETWORK_CIDR"
            printf 'Interfaces reported by %s:\n' "$bootstrap_target"
            ssh "${ssh_options[@]}" "$bootstrap_target" 'ip -br link show'
            installer_prompt_value private_interface "OVHcloud private NIC name (blank to match API-reported MAC)"
            installer_prompt_value private_interface_mac "Expected OVHcloud private NIC MAC (recommended if API attachment is disabled)"
            [[ -n "$private_interface" || -n "$private_interface_mac" || "$OVH_VRACK_AUTOMATE_ACCOUNT" == "true" ]] || \
                error "Provide the OVHcloud private NIC name or MAC."
            installer_prompt_value vlan_id "Optional vRack VLAN ID (blank for untagged VLAN 0)"
            provision_vrack_target "$bootstrap_target" "$worker_host" "$private_interface" "$private_interface_mac" "$vlan_id" "$ovh_server"
            target="$VRACK_TARGET"
        fi
        info "Checking SSH access to $target..."
        check_target "$target" "$worker_host"

        detected_name="${detected_name:-$(remote_hostname "$target")}"
        worker_name=""
        worker_labels=""
        worker_taints=""
        installer_prompt_value worker_name "Unique Kubernetes node name" "$detected_name"
        installer_prompt_value worker_labels "Node labels, comma-separated (optional)" "$COMMON_LABELS"
        installer_prompt_value worker_taints "Node taints, comma-separated (optional)" "$COMMON_TAINTS"
        install_worker "$target" "$worker_name" "$worker_host" "$worker_labels" "$worker_taints" "$TARGET_CONTROL_PLANE_IP"
    done
fi

if [[ "$ENROLLMENT_ROLE" == "control-plane" ]]; then
    final_control_planes="$(kubectl get nodes -o json | jq '[.items[] | select(.metadata.labels | has("node-role.kubernetes.io/control-plane") or has("node-role.kubernetes.io/master"))] | length')"
    (( final_control_planes % 2 == 1 )) || \
        error "Enrollment left $final_control_planes control planes; complete the remaining joins to restore an odd etcd membership."
    [[ "$final_control_planes" -eq "$EXPECTED_CONTROL_PLANE_COUNT" ]] || \
        error "Expected $EXPECTED_CONTROL_PLANE_COUNT control planes after enrollment, found $final_control_planes."
fi
if [[ "$DEFER_TOPOLOGY" != "true" ]]; then
    "$CLUSTER_TOPOLOGY_RECONCILER" \
        --control-plane-schedulable "$CONTROL_PLANE_SCHEDULABLE" \
        --update-longhorn-helm
fi

info "$ENROLLMENT_ROLE enrollment complete."
if [[ "$DEFER_TOPOLOGY" != true ]]; then
    access_args=(--node-network-cidr "$NODE_NETWORK_CIDR" --control-plane-ip "$CONTROL_PLANE_IP"
                 --ssh-user "$SSH_USER" --ssh-port "$SSH_PORT")
    [[ -z "$IDENTITY_FILE" ]] || access_args+=(--identity-file "$IDENTITY_FILE")
    "$CONTROL_PLANE_ACCESS_RECONCILER" "${access_args[@]}"
    ha_mode="$(kubectl -n infra get configmap bm-cluster-topology --ignore-not-found -o jsonpath='{.data.highAvailabilityEnabled}')"
    if [[ "$ha_mode" == true && "$ENROLLMENT_ROLE" == control-plane ]]; then
        HIGH_AVAILABILITY_ENABLED=true bash "$HA_CONTROL_PLANE_CONFIGURATOR" --reconcile "${access_args[@]}"
        "$SCRIPT_DIR/sync-vault-recovery.sh" --all-control-planes "${access_args[@]}"
    fi
fi
kubectl get nodes -o wide
