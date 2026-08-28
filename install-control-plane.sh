#!/bin/bash
# ==============================================================================
# install-control-plane.sh
# Installs the K3s control plane and deploys infrastructure components
# ==============================================================================
set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_CONFIG="$SCRIPT_DIR/config/platform.env"
if [[ ! -r "$PLATFORM_CONFIG" ]]; then
    echo "[ERROR] Shared platform contract not found: $PLATFORM_CONFIG" >&2
    exit 1
fi
# shellcheck source=config/platform.env
source "$PLATFORM_CONFIG"
NETWORK_LIBRARY="$SCRIPT_DIR/scripts/lib/network.sh"
if [[ ! -r "$NETWORK_LIBRARY" ]]; then
    echo "[ERROR] Shared network library not found: $NETWORK_LIBRARY" >&2
    exit 1
fi
# shellcheck source=scripts/lib/network.sh
source "$NETWORK_LIBRARY"
TRANSPORT_GUIDE_LIBRARY="$SCRIPT_DIR/scripts/lib/transport-guide.sh"
if [[ ! -r "$TRANSPORT_GUIDE_LIBRARY" ]]; then
    echo "[ERROR] Shared transport guide not found: $TRANSPORT_GUIDE_LIBRARY" >&2
    exit 1
fi
# shellcheck source=scripts/lib/transport-guide.sh
source "$TRANSPORT_GUIDE_LIBRARY"

K8S_DIR="$SCRIPT_DIR/k8s"
VAULT_BOOTSTRAP_SCRIPT="$SCRIPT_DIR/scripts/configure-vault.sh"
SECURITY_HARDEN_SCRIPT="$SCRIPT_DIR/scripts/configure-node-security.sh"
CLOUDFLARE_SCRIPT="$SCRIPT_DIR/scripts/configure-cloudflare.sh"
WORKER_INSTALLER_SCRIPT="$SCRIPT_DIR/install-worker.sh"
K3S_BACKUP_SCRIPT="$SCRIPT_DIR/scripts/configure-k3s-backups.sh"
NEXUS_REGISTRY_SCRIPT="$SCRIPT_DIR/scripts/configure-nexus-registry.sh"
K3S_REGISTRY_MIRROR_SCRIPT="$SCRIPT_DIR/scripts/configure-k3s-registry-mirror.sh"
K3S_APPARMOR_SCRIPT="$SCRIPT_DIR/scripts/configure-k3s-apparmor.sh"
LONGHORN_HOST_SCRIPT="$SCRIPT_DIR/scripts/configure-longhorn-host.sh"
K3S_NETWORK_SCRIPT="$SCRIPT_DIR/scripts/configure-k3s-control-plane-network.sh"
TAILSCALE_SCRIPT="$SCRIPT_DIR/scripts/configure-tailscale.sh"
OVH_VRACK_SCRIPT="$SCRIPT_DIR/scripts/configure-ovh-vrack.sh"
AUTO_APPROVE=false
INSTALL_SCOPE="${INSTALL_SCOPE:-apps}"
SERVER_EXPOSURE="${SERVER_EXPOSURE:-internet}"
K3S_NODE_TRANSPORT="${K3S_NODE_TRANSPORT:-}"
TAILSCALE_API_TOKEN="${TAILSCALE_API_TOKEN:-}"
TAILSCALE_TAILNET="${TAILSCALE_TAILNET:-$DEFAULT_TAILSCALE_TAILNET}"
TAILSCALE_MESH_NAME="${TAILSCALE_MESH_NAME:-$DEFAULT_TAILSCALE_MESH_NAME}"
TAILSCALE_NODE_HOSTNAME="${TAILSCALE_NODE_HOSTNAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
TAILSCALE_AUTH_KEY_EXPIRY_SECONDS="${TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-$DEFAULT_TAILSCALE_AUTH_KEY_EXPIRY_SECONDS}"
OVH_VRACK_AUTOMATE_ACCOUNT="${OVH_VRACK_AUTOMATE_ACCOUNT:-}"
OVH_API_ENDPOINT="${OVH_API_ENDPOINT:-ovh-eu}"
OVH_APPLICATION_KEY="${OVH_APPLICATION_KEY:-}"
OVH_APPLICATION_SECRET="${OVH_APPLICATION_SECRET:-}"
OVH_CONSUMER_KEY="${OVH_CONSUMER_KEY:-}"
OVH_VRACK_SERVICE_NAME="${OVH_VRACK_SERVICE_NAME:-}"
OVH_CONTROL_PLANE_SERVICE_NAME="${OVH_CONTROL_PLANE_SERVICE_NAME:-}"
INSTALLER_TEMP_DIR=""
nodesource_installer=""
k3s_installer=""
helm_installer=""
K3S_INSTALL_VERSION="${K3S_INSTALL_VERSION:-$DEFAULT_K3S_INSTALL_VERSION}"
K3S_REGISTRY_HOST="${K3S_REGISTRY_HOST:-$DEFAULT_K3S_REGISTRY_HOST}"
K3S_REGISTRY_ENDPOINT="${K3S_REGISTRY_ENDPOINT:-$DEFAULT_K3S_REGISTRY_ENDPOINT}"
INGRESS_NGINX_CHART_VERSION="${INGRESS_NGINX_CHART_VERSION:-$DEFAULT_INGRESS_NGINX_CHART_VERSION}"
LONGHORN_CHART_VERSION="${LONGHORN_CHART_VERSION:-$DEFAULT_LONGHORN_CHART_VERSION}"
VAULT_CHART_VERSION="${VAULT_CHART_VERSION:-$DEFAULT_VAULT_CHART_VERSION}"
EXTERNAL_SECRETS_CHART_VERSION="${EXTERNAL_SECRETS_CHART_VERSION:-$DEFAULT_EXTERNAL_SECRETS_CHART_VERSION}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-$DEFAULT_ARGOCD_CHART_VERSION}"
ARGOCD_IMAGE_TAG="${ARGOCD_IMAGE_TAG:-$DEFAULT_ARGOCD_IMAGE_TAG}"
LONGHORN_HELM_TIMEOUT="${LONGHORN_HELM_TIMEOUT:-$DEFAULT_LONGHORN_HELM_TIMEOUT}"
LONGHORN_POD_WAIT_TIMEOUT="${LONGHORN_POD_WAIT_TIMEOUT:-$DEFAULT_LONGHORN_POD_WAIT_TIMEOUT}"
INGRESS_HELM_TIMEOUT="${INGRESS_HELM_TIMEOUT:-$DEFAULT_INGRESS_HELM_TIMEOUT}"
VAULT_WAIT_TIMEOUT="${VAULT_WAIT_TIMEOUT:-$DEFAULT_VAULT_WAIT_TIMEOUT}"
EXTERNAL_SECRETS_HELM_TIMEOUT="${EXTERNAL_SECRETS_HELM_TIMEOUT:-$DEFAULT_EXTERNAL_SECRETS_HELM_TIMEOUT}"
EXTERNAL_SECRET_WAIT_TIMEOUT="${EXTERNAL_SECRET_WAIT_TIMEOUT:-$DEFAULT_EXTERNAL_SECRET_WAIT_TIMEOUT}"
ARGOCD_HELM_TIMEOUT="${ARGOCD_HELM_TIMEOUT:-$DEFAULT_ARGOCD_HELM_TIMEOUT}"
DATASTORE_WAIT_TIMEOUT="${DATASTORE_WAIT_TIMEOUT:-$DEFAULT_DATASTORE_WAIT_TIMEOUT}"
PLATFORM_WAIT_TIMEOUT="${PLATFORM_WAIT_TIMEOUT:-$DEFAULT_PLATFORM_WAIT_TIMEOUT}"
NEXUS_WAIT_TIMEOUT="${NEXUS_WAIT_TIMEOUT:-$DEFAULT_NEXUS_WAIT_TIMEOUT}"
POST_DEPLOY_JOB_WAIT_TIMEOUT="${POST_DEPLOY_JOB_WAIT_TIMEOUT:-$DEFAULT_POST_DEPLOY_JOB_WAIT_TIMEOUT}"
CLOUDFLARE_ZONE="${CLOUDFLARE_ZONE:-$DEFAULT_CLOUDFLARE_ZONE}"

IFS=',' read -r -a FOUNDATION_MANIFEST_ARRAY <<< "$FOUNDATION_MANIFESTS"
IFS=',' read -r -a DATASTORE_MANIFEST_ARRAY <<< "$DATASTORE_MANIFESTS"
IFS=',' read -r -a PLATFORM_MANIFEST_ARRAY <<< "$PLATFORM_MANIFESTS"
IFS=',' read -r -a POST_DEPLOY_CREATE_MANIFEST_ARRAY <<< "$POST_DEPLOY_CREATE_MANIFESTS"
IFS=',' read -r -a EXTERNAL_SECRET_NAME_ARRAY <<< "$EXTERNAL_SECRET_NAMES"
IFS=',' read -r -a DATASTORE_WAIT_APP_ARRAY <<< "$DATASTORE_WAIT_APPS"
IFS=',' read -r -a PLATFORM_WAIT_APP_ARRAY <<< "$PLATFORM_WAIT_APPS"
IFS=',' read -r -a PLATFORM_WAIT_DAEMONSET_ARRAY <<< "$PLATFORM_WAIT_DAEMONSETS"

for arg in "$@"; do
    case "$arg" in
        -y|--yes|--auto-approve)
            AUTO_APPROVE=true
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: $0 [--yes]"
            exit 1
            ;;
    esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

ask_with_default() {
    local prompt="$1"
    local default_choice="${2:-N}"
    local answer="" suffix=""

    if [[ "$default_choice" == "Y" ]]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    if [[ "$AUTO_APPROVE" == "true" ]]; then
        [[ "$default_choice" == "Y" ]]
        return
    fi

    read -rp "$(echo -e "${YELLOW}$prompt $suffix${NC} ")" answer
    answer="${answer:-$default_choice}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

ask_server_exposure() {
    local default_exposure raw_answer normalized
    default_exposure="$(normalize_server_exposure "$1")" || error "Invalid SERVER_EXPOSURE value: $1"

    if [[ "$AUTO_APPROVE" == "true" ]]; then
        echo "$default_exposure"
        return 0
    fi

    while true; do
        read -rp "$(echo -e "${YELLOW}Will this server be internet-exposed or local-only? [internet/local]${NC} ")" raw_answer
        raw_answer="${raw_answer:-$default_exposure}"
        if normalized="$(normalize_server_exposure "$raw_answer")"; then
            echo "$normalized"
            return 0
        fi
        warn "Please answer 'internet' or 'local'."
    done
}

normalize_install_scope() {
    case "${1,,}" in
        1|infra|infrastructure|infra-only)
            printf 'infra\n'
            ;;
        2|apps|all|infra+apps)
            printf 'apps\n'
            ;;
        *)
            return 1
            ;;
    esac
}

select_install_scope() {
    local default_scope raw_answer normalized
    default_scope="$(normalize_install_scope "$1")" || error "INSTALL_SCOPE must be infra or apps."

    if [[ "$AUTO_APPROVE" == "true" ]]; then
        printf '%s\n' "$default_scope"
        return 0
    fi

    printf '%s\n' \
        "Select the deployment scope:" \
        "  1) infra only" \
        "  2) infra + apps" \
        "     - Odoo (ERP/CRM)" >&2
    while true; do
        read -rp "Select 1 or 2 [$([[ "$default_scope" == "infra" ]] && printf 1 || printf 2)]: " raw_answer
        raw_answer="${raw_answer:-$default_scope}"
        if normalized="$(normalize_install_scope "$raw_answer")"; then
            printf '%s\n' "$normalized"
            return 0
        fi
        warn "Enter 1 for infra only or 2 for infra + apps." >&2
    done
}

select_node_transport() {
    local default_transport raw_answer normalized
    default_transport="$(normalize_node_transport "${DEFAULT_K3S_NODE_TRANSPORT:-vrack}")" || default_transport=vrack

    if [[ -n "$K3S_NODE_TRANSPORT" ]]; then
        normalize_node_transport "$K3S_NODE_TRANSPORT" || error "K3S_NODE_TRANSPORT must be vrack or tailscale."
        return
    fi
    if [[ "$AUTO_APPROVE" == "true" ]]; then
        if [[ -n "${K3S_WORKER_HOSTS:-}" ]]; then
            printf 'tailscale\n'
        elif [[ -n "${K3S_WORKER_IPS:-}" ]]; then
            printf 'vrack\n'
        else
            error "Set K3S_NODE_TRANSPORT=vrack|tailscale when adding workers non-interactively."
        fi
        return
    fi

    printf '%s\n' \
        "Select the private node transport:" \
        "  1) OVHcloud vRack (OVHcloud-only)" \
        "  2) Tailscale (hybrid cloud or non-OVHcloud providers)" >&2
    while true; do
        read -rp "Select 1 or 2 [$([[ "$default_transport" == "vrack" ]] && printf 1 || printf 2)]: " raw_answer
        raw_answer="${raw_answer:-$default_transport}"
        if normalized="$(normalize_node_transport "$raw_answer")"; then
            printf '%s\n' "$normalized"
            return
        fi
        case "$raw_answer" in
            1) printf 'vrack\n'; return ;;
            2) printf 'tailscale\n'; return ;;
        esac
        warn "Enter 1 for vRack or 2 for Tailscale."
    done
}

cleanup_private_credentials() {
    TAILSCALE_API_TOKEN=""
    OVH_APPLICATION_KEY=""
    OVH_APPLICATION_SECRET=""
    OVH_CONSUMER_KEY=""
    unset TAILSCALE_API_TOKEN OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY 2>/dev/null || true
    if [[ -n "$INSTALLER_TEMP_DIR" && "$INSTALLER_TEMP_DIR" == /tmp/bm-cluster-installers.* && -d "$INSTALLER_TEMP_DIR" ]]; then
        rm -r -- "$INSTALLER_TEMP_DIR"
    fi
}
trap cleanup_private_credentials EXIT HUP INT TERM

download_installer() {
    local url="$1" filename="$2" destination_variable="$3" destination
    [[ "$url" == https://* ]] || error "Installer URL must use HTTPS: $url"
    [[ "$filename" =~ ^[A-Za-z0-9._-]+$ ]] || error "Invalid installer filename: $filename"
    if [[ -z "$INSTALLER_TEMP_DIR" ]]; then
        INSTALLER_TEMP_DIR="$(mktemp -d /tmp/bm-cluster-installers.XXXXXX)"
        chmod 700 "$INSTALLER_TEMP_DIR"
    fi
    destination="$INSTALLER_TEMP_DIR/$filename"
    curl --fail --location --silent --show-error \
        --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors \
        --connect-timeout 15 --max-time 180 \
        --output "$destination" "$url"
    chmod 700 "$destination"
    printf -v "$destination_variable" '%s' "$destination"
}

ensure_tls_secret() {
    local namespace="$1"
    local secret_name="$2"
    shift 2
    local domains=("$@")

    if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
        warn "TLS secret '$secret_name' already exists in namespace '$namespace', reusing it."
        return 0
    fi

    local tmpdir openssl_config cert key
    tmpdir="$(mktemp -d)"
    openssl_config="$tmpdir/openssl.cnf"
    cert="$tmpdir/tls.crt"
    key="$tmpdir/tls.key"

    {
        echo "[req]"
        echo "distinguished_name = req_distinguished_name"
        echo "x509_extensions = v3_req"
        echo "prompt = no"
        echo ""
        echo "[req_distinguished_name]"
        echo "CN = ${domains[0]}"
        echo ""
        echo "[v3_req]"
        echo "subjectAltName = @alt_names"
        echo ""
        echo "[alt_names]"
        local i=1
        for domain in "${domains[@]}"; do
            echo "DNS.$i = $domain"
            i=$((i + 1))
        done
    } > "$openssl_config"

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$key" \
        -out "$cert" \
        -config "$openssl_config" >/dev/null 2>&1

    kubectl create secret tls "$secret_name" \
        --cert="$cert" \
        --key="$key" \
        -n "$namespace" >/dev/null

    rm -rf "$tmpdir"
    info "Created TLS secret '$secret_name' in namespace '$namespace'."
}

# ---------- Combined pre-flight checks -----------------------------------------
[[ $EUID -eq 0 ]] && error "Do not run as root. The script uses sudo when needed."

info "============================================="
info " Control Plane Installer"
info "============================================="
echo ""
echo "This script will:"
echo "  - Prompt you for each install feature group one by one"
echo "  - Install only selected components"
echo "  - Apply UFW everywhere and add intrusion prevention only when internet-exposed"
echo ""

ask_with_default "Proceed with installation and deployment?" "Y" || { info "Aborted."; exit 0; }

step "Select features to install (answer each prompt)"
SERVER_EXPOSURE="$(ask_server_exposure "$SERVER_EXPOSURE")"
if [[ "$SERVER_EXPOSURE" == "internet" ]]; then
    info "Internet-exposed mode selected: enabling UFW, Fail2ban, CrowdSec, and control-plane Lynis."
else
    info "Local-only mode selected: enabling UFW and control-plane Lynis; skipping Fail2ban and CrowdSec."
fi
INSTALL_SCOPE="$(select_install_scope "$INSTALL_SCOPE")"
if [[ "$INSTALL_SCOPE" == "apps" ]]; then
    INSTALL_APPS=true
    DEPLOY_ODOO=true
    info "Infrastructure and apps selected: deploying Odoo."
else
    INSTALL_APPS=false
    DEPLOY_ODOO=false
    info "Infrastructure-only installation selected."
fi

if command -v k3s &>/dev/null; then
    warn "K3s detected: $(k3s --version | head -1)"
    K3S_DEFAULT="N"
else
    K3S_DEFAULT="Y"
fi

ask_with_default "Install/upgrade system prerequisites (Java/Maven/Docker/Ansible/Node/etc.)?" "Y" && INSTALL_PREREQS=true || INSTALL_PREREQS=false
ask_with_default "Install or reinstall K3s control plane?" "$K3S_DEFAULT" && INSTALL_K3S=true || INSTALL_K3S=false
if [[ "$AUTO_APPROVE" == "true" ]]; then
    [[ -n "${K3S_WORKER_IPS:-}${K3S_WORKER_HOSTS:-}" ]] && ADD_K3S_WORKERS=true || ADD_K3S_WORKERS=false
else
    ask_with_default "Add or reconcile K3s worker nodes over SSH?" "N" && ADD_K3S_WORKERS=true || ADD_K3S_WORKERS=false
fi
if [[ "$ADD_K3S_WORKERS" == "true" ]]; then
    K3S_NODE_TRANSPORT="$(select_node_transport)"
    export K3S_NODE_TRANSPORT
    if [[ "$K3S_NODE_TRANSPORT" == "tailscale" ]]; then
        [[ -x "$TAILSCALE_SCRIPT" ]] || error "Tailscale configurator not found or not executable: $TAILSCALE_SCRIPT"
        transport_guide_tailscale_account "$AUTO_APPROVE" "$TAILSCALE_SCRIPT" || \
            error "Tailscale prerequisites are incomplete or account verification failed."
        step "Reconciling the tailnet policy and control-plane role..."
        K3S_PRIVATE_ADDRESS="$(printf '%s\n' "$TAILSCALE_API_TOKEN" | \
            "$TAILSCALE_SCRIPT" --role control-plane \
                --tailnet "$TAILSCALE_TAILNET" \
                --mesh-name "$TAILSCALE_MESH_NAME" \
                --hostname "$TAILSCALE_NODE_HOSTNAME" \
                --auth-key-expiry "$TAILSCALE_AUTH_KEY_EXPIRY_SECONDS" \
                --api-token-stdin)"
        K3S_PRIVATE_INTERFACE=tailscale0
        K3S_NODE_NETWORK_CIDR=100.64.0.0/10
        export K3S_PRIVATE_ADDRESS K3S_PRIVATE_INTERFACE K3S_NODE_NETWORK_CIDR
        TAILSCALE_CONFIG_PREPARED=true
        export TAILSCALE_TAILNET TAILSCALE_MESH_NAME TAILSCALE_NODE_HOSTNAME TAILSCALE_AUTH_KEY_EXPIRY_SECONDS TAILSCALE_CONFIG_PREPARED
    else
        [[ -x "$OVH_VRACK_SCRIPT" ]] || error "OVHcloud vRack configurator not found or not executable: $OVH_VRACK_SCRIPT"
        transport_guide_vrack_account "$AUTO_APPROVE" "$OVH_VRACK_SCRIPT" || \
            error "OVHcloud vRack prerequisites are incomplete or account verification failed."
        if [[ "$OVH_VRACK_AUTOMATE_ACCOUNT" == "true" ]]; then
            if [[ "$AUTO_APPROVE" != "true" ]]; then
                read -rp "$(echo -e "${YELLOW}This control plane's OVHcloud Dedicated Server service name [${OVH_CONTROL_PLANE_SERVICE_NAME}]:${NC} ")" ovh_answer
                OVH_CONTROL_PLANE_SERVICE_NAME="${ovh_answer:-$OVH_CONTROL_PLANE_SERVICE_NAME}"
            fi
            [[ -n "$OVH_VRACK_SERVICE_NAME" && -n "$OVH_CONTROL_PLANE_SERVICE_NAME" ]] || \
                error "OVH_VRACK_SERVICE_NAME and OVH_CONTROL_PLANE_SERVICE_NAME are required for API attachment."
            export OVH_API_ENDPOINT OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY OVH_VRACK_SERVICE_NAME
            step "Attaching the control-plane private interface to OVHcloud vRack $OVH_VRACK_SERVICE_NAME..."
            detected_vrack_mac="$("$OVH_VRACK_SCRIPT" --attach-server "$OVH_CONTROL_PLANE_SERVICE_NAME" \
                --vrack "$OVH_VRACK_SERVICE_NAME" --ovh-endpoint "$OVH_API_ENDPOINT" --non-interactive)"
            if [[ "${detected_vrack_mac,,}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ && -z "${K3S_PRIVATE_INTERFACE_MAC:-}" ]]; then
                K3S_PRIVATE_INTERFACE_MAC="$detected_vrack_mac"
            fi
        else
            warn "OVHcloud account attachment is manual: the existing vRack and every server must be attached in Control Panel before host configuration."
        fi
        OVH_VRACK_CONFIG_PREPARED=true
        export OVH_VRACK_AUTOMATE_ACCOUNT OVH_VRACK_CONFIG_PREPARED
        if [[ -z "${K3S_PRIVATE_ADDRESS:-}" ]]; then
            if [[ "$AUTO_APPROVE" == "true" ]]; then
                error "K3S_PRIVATE_ADDRESS is required with vRack workers."
            fi
            read -rp "$(echo -e "${YELLOW}Control-plane vRack/private RFC1918 IPv4:${NC} ")" K3S_PRIVATE_ADDRESS
            [[ -n "$K3S_PRIVATE_ADDRESS" ]] || error "A control-plane vRack/private IPv4 address is required."
            export K3S_PRIVATE_ADDRESS
        fi
        if ! trusted_private_ipv4 "$K3S_PRIVATE_ADDRESS" || tailscale_ipv4 "$K3S_PRIVATE_ADDRESS"; then
            error "vRack transport requires this control plane's RFC1918 IPv4 address."
        fi
        if [[ -z "${K3S_NODE_NETWORK_CIDR:-}" ]]; then
            if [[ "$AUTO_APPROVE" == "true" ]]; then
                error "K3S_NODE_NETWORK_CIDR is required with vRack workers."
            fi
            read -rp "$(echo -e "${YELLOW}Trusted vRack/private node CIDR (for example 10.50.0.0/24):${NC} ")" K3S_NODE_NETWORK_CIDR
            [[ -n "$K3S_NODE_NETWORK_CIDR" ]] || error "A trusted vRack/private node CIDR is required."
            export K3S_NODE_NETWORK_CIDR
        fi
        existing_vrack_interface="$(interface_owning_ip "$K3S_PRIVATE_ADDRESS")"
        if [[ -z "$existing_vrack_interface" && "$AUTO_APPROVE" != "true" ]]; then
            ip -br link show
            read -rp "$(echo -e "${YELLOW}Control-plane OVHcloud private/vRack NIC name:${NC} ")" K3S_PRIVATE_INTERFACE
            read -rp "$(echo -e "${YELLOW}Expected private NIC MAC (recommended) [${K3S_PRIVATE_INTERFACE_MAC:-}]:${NC} ")" ovh_answer
            K3S_PRIVATE_INTERFACE_MAC="${ovh_answer:-${K3S_PRIVATE_INTERFACE_MAC:-}}"
            read -rp "$(echo -e "${YELLOW}Optional vRack VLAN ID (blank for untagged VLAN 0):${NC} ")" K3S_VRACK_VLAN_ID
        fi
        vrack_node_args=(
            --configure-node
            --private-ip "$K3S_PRIVATE_ADDRESS"
            --network-cidr "$K3S_NODE_NETWORK_CIDR"
        )
        [[ -z "${K3S_PRIVATE_INTERFACE:-}" ]] || vrack_node_args+=(--interface "$K3S_PRIVATE_INTERFACE")
        [[ -z "${K3S_PRIVATE_INTERFACE_MAC:-}" ]] || vrack_node_args+=(--interface-mac "$K3S_PRIVATE_INTERFACE_MAC")
        [[ -z "${K3S_VRACK_VLAN_ID:-}" ]] || vrack_node_args+=(--vlan-id "$K3S_VRACK_VLAN_ID")
        [[ "$AUTO_APPROVE" != "true" ]] || vrack_node_args+=(--non-interactive)
        step "Configuring and validating the control-plane OVHcloud vRack interface before any firewall changes..."
        K3S_PRIVATE_INTERFACE="$("$OVH_VRACK_SCRIPT" "${vrack_node_args[@]}")"
        export K3S_PRIVATE_INTERFACE K3S_PRIVATE_INTERFACE_MAC K3S_VRACK_VLAN_ID
    fi
fi
ask_with_default "Install/upgrade Longhorn and make it default storage class?" "Y" && INSTALL_LONGHORN=true || INSTALL_LONGHORN=false
ask_with_default "Install/upgrade NGINX ingress controller?" "Y" && INSTALL_INGRESS=true || INSTALL_INGRESS=false
if [[ "$SERVER_EXPOSURE" == "internet" ]]; then
    ask_with_default "Configure Cloudflare public DNS and Origin TLS?" "Y" && CONFIGURE_CLOUDFLARE=true || CONFIGURE_CLOUDFLARE=false
else
    CONFIGURE_CLOUDFLARE=false
fi
ask_with_default "Install/upgrade Vault + External Secrets and bootstrap secrets?" "Y" && INSTALL_VAULT_STACK=true || INSTALL_VAULT_STACK=false
ask_with_default "Deploy/upgrade core data stores (Postgres, Kafka, Redis, MongoDB)?" "Y" && DEPLOY_DATA_STORES=true || DEPLOY_DATA_STORES=false
ask_with_default "Deploy/upgrade platform services from the shared inventory?" "Y" && DEPLOY_PLATFORM_SERVICES=true || DEPLOY_PLATFORM_SERVICES=false
ask_with_default "Install/upgrade Descheduler addon resources (manual trigger only)?" "Y" && INSTALL_DESCHEDULER=true || INSTALL_DESCHEDULER=false
ask_with_default "Install/upgrade ArgoCD?" "Y" && INSTALL_ARGOCD=true || INSTALL_ARGOCD=false

if [[ "$DEPLOY_PLATFORM_SERVICES" == "true" && "$DEPLOY_DATA_STORES" != "true" ]]; then
    warn "Platform services depend on data stores; enabling data store deployment."
    DEPLOY_DATA_STORES=true
fi

if [[ "$DEPLOY_ODOO" == "true" && "$DEPLOY_DATA_STORES" != "true" ]]; then
    warn "Odoo depends on PostgreSQL; enabling data store deployment."
    DEPLOY_DATA_STORES=true
fi

if [[ "$DEPLOY_DATA_STORES" == "true" && "$INSTALL_VAULT_STACK" != "true" ]]; then
    warn "Data stores require Vault-synced secrets; enabling Vault + External Secrets install."
    INSTALL_VAULT_STACK=true
fi

if [[ "$CONFIGURE_CLOUDFLARE" == "true" && "$INSTALL_INGRESS" != "true" ]]; then
    warn "Cloudflare publishing requires NGINX ingress; enabling ingress installation."
    INSTALL_INGRESS=true
fi

RUN_K8S_FEATURES=false
if [[ "$INSTALL_K3S" == "true" || "$ADD_K3S_WORKERS" == "true" || "$INSTALL_LONGHORN" == "true" || "$INSTALL_INGRESS" == "true" || "$CONFIGURE_CLOUDFLARE" == "true" || "$INSTALL_VAULT_STACK" == "true" || "$DEPLOY_DATA_STORES" == "true" || "$DEPLOY_PLATFORM_SERVICES" == "true" || "$DEPLOY_ODOO" == "true" || "$INSTALL_DESCHEDULER" == "true" || "$INSTALL_ARGOCD" == "true" ]]; then
    RUN_K8S_FEATURES=true
fi

NEEDS_HELM=false
if [[ "$INSTALL_LONGHORN" == "true" || "$INSTALL_INGRESS" == "true" || "$INSTALL_VAULT_STACK" == "true" || "$INSTALL_ARGOCD" == "true" ]]; then
    NEEDS_HELM=true
fi

# ---------- Prerequisites section ----------------------------------------------
if [[ "$INSTALL_PREREQS" == "true" ]]; then
    step "Installing system prerequisites..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        openjdk-21-jdk \
        maven \
        docker.io \
        ansible \
        open-iscsi \
        nfs-common \
        curl \
        jq \
        git \
        openssl \
        > /dev/null

    if ! command -v node &>/dev/null || [[ "$(node -v)" != v24* ]]; then
        info "Installing Node.js 24..."
        download_installer https://deb.nodesource.com/setup_24.x nodesource-24.sh nodesource_installer
        sudo -E bash "$nodesource_installer" > /dev/null 2>&1
        sudo apt-get install -y -qq nodejs > /dev/null
    fi

    if ! groups "$USER" | grep -q docker; then
        info "Adding $USER to docker group (re-login required for non-sudo docker)..."
        sudo usermod -aG docker "$USER"
    fi

    sudo systemctl enable --now iscsid > /dev/null 2>&1

    export MAVEN_OPTS="-Dhttp.proxyHost= -Dhttps.proxyHost="
    grep -q "MAVEN_OPTS" ~/.bashrc 2>/dev/null || \
        echo 'export MAVEN_OPTS="-Dhttp.proxyHost= -Dhttps.proxyHost="' >> ~/.bashrc
else
    warn "Skipping system prerequisites."
fi

if [[ "$RUN_K8S_FEATURES" == "true" ]]; then
    if [[ "$ADD_K3S_WORKERS" == "true" ]]; then
        [[ -x "$K3S_NETWORK_SCRIPT" ]] || error "K3s private-network configurator not found or not executable: $K3S_NETWORK_SCRIPT"
        network_args=()
        [[ -z "${K3S_PRIVATE_ADDRESS:-}" ]] || network_args+=(--private-ip "$K3S_PRIVATE_ADDRESS")
        [[ -z "${K3S_PRIVATE_INTERFACE:-}" ]] || network_args+=(--private-interface "$K3S_PRIVATE_INTERFACE")
        [[ -z "${K3S_PUBLIC_ADDRESS:-}" ]] || network_args+=(--public-ip "$K3S_PUBLIC_ADDRESS")
        if [[ "$INSTALL_K3S" != "true" ]] && systemctl cat k3s.service >/dev/null 2>&1; then
            network_args+=(--restart)
        fi
        step "Configuring private K3s control-plane networking..."
        "$K3S_NETWORK_SCRIPT" "${network_args[@]}"
    fi

    if [[ "$INSTALL_K3S" == "true" ]]; then
        info "Installing K3s (disabling Traefik, using Nginx Ingress instead)..."
        download_installer https://get.k3s.io k3s-install.sh k3s_installer
        sudo env INSTALL_K3S_VERSION="$K3S_INSTALL_VERSION" sh "$k3s_installer" \
            --disable traefik \
            --secrets-encryption \
            --write-kubeconfig-mode 600
    fi

    if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
        umask 077
        mkdir -p ~/.kube
        chmod 700 ~/.kube
        sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
        sudo chown "$USER":"$USER" ~/.kube/config
        chmod 600 ~/.kube/config

        [[ -x "$K3S_REGISTRY_MIRROR_SCRIPT" ]] || \
            error "K3s registry mirror configurator is not executable: $K3S_REGISTRY_MIRROR_SCRIPT"
        K3S_REGISTRY_HOST="$K3S_REGISTRY_HOST" K3S_REGISTRY_ENDPOINT="$K3S_REGISTRY_ENDPOINT" \
            "$K3S_REGISTRY_MIRROR_SCRIPT"
    fi
    export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
    grep -q "KUBECONFIG" ~/.bashrc 2>/dev/null || \
        echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
fi

if command -v k3s >/dev/null 2>&1; then
    [[ -x "$K3S_APPARMOR_SCRIPT" ]] || error "K3s AppArmor configurator is not executable: $K3S_APPARMOR_SCRIPT"
    step "Configuring the enforced K3s AppArmor runtime profile..."
    "$K3S_APPARMOR_SCRIPT"

    [[ -x "$K3S_BACKUP_SCRIPT" ]] || error "K3s backup configurator is not executable: $K3S_BACKUP_SCRIPT"
    step "Configuring daily consistent K3s recovery archives..."
    "$K3S_BACKUP_SCRIPT"
fi

if [[ "$INSTALL_LONGHORN" == "true" ]]; then
    [[ -x "$LONGHORN_HOST_SCRIPT" ]] || error "Longhorn host configurator is not executable: $LONGHORN_HOST_SCRIPT"
    step "Configuring Longhorn host storage prerequisites..."
    "$LONGHORN_HOST_SCRIPT"
fi

if [[ "$NEEDS_HELM" == "true" ]] && ! command -v helm &>/dev/null; then
    info "Installing Helm 3..."
    download_installer https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 helm-install.sh helm_installer
    bash "$helm_installer" > /dev/null 2>&1
fi

if [[ -x "$SECURITY_HARDEN_SCRIPT" ]]; then
    step "Applying the $SERVER_EXPOSURE control-plane host security policy..."
    "$SECURITY_HARDEN_SCRIPT" --apply --server-exposure "$SERVER_EXPOSURE" --node-role control-plane
else
    warn "Host security script not found at $SECURITY_HARDEN_SCRIPT"
fi

# ---------- Infrastructure section ---------------------------------------------
if [[ "$RUN_K8S_FEATURES" == "true" ]]; then
    command -v kubectl &>/dev/null || error "kubectl not found."
    command -v openssl &>/dev/null || error "openssl not found."
    kubectl cluster-info &>/dev/null || error "Cannot reach K8s cluster."
    [[ "$NEEDS_HELM" != "true" ]] || command -v helm &>/dev/null || error "helm not found."

    mapfile -t control_plane_nodes < <(kubectl get nodes \
        -l node-role.kubernetes.io/control-plane -o name)
    [[ ${#control_plane_nodes[@]} -gt 0 ]] || error "No control-plane node was found."
    kubectl label "${control_plane_nodes[@]}" \
        svccontroller.k3s.cattle.io/enablelb=true \
        node.swirlit.dev/role=control-plane \
        "node.swirlit.dev/exposure=$SERVER_EXPOSURE" \
        --overwrite >/dev/null

    if [[ "$INSTALL_K3S" == "true" ]]; then
        kubectl wait --for=condition=Ready node --all --timeout=120s
    fi

    if [[ "$ADD_K3S_WORKERS" == "true" ]]; then
        [[ -x "$WORKER_INSTALLER_SCRIPT" ]] || error "Worker installer not found or not executable at $WORKER_INSTALLER_SCRIPT"
        worker_manager_args=()
        worker_ip_list="${K3S_WORKER_IPS:-}"
        [[ -z "$worker_ip_list" ]] || worker_manager_args+=(--worker-ips "$worker_ip_list")
        worker_host_list="${K3S_WORKER_HOSTS:-}"
        [[ -z "$worker_host_list" ]] || worker_manager_args+=(--worker-hosts "$worker_host_list")
        worker_manager_args+=(--transport "$K3S_NODE_TRANSPORT")
        worker_server_url="${K3S_SERVER_URL:-https://${K3S_PRIVATE_ADDRESS}:6443}"
        worker_manager_args+=(--server-url "$worker_server_url")
        [[ -z "${K3S_WORKER_SSH_USER:-}" ]] || worker_manager_args+=(--ssh-user "$K3S_WORKER_SSH_USER")
        [[ -z "${K3S_WORKER_SSH_PORT:-}" ]] || worker_manager_args+=(--ssh-port "$K3S_WORKER_SSH_PORT")
        [[ -z "${K3S_WORKER_IDENTITY_FILE:-}" ]] || worker_manager_args+=(--identity-file "$K3S_WORKER_IDENTITY_FILE")
        [[ -z "${K3S_NODE_NETWORK_CIDR:-}" ]] || worker_manager_args+=(--node-network-cidr "$K3S_NODE_NETWORK_CIDR")
        [[ -z "${K3S_WORKER_LABELS:-}" ]] || worker_manager_args+=(--labels "$K3S_WORKER_LABELS")
        [[ -z "${K3S_WORKER_TAINTS:-}" ]] || worker_manager_args+=(--taints "$K3S_WORKER_TAINTS")
        step "Adding K3s worker nodes..."
        if [[ "$K3S_NODE_TRANSPORT" == "tailscale" ]]; then
            printf '%s\n' "$TAILSCALE_API_TOKEN" | \
                "$WORKER_INSTALLER_SCRIPT" --control-plane --tailscale-api-token-stdin "${worker_manager_args[@]}"
        else
            "$WORKER_INSTALLER_SCRIPT" --control-plane "${worker_manager_args[@]}"
        fi
    fi

    step "Creating infra namespace..."
    kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    if [[ "$INSTALL_APPS" == "true" ]]; then
        step "Creating the shared application namespace..."
        kubectl apply -f "$K8S_DIR/base/apps-namespace.yaml" >/dev/null
    fi
    step "Configuring the cluster-only $DEFAULT_INTERNAL_DNS_ZONE service aliases..."
    for manifest in "${FOUNDATION_MANIFEST_ARRAY[@]}"; do
        kubectl apply -f "$K8S_DIR/$manifest"
    done
    kubectl apply -f "$K8S_DIR/base/security-baseline.yaml"

    step "Publishing host security policy record..."
    kubectl apply -f "$K8S_DIR/base/host-security-config.yaml"

    if [[ "$CONFIGURE_CLOUDFLARE" != "true" && ( "$INSTALL_INGRESS" == "true" || "$INSTALL_VAULT_STACK" == "true" || "$DEPLOY_PLATFORM_SERVICES" == "true" || "$DEPLOY_ODOO" == "true" ) ]]; then
        step "Ensuring HTTPS TLS secret..."
        tls_domains=("$CLOUDFLARE_ZONE" "*.$CLOUDFLARE_ZONE")
        ensure_tls_secret infra swirlit-dev-tls "${tls_domains[@]}"
        if [[ "$INSTALL_APPS" == "true" ]]; then
            ensure_tls_secret apps swirlit-dev-tls "${tls_domains[@]}"
        fi
    fi

    if [[ "$INSTALL_LONGHORN" == "true" ]]; then
        node_count="$(kubectl get nodes --no-headers | awk '$2 ~ /^Ready/ {count++} END {print count+0}')"
        longhorn_replicas="$node_count"
        (( longhorn_replicas > 3 )) && longhorn_replicas=3
        (( longhorn_replicas < 1 )) && longhorn_replicas=1
        step "Installing/upgrading Longhorn with $longhorn_replicas default replica(s) for new volumes..."
        helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
        helm repo update > /dev/null 2>&1
        helm upgrade --install longhorn longhorn/longhorn \
            --namespace longhorn-system \
            --create-namespace \
            --version "$LONGHORN_CHART_VERSION" \
            --set "defaultSettings.defaultReplicaCount=$longhorn_replicas" \
            --set "persistence.defaultClassReplicaCount=$longhorn_replicas" \
            --set defaultSettings.defaultDataLocality=best-effort \
            --set defaultSettings.concurrentAutomaticEngineUpgradePerNodeLimit=1 \
            --set "defaultSettings.storageMinimalAvailablePercentage=20" \
            --set "defaultSettings.storageOverProvisioningPercentage=110" \
            --wait --timeout "$LONGHORN_HELM_TIMEOUT"

        kubectl patch storageclass longhorn -p \
            '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
        kubectl patch storageclass local-path -p \
            '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
        kubectl wait --for=condition=ready pod -l app=longhorn-manager \
            -n longhorn-system --timeout="$LONGHORN_POD_WAIT_TIMEOUT"
        kubectl -n longhorn-system patch settings.longhorn.io default-replica-count \
            --type=merge -p "{\"value\":\"$longhorn_replicas\"}" >/dev/null
    fi

    if [[ "$INSTALL_INGRESS" == "true" ]]; then
        step "Installing Nginx Ingress Controller..."
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
        helm repo update > /dev/null 2>&1
        helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
            --namespace infra \
            --version "$INGRESS_NGINX_CHART_VERSION" \
            --set controller.service.type=LoadBalancer \
            --set controller.service.enableHttp=true \
            --set-string 'controller.nodeSelector.node-role\.kubernetes\.io/control-plane=true' \
            --wait --timeout "$INGRESS_HELM_TIMEOUT"
    fi

    if [[ "$CONFIGURE_CLOUDFLARE" == "true" ]]; then
        [[ -x "$CLOUDFLARE_SCRIPT" ]] || error "Cloudflare configurator is not executable: $CLOUDFLARE_SCRIPT"
        step "Configuring Cloudflare DNS and Origin TLS..."
        "$CLOUDFLARE_SCRIPT"
    fi

    if [[ "$INSTALL_VAULT_STACK" == "true" ]]; then
        step "Installing HashiCorp Vault..."
        helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
        helm repo update > /dev/null 2>&1
        helm upgrade --install vault hashicorp/vault \
            --namespace infra \
            --version "$VAULT_CHART_VERSION" \
            --set injector.enabled=false \
            --set server.ha.enabled=true \
            --set server.ha.raft.enabled=true \
            --set server.ha.replicas=1 \
            --set server.dataStorage.storageClass=longhorn

        step "Installing External Secrets Operator..."
        helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
        helm repo update > /dev/null 2>&1
        helm upgrade --install external-secrets external-secrets/external-secrets \
            --namespace infra \
            --version "$EXTERNAL_SECRETS_CHART_VERSION" \
            --set installCRDs=true \
            --wait --timeout "$EXTERNAL_SECRETS_HELM_TIMEOUT"

        step "Applying unified Vault manifests (ingress, RBAC, and secret sync)..."
        kubectl apply -f "$K8S_DIR/platform/vault.yaml"

        kubectl wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 -n infra --timeout="$VAULT_WAIT_TIMEOUT"
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=external-secrets -n infra --timeout="$VAULT_WAIT_TIMEOUT"

        [[ -x "$VAULT_BOOTSTRAP_SCRIPT" ]] || error "Vault configurator is not executable: $VAULT_BOOTSTRAP_SCRIPT"
        step "Bootstrapping Vault auth/policies and seeding secrets..."
        "$VAULT_BOOTSTRAP_SCRIPT" infra

        for es in "${EXTERNAL_SECRET_NAME_ARRAY[@]}"; do
            kubectl wait --for=condition=Ready externalsecret/"$es" -n infra \
                --timeout="$EXTERNAL_SECRET_WAIT_TIMEOUT"
        done
    fi

    if [[ "$DEPLOY_DATA_STORES" == "true" ]]; then
        step "Deploying core data stores..."
        for manifest in "${DATASTORE_MANIFEST_ARRAY[@]}"; do
            kubectl apply -f "$K8S_DIR/$manifest"
        done

        for app in "${DATASTORE_WAIT_APP_ARRAY[@]}"; do
            kubectl wait --for=condition=ready pod -l "app=$app" -n infra \
                --timeout="$DATASTORE_WAIT_TIMEOUT"
        done
    fi

    if [[ "$DEPLOY_PLATFORM_SERVICES" == "true" ]]; then
        step "Deploying platform services..."
        for manifest in "${PLATFORM_MANIFEST_ARRAY[@]}"; do
            kubectl apply -f "$K8S_DIR/$manifest"
        done

        kubectl rollout status deployment/nexus -n infra --timeout="$NEXUS_WAIT_TIMEOUT"
        [[ -x "$NEXUS_REGISTRY_SCRIPT" ]] || error "Nexus registry configurator is not executable: $NEXUS_REGISTRY_SCRIPT"
        step "Configuring the private Nexus image registry and service accounts..."
        "$NEXUS_REGISTRY_SCRIPT"
        registry_secrets=(jenkins-builds/jenkins-registry-auth)
        for registry_secret in "${registry_secrets[@]}"; do
            registry_namespace="${registry_secret%%/*}"
            registry_name="${registry_secret##*/}"
            kubectl wait --for=condition=Ready externalsecret/"$registry_name" \
                -n "$registry_namespace" --timeout="$EXTERNAL_SECRET_WAIT_TIMEOUT"
        done

        for app in "${PLATFORM_WAIT_APP_ARRAY[@]}"; do
            kubectl wait --for=condition=ready pod -l "app=$app" -n infra \
                --timeout="$PLATFORM_WAIT_TIMEOUT"
        done
        for daemonset in "${PLATFORM_WAIT_DAEMONSET_ARRAY[@]}"; do
            kubectl rollout status "daemonset/$daemonset" -n infra \
                --timeout="$PLATFORM_WAIT_TIMEOUT"
        done
        for manifest in "${POST_DEPLOY_CREATE_MANIFEST_ARRAY[@]}"; do
            created_resource="$(kubectl create -f "$K8S_DIR/$manifest" -o name)"
            kubectl wait --for=condition=complete "$created_resource" -n infra \
                --timeout="$POST_DEPLOY_JOB_WAIT_TIMEOUT"
        done
    fi

    if [[ "$DEPLOY_ODOO" == "true" ]]; then
        step "Deploying Odoo in the apps namespace..."
        kubectl apply -f "$K8S_DIR/apps/odoo.yaml"
        kubectl wait --for=condition=Ready externalsecret/odoo-secret -n apps \
            --timeout="$EXTERNAL_SECRET_WAIT_TIMEOUT"
        kubectl wait --for=condition=ready pod -l app=odoo -n apps \
            --timeout="$PLATFORM_WAIT_TIMEOUT"
    fi

    if [[ "$INSTALL_DESCHEDULER" == "true" ]]; then
        step "Installing Descheduler addon resources (manual-run mode)..."
        kubectl apply -f "$K8S_DIR/addons/descheduler.yaml"
    fi

    if [[ "$INSTALL_ARGOCD" == "true" ]]; then
        step "Installing ArgoCD..."
        helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
        helm repo update > /dev/null 2>&1
        helm upgrade --install argocd argo/argo-cd \
            --namespace infra \
            --version "$ARGOCD_CHART_VERSION" \
            --set-string "global.image.tag=$ARGOCD_IMAGE_TAG" \
            --set server.service.type=ClusterIP \
            --set configs.params."server\\.insecure"=true \
            --set redis.enabled=true \
            --wait --timeout "$ARGOCD_HELM_TIMEOUT"
    fi
else
    warn "All Kubernetes feature groups were skipped."
fi

info ""
info "============================================="
info " Installation complete!"
info "============================================="

echo ""
echo "Installed versions:"
command -v java >/dev/null 2>&1 && echo "  Java: $(java -version 2>&1 | head -1)"
command -v mvn >/dev/null 2>&1 && echo "  Maven: $(mvn -version 2>&1 | head -1)"
command -v node >/dev/null 2>&1 && echo "  Node: $(node -v)"
command -v docker >/dev/null 2>&1 && echo "  Docker: $(docker --version)"
if command -v helm >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    LONGHORN_VERSION="$(helm list -n longhorn-system -o json 2>/dev/null | jq -r '.[0].app_version // "unknown"')"
    echo "  Longhorn: ${LONGHORN_VERSION}"
fi
echo ""
if [[ "$RUN_K8S_FEATURES" == "true" ]]; then
    if [[ "$DEPLOY_PLATFORM_SERVICES" == "true" ]] || kubectl get deployment homepage -n infra >/dev/null 2>&1; then
        echo "Service dashboard: https://dashboard.swirlit.dev"
    fi

    echo ""
    echo "Retrieve credentials:"
    echo "  Jenkins:  kubectl exec -n infra deployment/jenkins -- cat /var/jenkins_home/secrets/initialAdminPassword"
    echo "  ArgoCD:   kubectl -n infra get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo "  Nexus:    kubectl exec -n infra deployment/nexus -- cat /nexus-data/admin.password"
    echo "  GitLab:   kubectl exec -n infra deployment/gitlab -- grep 'Password:' /etc/gitlab/initial_root_password"
    echo "  MongoDB:  kubectl get secret -n infra mongodb-secret -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d"
    echo "  Vault:    sudo cat /var/lib/bm-cluster/vault-bootstrap-token"
    echo "  DBGate:   kubectl get secret -n infra dbgate-auth-secret -o go-template='{{printf \"%s\" (index .data \"LOGIN\" | base64decode)}}:{{printf \"%s\" (index .data \"PASSWORD\" | base64decode)}}'"
    echo "  Kafka UI: kubectl get secret -n infra kafka-ui-auth-secret -o go-template='{{printf \"%s\" (index .data \"SPRING_SECURITY_USER_NAME\" | base64decode)}}:{{printf \"%s\" (index .data \"SPRING_SECURITY_USER_PASSWORD\" | base64decode)}}'"
    echo "  Portainer: username admin; password: kubectl get secret -n infra portainer-auth-secret -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d"
    if [[ "$DEPLOY_ODOO" == "true" ]]; then
        echo "  Odoo:     username admin; password: kubectl get secret -n apps odoo-secret -o jsonpath='{.data.ODOO_ADMIN_PASSWORD}' | base64 -d"
    fi
    echo "  Descheduler trigger: kubectl create -f k8s/addons/descheduler-run-job.yaml"
    echo "  Add workers:          ./install-worker.sh"
    echo "  Worker join token:    sudo cat /var/lib/rancher/k3s/server/node-token"
    echo ""

    echo "Cluster nodes:"
    kubectl get nodes -o wide
    echo ""
    echo "Pod status:"
    kubectl get pods -n infra --no-headers 2>&1 | awk '{printf "  %-50s %s\n", $1, $2}'
    if [[ "$INSTALL_APPS" == "true" ]]; then
        echo ""
        echo "App pod status:"
        kubectl get pods -n apps --no-headers 2>&1 | awk '{printf "  %-50s %s\n", $1, $2}'
    fi
fi
