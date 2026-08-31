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
PROMPT_LIBRARY="$SCRIPT_DIR/scripts/lib/installer-prompts.sh"
if [[ ! -r "$PROMPT_LIBRARY" ]]; then
    echo "[ERROR] Shared installer prompt library not found: $PROMPT_LIBRARY" >&2
    exit 1
fi
# shellcheck source=scripts/lib/installer-prompts.sh
source "$PROMPT_LIBRARY"
TRANSPORT_GUIDE_LIBRARY="$SCRIPT_DIR/scripts/lib/transport-guide.sh"
if [[ ! -r "$TRANSPORT_GUIDE_LIBRARY" ]]; then
    echo "[ERROR] Shared transport guide not found: $TRANSPORT_GUIDE_LIBRARY" >&2
    exit 1
fi
# shellcheck source=scripts/lib/transport-guide.sh
source "$TRANSPORT_GUIDE_LIBRARY"
SSO_ADMIN_LIBRARY="$SCRIPT_DIR/scripts/lib/sso-admin.sh"
if [[ ! -r "$SSO_ADMIN_LIBRARY" ]]; then
    echo "[ERROR] Shared SSO administrator library not found: $SSO_ADMIN_LIBRARY" >&2
    exit 1
fi
# shellcheck source=scripts/lib/sso-admin.sh
source "$SSO_ADMIN_LIBRARY"

K8S_TEMPLATE_DIR="$SCRIPT_DIR/k8s"
K8S_DIR="$K8S_TEMPLATE_DIR"
ARGOCD_VALUES_FILE="$SCRIPT_DIR/config/argocd-values.yaml"
RENDER_CONFIG_SCRIPT="$SCRIPT_DIR/scripts/render-cluster-config.sh"
VAULT_VALUES_FILE="$SCRIPT_DIR/config/vault-values.yaml"
VAULT_BOOTSTRAP_SCRIPT="$SCRIPT_DIR/scripts/configure-vault.sh"
SECURITY_HARDEN_SCRIPT="$SCRIPT_DIR/scripts/configure-node-security.sh"
CLOUDFLARE_SCRIPT="$SCRIPT_DIR/scripts/configure-cloudflare.sh"
WORKER_INSTALLER_SCRIPT="$SCRIPT_DIR/install-worker.sh"
K3S_BACKUP_SCRIPT="$SCRIPT_DIR/scripts/configure-k3s-backups.sh"
GITLAB_CI_SCRIPT="$SCRIPT_DIR/scripts/configure-gitlab-ci.sh"
GITLAB_TOKEN_LIBRARY="$SCRIPT_DIR/scripts/lib/gitlab-admin-token.sh"
LOCAL_ADMIN_PASSWORD_ROTATION_SCRIPT="$SCRIPT_DIR/scripts/rotate-local-admin-passwords.sh"
K3S_REGISTRY_MIRROR_SCRIPT="$SCRIPT_DIR/scripts/configure-k3s-registry-mirror.sh"
K3S_APPARMOR_SCRIPT="$SCRIPT_DIR/scripts/configure-k3s-apparmor.sh"
LONGHORN_HOST_SCRIPT="$SCRIPT_DIR/scripts/configure-longhorn-host.sh"
CLUSTER_TOPOLOGY_SCRIPT="$SCRIPT_DIR/scripts/reconcile-cluster-topology.sh"
K3S_NETWORK_SCRIPT="$SCRIPT_DIR/scripts/configure-k3s-control-plane-network.sh"
LEGACY_RECONCILIATION_SCRIPT="$SCRIPT_DIR/scripts/reconcile-legacy-resources.sh"
TAILSCALE_SCRIPT="$SCRIPT_DIR/scripts/configure-tailscale.sh"
OVH_VRACK_SCRIPT="$SCRIPT_DIR/scripts/configure-ovh-vrack.sh"
AUTO_APPROVE=false
INSTALL_SCOPE="${INSTALL_SCOPE:-apps}"
SERVER_EXPOSURE="${SERVER_EXPOSURE:-internet}"
K3S_NODE_TRANSPORT="${K3S_NODE_TRANSPORT:-}"
TAILSCALE_API_TOKEN="${TAILSCALE_API_TOKEN:-}"
TAILSCALE_TAILNET="${TAILSCALE_TAILNET:-$DEFAULT_TAILSCALE_TAILNET}"
TAILSCALE_MESH_NAME="${TAILSCALE_MESH_NAME:-$DEFAULT_TAILSCALE_MESH_NAME}"
TAILSCALE_NODE_HOSTNAME="${TAILSCALE_NODE_HOSTNAME:-}"
TAILSCALE_AUTH_KEY_EXPIRY_SECONDS="${TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-$DEFAULT_TAILSCALE_AUTH_KEY_EXPIRY_SECONDS}"
OVH_VRACK_AUTOMATE_ACCOUNT="${OVH_VRACK_AUTOMATE_ACCOUNT:-}"
OVH_API_ENDPOINT="${OVH_API_ENDPOINT:-ovh-eu}"
OVH_APPLICATION_KEY="${OVH_APPLICATION_KEY:-}"
OVH_APPLICATION_SECRET="${OVH_APPLICATION_SECRET:-}"
OVH_CONSUMER_KEY="${OVH_CONSUMER_KEY:-}"
OVH_VRACK_SERVICE_NAME="${OVH_VRACK_SERVICE_NAME:-}"
OVH_CONTROL_PLANE_SERVICE_NAME="${OVH_CONTROL_PLANE_SERVICE_NAME:-}"
KEYCLOAK_SSO_BOOTSTRAP_USERNAME="${KEYCLOAK_SSO_BOOTSTRAP_USERNAME:-}"
KEYCLOAK_SSO_BOOTSTRAP_PASSWORD="${KEYCLOAK_SSO_BOOTSTRAP_PASSWORD:-}"
ROTATE_LOCAL_ADMIN_PASSWORDS="${ROTATE_LOCAL_ADMIN_PASSWORDS:-}"
LOCAL_ADMIN_PASSWORD="${LOCAL_ADMIN_PASSWORD:-}"
CONFIGURE_OFFSITE_BACKUPS="${CONFIGURE_OFFSITE_BACKUPS:-}"
BACKUP_S3_ENDPOINT="${BACKUP_S3_ENDPOINT:-}"
BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-}"
BACKUP_S3_REGION="${BACKUP_S3_REGION:-}"
BACKUP_S3_ACCESS_KEY="${BACKUP_S3_ACCESS_KEY:-}"
BACKUP_S3_SECRET_KEY="${BACKUP_S3_SECRET_KEY:-}"
BACKUP_REPOSITORY_PASSWORD="${BACKUP_REPOSITORY_PASSWORD:-}"
PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-${DEFAULT_PLATFORM_DOMAIN:-}}"
INTERNAL_DNS_ZONE="${INTERNAL_DNS_ZONE:-}"
CONTROL_PLANE_NODE_NAME="${CONTROL_PLANE_NODE_NAME:-}"
CONFIGURE_REPOSITORY_SYNC="${CONFIGURE_REPOSITORY_SYNC:-}"
REPOSITORY_SYNC_MAPPINGS="${REPOSITORY_SYNC_MAPPINGS:-}"
GITLAB_GROUP_PATH="${GITLAB_GROUP_PATH:-swirlit}"
GITLAB_GROUP_NAME="${GITLAB_GROUP_NAME:-SwirlIT}"
GITLAB_PROJECT_PATH="${GITLAB_PROJECT_PATH:-}"
GITOPS_REPOSITORY_URL="${GITOPS_REPOSITORY_URL:-}"
RENDERED_CONFIG_DIR=""
INSTALLER_TEMP_DIR=""
nodesource_installer=""
k3s_installer=""
helm_installer=""
K3S_INSTALL_VERSION="${K3S_INSTALL_VERSION:-$DEFAULT_K3S_INSTALL_VERSION}"
K3S_REGISTRY_HOST="${K3S_REGISTRY_HOST:-${DEFAULT_K3S_REGISTRY_HOST:-}}"
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
POST_DEPLOY_JOB_WAIT_TIMEOUT="${POST_DEPLOY_JOB_WAIT_TIMEOUT:-$DEFAULT_POST_DEPLOY_JOB_WAIT_TIMEOUT}"
CLOUDFLARE_ZONE="${CLOUDFLARE_ZONE:-${DEFAULT_CLOUDFLARE_ZONE:-}}"
CLOUDFLARE_ACCESS_TEAM_NAME="${CLOUDFLARE_ACCESS_TEAM_NAME:-${DEFAULT_CLOUDFLARE_ACCESS_TEAM_NAME:-}}"
CLUSTER_NODE_COUNT="${CLUSTER_NODE_COUNT:-}"
CONTROL_PLANE_SCHEDULABLE="${CONTROL_PLANE_SCHEDULABLE:-}"
PLANNED_WORKER_COUNT=0
WORKERS_TO_ADD=0

IFS=',' read -r -a FOUNDATION_MANIFEST_ARRAY <<< "$FOUNDATION_MANIFESTS"
IFS=',' read -r -a DATASTORE_MANIFEST_ARRAY <<< "$DATASTORE_MANIFESTS"
IFS=',' read -r -a PLATFORM_MANIFEST_ARRAY <<< "$PLATFORM_MANIFESTS"
IFS=',' read -r -a POST_DEPLOY_CREATE_MANIFEST_ARRAY <<< "$POST_DEPLOY_CREATE_MANIFESTS"
IFS=',' read -r -a POST_ARGOCD_MANIFEST_ARRAY <<< "$POST_ARGOCD_MANIFESTS"
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
fail()  { error "$@"; }
step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

ask_with_default() {
    installer_prompt_yes_no "$1" "${2:-N}" "$AUTO_APPROVE"
}

prompt_cluster_identity() {
    local default_node

    if [[ "$AUTO_APPROVE" != "true" ]]; then
        installer_prompt_value PLATFORM_DOMAIN "Public base domain for this cluster" "$PLATFORM_DOMAIN"
    fi
    PLATFORM_DOMAIN="${PLATFORM_DOMAIN,,}"
    [[ "$PLATFORM_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || \
        error "Set PLATFORM_DOMAIN to a valid base domain such as example.com."

    INTERNAL_DNS_ZONE="${INTERNAL_DNS_ZONE:-internal.$PLATFORM_DOMAIN}"
    INTERNAL_DNS_ZONE="${INTERNAL_DNS_ZONE,,}"
    [[ "$INTERNAL_DNS_ZONE" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || \
        error "INTERNAL_DNS_ZONE is invalid."
    [[ "$INTERNAL_DNS_ZONE" != "$PLATFORM_DOMAIN" ]] || \
        error "The private service domain must differ from the public domain."

    default_node="${CONTROL_PLANE_NODE_NAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
    if [[ "$AUTO_APPROVE" != "true" ]]; then
        installer_prompt_value CONTROL_PLANE_NODE_NAME "K3s control-plane node name" "$default_node"
    else
        CONTROL_PLANE_NODE_NAME="$default_node"
    fi
    CONTROL_PLANE_NODE_NAME="${CONTROL_PLANE_NODE_NAME,,}"
    [[ "$CONTROL_PLANE_NODE_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#CONTROL_PLANE_NODE_NAME} -le 63 ]] || \
        error "CONTROL_PLANE_NODE_NAME must be a single valid lowercase DNS label."

    CLOUDFLARE_ZONE="${CLOUDFLARE_ZONE:-$PLATFORM_DOMAIN}"
    [[ "$CLOUDFLARE_ZONE" == "$PLATFORM_DOMAIN" ]] || \
        error "CLOUDFLARE_ZONE must match PLATFORM_DOMAIN for this deployment."
    K3S_REGISTRY_HOST="${K3S_REGISTRY_HOST:-registry.$PLATFORM_DOMAIN}"
    CLOUDFLARE_ACCESS_TEAM_NAME="${CLOUDFLARE_ACCESS_TEAM_NAME:-bm-cluster-${PLATFORM_DOMAIN//./-}}"
    [[ "$CLOUDFLARE_ACCESS_TEAM_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#CLOUDFLARE_ACCESS_TEAM_NAME} -le 63 ]] || \
        error "CLOUDFLARE_ACCESS_TEAM_NAME must be a single lowercase DNS label."
    TAILSCALE_NODE_HOSTNAME="${TAILSCALE_NODE_HOSTNAME:-$CONTROL_PLANE_NODE_NAME}"
    export PLATFORM_DOMAIN INTERNAL_DNS_ZONE CONTROL_PLANE_NODE_NAME CLOUDFLARE_ZONE CLOUDFLARE_ACCESS_TEAM_NAME
    export K3S_REGISTRY_HOST TAILSCALE_NODE_HOSTNAME
    info "Cluster identity: node $CONTROL_PLANE_NODE_NAME, public domain $PLATFORM_DOMAIN, private domain $INTERNAL_DNS_ZONE"
}

configured_worker_target_count() {
    local targets="${K3S_WORKER_HOSTS:-${K3S_WORKER_IPS:-}}"

    [[ -n "$targets" ]] || { printf '0\n'; return; }
    tr ',' '\n' <<< "$targets" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]'
}

ready_cluster_node_count() {
    local nodes

    command -v kubectl >/dev/null 2>&1 || { printf '0\n'; return; }
    nodes="$(kubectl get nodes --no-headers 2>/dev/null)" || { printf '0\n'; return; }
    awk '$2 ~ /^Ready/ {count++} END {print count+0}' <<< "$nodes"
}

ready_cluster_worker_count() {
    local nodes

    command -v kubectl >/dev/null 2>&1 || { printf '0\n'; return; }
    nodes="$(kubectl get nodes \
        -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master' \
        --no-headers 2>/dev/null)" || { printf '0\n'; return; }
    awk '$2 ~ /^Ready/ {count++} END {print count+0}' <<< "$nodes"
}

configure_cluster_topology_plan() {
    local configured_workers existing_nodes existing_workers default_node_count
    local control_plane_default

    configured_workers="$(configured_worker_target_count)"
    existing_nodes="$(ready_cluster_node_count || printf '0')"
    existing_workers="$(ready_cluster_worker_count || printf '0')"
    default_node_count="$existing_nodes"
    (( default_node_count >= 1 )) || default_node_count=1
    (( configured_workers == 0 )) || default_node_count=$((configured_workers + 1))

    if [[ "$AUTO_APPROVE" != "true" ]]; then
        while true; do
            installer_prompt_value CLUSTER_NODE_COUNT \
                "Total number of cluster nodes, including the control plane" \
                "${CLUSTER_NODE_COUNT:-$default_node_count}"
            [[ "$CLUSTER_NODE_COUNT" =~ ^[1-9][0-9]*$ ]] && break
            warn "Enter a positive whole number."
        done
    else
        CLUSTER_NODE_COUNT="${CLUSTER_NODE_COUNT:-$default_node_count}"
    fi
    [[ "$CLUSTER_NODE_COUNT" =~ ^[1-9][0-9]*$ ]] || \
        error "CLUSTER_NODE_COUNT must be a positive integer."
    if (( existing_nodes > CLUSTER_NODE_COUNT )); then
        error "The cluster already has $existing_nodes Ready nodes; this installer does not remove nodes."
    fi

    PLANNED_WORKER_COUNT=$((CLUSTER_NODE_COUNT - 1))
    WORKERS_TO_ADD=$((PLANNED_WORKER_COUNT - existing_workers))
    (( WORKERS_TO_ADD >= 0 )) || WORKERS_TO_ADD=0
    if (( configured_workers > 0 )); then
        (( configured_workers == PLANNED_WORKER_COUNT )) || \
            error "The configured worker target list has $configured_workers entries, but CLUSTER_NODE_COUNT requires $PLANNED_WORKER_COUNT workers."
        WORKERS_TO_ADD="$configured_workers"
    fi

    if [[ -z "$CONTROL_PLANE_SCHEDULABLE" ]]; then
        [[ "$CLUSTER_NODE_COUNT" -eq 1 ]] && control_plane_default=Y || control_plane_default=N
        if ask_with_default \
            "Allow the control plane to run workloads as a controller-worker?" \
            "$control_plane_default"; then
            CONTROL_PLANE_SCHEDULABLE=true
        else
            CONTROL_PLANE_SCHEDULABLE=false
        fi
    else
        case "${CONTROL_PLANE_SCHEDULABLE,,}" in
            1|true|yes|y|worker|controller-worker) CONTROL_PLANE_SCHEDULABLE=true ;;
            0|false|no|n|controller|controller-only) CONTROL_PLANE_SCHEDULABLE=false ;;
            *) error "CONTROL_PLANE_SCHEDULABLE must be true or false." ;;
        esac
    fi
    if [[ "$CLUSTER_NODE_COUNT" -eq 1 && "$CONTROL_PLANE_SCHEDULABLE" != "true" ]]; then
        error "A control-plane-only cluster must allow workloads on its control plane."
    fi

    export CLUSTER_NODE_COUNT CONTROL_PLANE_SCHEDULABLE
    info "Topology plan: $CLUSTER_NODE_COUNT total node(s), $PLANNED_WORKER_COUNT worker(s), control-plane schedulable=$CONTROL_PLANE_SCHEDULABLE."
}

github_repository_url() {
    local remote_url
    remote_url="$(git -C "$SCRIPT_DIR" remote get-url github 2>/dev/null || \
        git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
    case "$remote_url" in
        git@github.com:*) remote_url="https://github.com/${remote_url#git@github.com:}" ;;
        ssh://git@github.com/*) remote_url="https://github.com/${remote_url#ssh://git@github.com/}" ;;
    esac
    [[ "$remote_url" == https://github.com/*.git ]] && printf '%s\n' "$remote_url"
}

configure_repository_delivery() {
    local default_gitops github_url github_slug mapping normalized_mappings=""
    local repository_name
    repository_name="$(basename "$SCRIPT_DIR")"
    github_url="$(github_repository_url)"
    github_slug="${github_url#https://github.com/}"
    github_slug="${github_slug%.git}"

    if [[ -z "$CONFIGURE_REPOSITORY_SYNC" ]]; then
        if [[ "$AUTO_APPROVE" == "true" ]]; then
            CONFIGURE_REPOSITORY_SYNC=false
        elif ask_with_default "Synchronize selected repositories bidirectionally between GitHub and GitLab?" "N"; then
            CONFIGURE_REPOSITORY_SYNC=true
        else
            CONFIGURE_REPOSITORY_SYNC=false
        fi
    fi
    case "${CONFIGURE_REPOSITORY_SYNC,,}" in
        1|true|yes|y) CONFIGURE_REPOSITORY_SYNC=true ;;
        0|false|no|n) CONFIGURE_REPOSITORY_SYNC=false ;;
        *) error "CONFIGURE_REPOSITORY_SYNC must be true or false." ;;
    esac

    if [[ "$CONFIGURE_REPOSITORY_SYNC" == "true" ]]; then
        if [[ "$AUTO_APPROVE" != "true" ]]; then
            installer_prompt_value GITLAB_GROUP_PATH "GitLab group path" "$GITLAB_GROUP_PATH"
            installer_prompt_value GITLAB_GROUP_NAME "GitLab group display name" "$GITLAB_GROUP_NAME"
        fi
        [[ "$GITLAB_GROUP_PATH" =~ ^[A-Za-z0-9_.-]+$ ]] || \
            error "The GitLab group path is invalid."
        GITLAB_PROJECT_PATH="${GITLAB_PROJECT_PATH:-$GITLAB_GROUP_PATH/$repository_name}"
        if [[ "$AUTO_APPROVE" != "true" ]]; then
            installer_prompt_value GITLAB_PROJECT_PATH "GitLab path for this cluster repository" "$GITLAB_PROJECT_PATH"
        fi
        [[ "$GITLAB_PROJECT_PATH" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$ ]] || \
            error "The GitLab project path is invalid."

        if [[ -z "$REPOSITORY_SYNC_MAPPINGS" && -n "$github_slug" ]]; then
            REPOSITORY_SYNC_MAPPINGS="$github_slug=$GITLAB_PROJECT_PATH"
        fi
        if [[ "$AUTO_APPROVE" != "true" ]]; then
            cat >&2 <<EOF

Enter each repository pair as GitHub-owner/repository=GitLab-group/repository.
Separate multiple pairs with commas. Example:
  company/web=platform/web,company/api=platform/api
EOF
            installer_prompt_value REPOSITORY_SYNC_MAPPINGS "Repository pairs" "$REPOSITORY_SYNC_MAPPINGS"
        fi
        [[ -n "$REPOSITORY_SYNC_MAPPINGS" ]] || error "At least one repository pair is required for synchronization."
        IFS=',' read -r -a repository_mappings <<< "$REPOSITORY_SYNC_MAPPINGS"
        for mapping in "${repository_mappings[@]}"; do
            mapping="${mapping//[[:space:]]/}"
            [[ "$mapping" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+=[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
                error "Invalid repository mapping: $mapping"
            normalized_mappings+="${normalized_mappings:+,}$mapping"
        done
        REPOSITORY_SYNC_MAPPINGS="$normalized_mappings"
        GITOPS_REPOSITORY_URL="https://gitlab.$PLATFORM_DOMAIN/$GITLAB_PROJECT_PATH.git"
    else
        GITLAB_PROJECT_PATH="${GITLAB_PROJECT_PATH:-$GITLAB_GROUP_PATH/$repository_name}"
        default_gitops="${GITOPS_REPOSITORY_URL:-$github_url}"
        if [[ "$AUTO_APPROVE" != "true" ]]; then
            installer_prompt_value GITOPS_REPOSITORY_URL "GitOps repository URL" "$default_gitops"
        else
            GITOPS_REPOSITORY_URL="$default_gitops"
        fi
        [[ "$GITOPS_REPOSITORY_URL" =~ ^https?://[^[:space:]]+\.git$ ]] || \
            error "Set GITOPS_REPOSITORY_URL to an HTTP(S) .git repository accessible by Argo CD."
    fi
    export CONFIGURE_REPOSITORY_SYNC REPOSITORY_SYNC_MAPPINGS GITLAB_GROUP_PATH
    export GITLAB_GROUP_NAME GITLAB_PROJECT_PATH GITOPS_REPOSITORY_URL
}

prompt_github_admin_token() {
    [[ -z "${GITHUB_ADMIN_TOKEN:-}" ]] || return 0
    [[ "$AUTO_APPROVE" != "true" ]] || error "Set GITHUB_ADMIN_TOKEN when CONFIGURE_REPOSITORY_SYNC=true."
    cat >&2 <<'EOF'

Create a GitHub fine-grained personal access token:
  1. Open https://github.com/settings/personal-access-tokens/new.
  2. Select every repository entered above.
  3. Grant Administration, Actions, Contents, Secrets, and Variables read/write.
  4. Use the shortest practical expiry and paste the token below.
EOF
    installer_prompt_secret GITHUB_ADMIN_TOKEN "GitHub repository-management token (input hidden)"
    [[ -n "$GITHUB_ADMIN_TOKEN" ]] || error "A GitHub token is required for repository synchronization."
    export GITHUB_ADMIN_TOKEN
}

configure_backup_destination() {
    if [[ -z "$CONFIGURE_OFFSITE_BACKUPS" ]]; then
        if [[ "$AUTO_APPROVE" == "true" ]]; then
            [[ -n "$BACKUP_S3_ENDPOINT$BACKUP_S3_BUCKET$BACKUP_S3_ACCESS_KEY$BACKUP_S3_SECRET_KEY" ]] && \
                CONFIGURE_OFFSITE_BACKUPS=true || CONFIGURE_OFFSITE_BACKUPS=false
        elif ask_with_default "Configure encrypted off-node backups in S3-compatible object storage?" "Y"; then
            CONFIGURE_OFFSITE_BACKUPS=true
        else
            CONFIGURE_OFFSITE_BACKUPS=false
        fi
    fi
    case "${CONFIGURE_OFFSITE_BACKUPS,,}" in
        1|true|yes|y) CONFIGURE_OFFSITE_BACKUPS=true ;;
        0|false|no|n) CONFIGURE_OFFSITE_BACKUPS=false ;;
        *) error "CONFIGURE_OFFSITE_BACKUPS must be true or false." ;;
    esac
    if [[ "$CONFIGURE_OFFSITE_BACKUPS" != "true" ]]; then
        warn "Backups will remain local and will not survive loss of this server."
        export CONFIGURE_OFFSITE_BACKUPS
        return
    fi

    if [[ "$AUTO_APPROVE" != "true" ]]; then
        cat >&2 <<'EOF'

Prepare S3-compatible backup storage:
  1. Create a private bucket at your object-storage provider.
  2. Enable object versioning and provider-side retention if available.
  3. Create an access key/API token limited to list, read, write, and delete
     objects in that bucket. Do not use an account-wide administrator key.
  4. Copy the S3 endpoint, region, bucket name, access-key ID, and secret key.

Examples of endpoints are https://s3.REGION.amazonaws.com and an R2/MinIO S3
endpoint supplied by that provider.
EOF
        installer_prompt_value BACKUP_S3_ENDPOINT "S3-compatible HTTPS endpoint" "$BACKUP_S3_ENDPOINT"
        installer_prompt_value BACKUP_S3_REGION "S3 region" "$BACKUP_S3_REGION"
        installer_prompt_value BACKUP_S3_BUCKET "Private backup bucket" "$BACKUP_S3_BUCKET"
        [[ -n "$BACKUP_S3_ACCESS_KEY" ]] || installer_prompt_secret BACKUP_S3_ACCESS_KEY "S3 access-key ID (input hidden)"
        [[ -n "$BACKUP_S3_SECRET_KEY" ]] || installer_prompt_secret BACKUP_S3_SECRET_KEY "S3 secret access key/API token (input hidden)"
        if [[ -z "$BACKUP_REPOSITORY_PASSWORD" ]]; then
            installer_prompt_confirmed_secret BACKUP_REPOSITORY_PASSWORD \
                "Encryption password for the off-node recovery archive" \
                "Confirm recovery-archive encryption password" || \
                error "Backup encryption passwords do not match."
        fi
    fi
    [[ "$BACKUP_S3_ENDPOINT" == https://* ]] || error "BACKUP_S3_ENDPOINT must use HTTPS."
    [[ "$BACKUP_S3_REGION" =~ ^[A-Za-z0-9._-]+$ ]] || error "BACKUP_S3_REGION is invalid."
    [[ "$BACKUP_S3_BUCKET" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{1,61}[A-Za-z0-9]$ ]] || error "BACKUP_S3_BUCKET is invalid."
    [[ -n "$BACKUP_S3_ACCESS_KEY" && -n "$BACKUP_S3_SECRET_KEY" ]] || error "S3 backup credentials are required."
    (( ${#BACKUP_REPOSITORY_PASSWORD} >= 16 )) || error "The backup encryption password must contain at least 16 characters."
    export CONFIGURE_OFFSITE_BACKUPS BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_BUCKET
    export BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY BACKUP_REPOSITORY_PASSWORD
}

prepare_rendered_configuration() {
    [[ -x "$RENDER_CONFIG_SCRIPT" ]] || error "Configuration renderer is not executable: $RENDER_CONFIG_SCRIPT"
    RENDERED_CONFIG_DIR="$(mktemp -d /tmp/bm-cluster-rendered.XXXXXX)"
    chmod 700 "$RENDERED_CONFIG_DIR"
    "$RENDER_CONFIG_SCRIPT" \
        --output "$RENDERED_CONFIG_DIR" \
        --domain "$PLATFORM_DOMAIN" \
        --internal-domain "$INTERNAL_DNS_ZONE" \
        --gitops-repository "$GITOPS_REPOSITORY_URL" \
        --gitlab-group "$GITLAB_GROUP_PATH" \
        --gitlab-project "${GITLAB_PROJECT_PATH##*/}" \
        --cloudflare-access-team "$CLOUDFLARE_ACCESS_TEAM_NAME" \
        --apps-enabled "$INSTALL_APPS" \
        --descheduler-enabled "$INSTALL_DESCHEDULER" >/dev/null
    K8S_DIR="$RENDERED_CONFIG_DIR/k8s"
    ARGOCD_VALUES_FILE="$RENDERED_CONFIG_DIR/config/argocd-values.yaml"
}

validate_local_admin_password() {
    LOCAL_ADMIN_PASSWORD_ERROR=""
    if (( ${#LOCAL_ADMIN_PASSWORD} < 12 )); then
        LOCAL_ADMIN_PASSWORD_ERROR="The local administrator password must contain at least 12 characters."
        return 1
    fi
    if [[ "$LOCAL_ADMIN_PASSWORD" =~ [[:cntrl:]] ]]; then
        LOCAL_ADMIN_PASSWORD_ERROR="The local administrator password cannot contain control characters."
        return 1
    fi
    if [[ ! "$LOCAL_ADMIN_PASSWORD" =~ [[:lower:]] ||
          ! "$LOCAL_ADMIN_PASSWORD" =~ [[:upper:]] ||
          ! "$LOCAL_ADMIN_PASSWORD" =~ [[:digit:]] ||
          ! "$LOCAL_ADMIN_PASSWORD" =~ [^[:alnum:]] ]]; then
        LOCAL_ADMIN_PASSWORD_ERROR="The local administrator password must include lowercase, uppercase, numeric, and special characters."
        return 1
    fi
}

configure_local_admin_password_rotation() {
    if [[ -z "$ROTATE_LOCAL_ADMIN_PASSWORDS" ]]; then
        if ask_with_default "Use one password for all local infrastructure superusers?" "N"; then
            ROTATE_LOCAL_ADMIN_PASSWORDS=true
        else
            ROTATE_LOCAL_ADMIN_PASSWORDS=false
        fi
    else
        case "${ROTATE_LOCAL_ADMIN_PASSWORDS,,}" in
            1|true|yes|y) ROTATE_LOCAL_ADMIN_PASSWORDS=true ;;
            0|false|no|n) ROTATE_LOCAL_ADMIN_PASSWORDS=false ;;
            *) error "ROTATE_LOCAL_ADMIN_PASSWORDS must be true or false." ;;
        esac
    fi

    if [[ "$ROTATE_LOCAL_ADMIN_PASSWORDS" != "true" ]]; then
        LOCAL_ADMIN_PASSWORD=""
        unset LOCAL_ADMIN_PASSWORD
        return
    fi

    while ! validate_local_admin_password; do
        if [[ "$AUTO_APPROVE" == "true" ]]; then
            error "Set LOCAL_ADMIN_PASSWORD when ROTATE_LOCAL_ADMIN_PASSWORDS=true. $LOCAL_ADMIN_PASSWORD_ERROR"
        fi
        [[ -z "$LOCAL_ADMIN_PASSWORD" ]] || warn "$LOCAL_ADMIN_PASSWORD_ERROR"
        LOCAL_ADMIN_PASSWORD=""
        if ! installer_prompt_confirmed_secret LOCAL_ADMIN_PASSWORD \
            "Local infrastructure administrator password (input hidden)" \
            "Confirm local infrastructure administrator password"; then
            warn "The passwords do not match."
            LOCAL_ADMIN_PASSWORD=""
        fi
    done

    unset LOCAL_ADMIN_PASSWORD_ERROR
    info "The installer will align supported local infrastructure superusers after platform deployment."
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
    local requested_transport="$K3S_NODE_TRANSPORT" selected_transport=""

    if [[ "$AUTO_APPROVE" == "true" && -z "$requested_transport" ]]; then
        if [[ -n "${K3S_WORKER_HOSTS:-}" ]]; then
            requested_transport=tailscale
        elif [[ -n "${K3S_WORKER_IPS:-}" ]]; then
            requested_transport=vrack
        else
            error "Set K3S_NODE_TRANSPORT=vrack|tailscale when adding workers non-interactively."
        fi
    fi

    installer_select_node_transport selected_transport "$requested_transport" \
        "${DEFAULT_K3S_NODE_TRANSPORT:-vrack}" "$AUTO_APPROVE" || \
        error "K3S_NODE_TRANSPORT must be vrack or tailscale."
    printf '%s\n' "$selected_transport"
}

configure_platform_component_selection() {
    installer_prompt_section "Platform components" \
        "The recommended bundle installs storage, ingress, secrets, data stores," \
        "platform services, Descheduler resources, and Argo CD."

    if ask_with_default "Use the recommended platform component bundle?" "Y"; then
        INSTALL_LONGHORN=true
        INSTALL_INGRESS=true
        INSTALL_VAULT_STACK=true
        DEPLOY_DATA_STORES=true
        DEPLOY_PLATFORM_SERVICES=true
        INSTALL_DESCHEDULER=true
        INSTALL_ARGOCD=true
        return
    fi

    info "Custom component selection enabled."
    ask_with_default "Install/upgrade Longhorn and make it the default storage class?" "Y" && INSTALL_LONGHORN=true || INSTALL_LONGHORN=false
    ask_with_default "Install/upgrade NGINX ingress controller?" "Y" && INSTALL_INGRESS=true || INSTALL_INGRESS=false
    ask_with_default "Install/upgrade Vault + External Secrets and bootstrap secrets?" "Y" && INSTALL_VAULT_STACK=true || INSTALL_VAULT_STACK=false
    ask_with_default "Deploy/upgrade core data stores (Postgres, Kafka, Redis, MongoDB)?" "Y" && DEPLOY_DATA_STORES=true || DEPLOY_DATA_STORES=false
    ask_with_default "Deploy/upgrade platform services from the shared inventory?" "Y" && DEPLOY_PLATFORM_SERVICES=true || DEPLOY_PLATFORM_SERVICES=false
    ask_with_default "Install/upgrade Descheduler addon resources (manual trigger only)?" "Y" && INSTALL_DESCHEDULER=true || INSTALL_DESCHEDULER=false
    ask_with_default "Install/upgrade Argo CD?" "Y" && INSTALL_ARGOCD=true || INSTALL_ARGOCD=false
}

prompt_platform_admin_credentials() {
    while ! sso_admin_validate_username "$KEYCLOAK_SSO_BOOTSTRAP_USERNAME"; do
        if [[ "$AUTO_APPROVE" == "true" ]]; then
            error "Set a valid KEYCLOAK_SSO_BOOTSTRAP_USERNAME for a non-interactive platform installation. $SSO_ADMIN_VALIDATION_ERROR"
        fi
        [[ -z "$KEYCLOAK_SSO_BOOTSTRAP_USERNAME" ]] || warn "$SSO_ADMIN_VALIDATION_ERROR"
        installer_prompt_value KEYCLOAK_SSO_BOOTSTRAP_USERNAME \
            "Platform administrator login (username or email)"
    done

    while ! sso_admin_validate_password "$KEYCLOAK_SSO_BOOTSTRAP_PASSWORD" \
        "$KEYCLOAK_SSO_BOOTSTRAP_USERNAME"; do
        if [[ "$AUTO_APPROVE" == "true" ]]; then
            error "Set a valid KEYCLOAK_SSO_BOOTSTRAP_PASSWORD for a non-interactive platform installation. $SSO_ADMIN_VALIDATION_ERROR"
        fi
        [[ -z "$KEYCLOAK_SSO_BOOTSTRAP_PASSWORD" ]] || warn "$SSO_ADMIN_VALIDATION_ERROR"
        KEYCLOAK_SSO_BOOTSTRAP_PASSWORD=""
        if ! installer_prompt_confirmed_secret KEYCLOAK_SSO_BOOTSTRAP_PASSWORD \
            "Platform administrator password (input hidden)" \
            "Confirm platform administrator password"; then
            warn "The passwords do not match."
            KEYCLOAK_SSO_BOOTSTRAP_PASSWORD=""
        fi
    done

    export KEYCLOAK_SSO_BOOTSTRAP_USERNAME KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
    info "Keycloak will provision '$KEYCLOAK_SSO_BOOTSTRAP_USERNAME' as the shared platform administrator."
}

cleanup_private_credentials() {
    TAILSCALE_API_TOKEN=""
    OVH_APPLICATION_KEY=""
    OVH_APPLICATION_SECRET=""
    OVH_CONSUMER_KEY=""
    KEYCLOAK_SSO_BOOTSTRAP_PASSWORD=""
    LOCAL_ADMIN_PASSWORD=""
    GITHUB_ADMIN_TOKEN=""
    CLOUDFLARE_API_TOKEN=""
    BACKUP_S3_ACCESS_KEY=""
    BACKUP_S3_SECRET_KEY=""
    BACKUP_REPOSITORY_PASSWORD=""
    unset TAILSCALE_API_TOKEN OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY 2>/dev/null || true
    unset KEYCLOAK_SSO_BOOTSTRAP_USERNAME KEYCLOAK_SSO_BOOTSTRAP_PASSWORD 2>/dev/null || true
    unset LOCAL_ADMIN_PASSWORD LOCAL_ADMIN_PASSWORD_ERROR 2>/dev/null || true
    unset GITHUB_ADMIN_TOKEN 2>/dev/null || true
    unset CLOUDFLARE_API_TOKEN 2>/dev/null || true
    unset BACKUP_S3_ACCESS_KEY BACKUP_S3_SECRET_KEY BACKUP_REPOSITORY_PASSWORD 2>/dev/null || true
    if declare -F gitlab_revoke_ephemeral_admin_token >/dev/null 2>&1; then
        gitlab_revoke_ephemeral_admin_token
    fi
    if [[ -n "$INSTALLER_TEMP_DIR" && "$INSTALLER_TEMP_DIR" == /tmp/bm-cluster-installers.* && -d "$INSTALLER_TEMP_DIR" ]]; then
        rm -r -- "$INSTALLER_TEMP_DIR"
    fi
    if [[ -n "$RENDERED_CONFIG_DIR" && "$RENDERED_CONFIG_DIR" == /tmp/bm-cluster-rendered.* && -d "$RENDERED_CONFIG_DIR" ]]; then
        rm -r -- "$RENDERED_CONFIG_DIR"
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
echo "  - Group related questions and offer a recommended platform bundle"
echo "  - Provision the login you choose as administrator through Keycloak SSO"
echo "  - Install only selected components"
echo "  - Apply UFW everywhere and add intrusion prevention only when internet-exposed"
echo ""

ask_with_default "Proceed with installation and deployment?" "Y" || { info "Aborted."; exit 0; }

installer_prompt_section "Cluster identity and deployment scope" \
    "Choose where this cluster runs and whether it includes application workloads."
prompt_cluster_identity

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

installer_prompt_section "Cluster nodes and scheduling" \
    "Set the total node count, then choose whether the control plane also runs workloads."
configure_cluster_topology_plan

installer_prompt_section "Host prerequisites and K3s nodes" \
    "Choose host preparation, control-plane installation, and optional workers."
if command -v k3s &>/dev/null; then
    warn "K3s detected: $(k3s --version | head -1)"
    K3S_DEFAULT="N"
else
    K3S_DEFAULT="Y"
fi

ask_with_default "Install/upgrade system prerequisites (Java/Maven/Docker/Ansible/Node/etc.)?" "Y" && INSTALL_PREREQS=true || INSTALL_PREREQS=false
ask_with_default "Install or reinstall K3s control plane?" "$K3S_DEFAULT" && INSTALL_K3S=true || INSTALL_K3S=false
if (( WORKERS_TO_ADD > 0 )); then
    ADD_K3S_WORKERS=true
    info "$WORKERS_TO_ADD worker node(s) will be added or reconciled over SSH."
else
    ADD_K3S_WORKERS=false
    info "The requested worker count is already present; no worker enrollment is needed."
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
                installer_prompt_value OVH_CONTROL_PLANE_SERVICE_NAME \
                    "This control plane's OVHcloud Dedicated Server service name" \
                    "$OVH_CONTROL_PLANE_SERVICE_NAME"
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
            installer_prompt_value K3S_PRIVATE_ADDRESS "Control-plane vRack/private RFC1918 IPv4"
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
            installer_prompt_value K3S_NODE_NETWORK_CIDR \
                "Trusted vRack/private node CIDR (for example 10.50.0.0/24)"
            [[ -n "$K3S_NODE_NETWORK_CIDR" ]] || error "A trusted vRack/private node CIDR is required."
            export K3S_NODE_NETWORK_CIDR
        fi
        existing_vrack_interface="$(interface_owning_ip "$K3S_PRIVATE_ADDRESS")"
        if [[ -z "$existing_vrack_interface" && "$AUTO_APPROVE" != "true" ]]; then
            ip -br link show
            installer_prompt_value K3S_PRIVATE_INTERFACE "Control-plane OVHcloud private/vRack NIC name"
            installer_prompt_value K3S_PRIVATE_INTERFACE_MAC \
                "Expected private NIC MAC (recommended)" "${K3S_PRIVATE_INTERFACE_MAC:-}"
            installer_prompt_value K3S_VRACK_VLAN_ID \
                "Optional vRack VLAN ID (blank for untagged VLAN 0)"
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

configure_platform_component_selection

installer_prompt_section "Recovery and public access" \
    "Configure off-node backups and, for internet-facing clusters, public DNS and TLS."
configure_backup_destination
if [[ "$SERVER_EXPOSURE" == "internet" ]]; then
    ask_with_default "Configure Cloudflare public DNS and Origin TLS?" "Y" && CONFIGURE_CLOUDFLARE=true || CONFIGURE_CLOUDFLARE=false
else
    CONFIGURE_CLOUDFLARE=false
fi
if [[ "$CONFIGURE_CLOUDFLARE" == "true" && "$AUTO_APPROVE" != "true" ]]; then
    installer_prompt_value CLOUDFLARE_ACCESS_TEAM_NAME \
        "Cloudflare Zero Trust team label (first part of TEAM.cloudflareaccess.com)" \
        "$CLOUDFLARE_ACCESS_TEAM_NAME"
fi
[[ "$CLOUDFLARE_ACCESS_TEAM_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#CLOUDFLARE_ACCESS_TEAM_NAME} -le 63 ]] || \
    error "CLOUDFLARE_ACCESS_TEAM_NAME must be a single lowercase DNS label."
export CLOUDFLARE_ACCESS_TEAM_NAME

installer_prompt_section "GitOps and repository delivery" \
    "Choose the Argo CD source and optionally configure GitHub/GitLab synchronization."
configure_repository_delivery

if [[ "$DEPLOY_PLATFORM_SERVICES" == "true" && "$DEPLOY_DATA_STORES" != "true" ]]; then
    warn "Platform services depend on data stores; enabling data store deployment."
    DEPLOY_DATA_STORES=true
fi

if [[ "$DEPLOY_ODOO" == "true" && "$DEPLOY_DATA_STORES" != "true" ]]; then
    warn "Odoo depends on PostgreSQL; enabling data store deployment."
    DEPLOY_DATA_STORES=true
fi

if [[ "$DEPLOY_ODOO" == "true" && "$DEPLOY_PLATFORM_SERVICES" != "true" ]]; then
    warn "Odoo SSO depends on Keycloak; enabling platform service deployment."
    DEPLOY_PLATFORM_SERVICES=true
fi

if [[ "$DEPLOY_PLATFORM_SERVICES" == "true" ]]; then
    installer_prompt_section "Administrator credentials" \
        "Configure the shared Keycloak administrator and optional local password alignment."
    prompt_platform_admin_credentials
    configure_local_admin_password_rotation
else
    ROTATE_LOCAL_ADMIN_PASSWORDS=false
    LOCAL_ADMIN_PASSWORD=""
    unset LOCAL_ADMIN_PASSWORD
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

prepare_rendered_configuration

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
        dnsutils \
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
        k3s_server_args=(
            --disable traefik
            --node-name "$CONTROL_PLANE_NODE_NAME"
            --secrets-encryption
            --write-kubeconfig-mode 600
        )
        sudo env INSTALL_K3S_VERSION="$K3S_INSTALL_VERSION" sh "$k3s_installer" \
            "${k3s_server_args[@]}"
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
        node.bm-cluster.io/role=control-plane \
        "node.bm-cluster.io/exposure=$SERVER_EXPOSURE" \
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
        if [[ -z "$worker_ip_list$worker_host_list" ]]; then
            worker_manager_args+=(--worker-count "$WORKERS_TO_ADD")
        fi
        worker_manager_args+=(--control-plane-schedulable "$CONTROL_PLANE_SCHEDULABLE")
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
    [[ -x "$CLUSTER_TOPOLOGY_SCRIPT" ]] || \
        error "Cluster topology reconciler is not executable: $CLUSTER_TOPOLOGY_SCRIPT"
    step "Reconciling control-plane scheduling and topology-dependent configuration..."
    "$CLUSTER_TOPOLOGY_SCRIPT" \
        --control-plane-schedulable "$CONTROL_PLANE_SCHEDULABLE" \
        --expected-node-count "$CLUSTER_NODE_COUNT"
    [[ -x "$LEGACY_RECONCILIATION_SCRIPT" ]] || error "Legacy-state reconciler is not executable: $LEGACY_RECONCILIATION_SCRIPT"
    "$LEGACY_RECONCILIATION_SCRIPT"
    if [[ "$INSTALL_APPS" == "true" ]]; then
        step "Creating the shared application namespace..."
        kubectl apply -f "$K8S_DIR/base/apps-namespace.yaml" >/dev/null
    fi
    step "Configuring the cluster-only $INTERNAL_DNS_ZONE service aliases..."
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
        longhorn_replicas="$("$CLUSTER_TOPOLOGY_SCRIPT" --print-longhorn-replicas)"
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
        "$CLUSTER_TOPOLOGY_SCRIPT" \
            --control-plane-schedulable "$CONTROL_PLANE_SCHEDULABLE" \
            --expected-node-count "$CLUSTER_NODE_COUNT"
        if [[ "$CONFIGURE_OFFSITE_BACKUPS" == "true" ]]; then
            step "Configuring recurring off-node Longhorn volume backups..."
            RUN_BACKUP_NOW=false "$K3S_BACKUP_SCRIPT"
        fi
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
            --set-string 'controller.tolerations[0].key=node-role.kubernetes.io/control-plane' \
            --set-string 'controller.tolerations[0].operator=Exists' \
            --set-string 'controller.tolerations[0].effect=NoSchedule' \
            --wait --timeout "$INGRESS_HELM_TIMEOUT"
    fi

    if [[ "$CONFIGURE_CLOUDFLARE" == "true" ]]; then
        [[ -x "$CLOUDFLARE_SCRIPT" ]] || error "Cloudflare configurator is not executable: $CLOUDFLARE_SCRIPT"
        if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
            cat >&2 <<'EOF'

Create a Cloudflare User API Token:
  1. Open https://dash.cloudflare.com/profile/api-tokens.
  2. Create a custom user token for the selected account.
  3. Grant Zone/DNS/Zone Settings/SSL/WAF/Cache edit, Access Apps and
     Organizations edit, Memberships read, and Registrar Domains read.
  4. For a new zone, scope zone permissions to all zones in the account.
  5. Paste the cfut_ token below; it is used only for this installer run.
EOF
            installer_prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare User API Token (cfut_...)"
            export CLOUDFLARE_API_TOKEN
        fi
        step "Configuring Cloudflare DNS and Origin TLS..."
        CLOUDFLARE_ENABLE_ACCESS=false "$CLOUDFLARE_SCRIPT"
    fi

    if [[ "$INSTALL_VAULT_STACK" == "true" ]]; then
        step "Installing HashiCorp Vault..."
        helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
        helm repo update > /dev/null 2>&1
        helm upgrade --install vault hashicorp/vault \
            --namespace infra \
            --version "$VAULT_CHART_VERSION" \
            --values "$VAULT_VALUES_FILE" \
            --set injector.enabled=false \
            --set server.ha.enabled=true \
            --set server.ha.raft.enabled=true \
            --set server.ha.replicas=1 \
            --set server.dataStorage.storageClass=longhorn \
            --set server.statefulSet.securityContext.pod.runAsNonRoot=true \
            --set server.statefulSet.securityContext.pod.runAsUser=100 \
            --set server.statefulSet.securityContext.pod.runAsGroup=1000 \
            --set server.statefulSet.securityContext.pod.fsGroup=1000 \
            --set-string server.statefulSet.securityContext.pod.seccompProfile.type=RuntimeDefault \
            --set server.statefulSet.securityContext.container.allowPrivilegeEscalation=false \
            --set 'server.statefulSet.securityContext.container.capabilities.drop[0]=ALL'

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
        kubectl delete role/bm-cluster-gitops-read rolebinding/bm-cluster-gitops-read \
            -n infra --ignore-not-found >/dev/null

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

        if [[ "$ROTATE_LOCAL_ADMIN_PASSWORDS" == "true" ]]; then
            [[ -x "$LOCAL_ADMIN_PASSWORD_ROTATION_SCRIPT" ]] || \
                error "Local administrator password rotation script is not executable: $LOCAL_ADMIN_PASSWORD_ROTATION_SCRIPT"
            step "Aligning local infrastructure superuser passwords..."
            printf '%s\n' "$LOCAL_ADMIN_PASSWORD" | \
                "$LOCAL_ADMIN_PASSWORD_ROTATION_SCRIPT" --password-stdin
            LOCAL_ADMIN_PASSWORD=""
            unset LOCAL_ADMIN_PASSWORD
        fi

        if [[ "$CONFIGURE_CLOUDFLARE" == "true" ]]; then
            step "Connecting Cloudflare Access to Keycloak..."
            "$CLOUDFLARE_SCRIPT"
        fi

        [[ -x "$GITLAB_CI_SCRIPT" ]] || error "GitLab CI configurator is not executable: $GITLAB_CI_SCRIPT"
        [[ -r "$GITLAB_TOKEN_LIBRARY" ]] || error "GitLab token helper is missing: $GITLAB_TOKEN_LIBRARY"
        # shellcheck source=scripts/lib/gitlab-admin-token.sh
        source "$GITLAB_TOKEN_LIBRARY"
        gitlab_acquire_admin_token
        if [[ "$CONFIGURE_REPOSITORY_SYNC" == "true" ]]; then
            prompt_github_admin_token
            IFS=',' read -r -a repository_mappings <<< "$REPOSITORY_SYNC_MAPPINGS"
            for repository_mapping in "${repository_mappings[@]}"; do
                github_slug="${repository_mapping%%=*}"
                gitlab_path="${repository_mapping#*=}"
                gitlab_group="${gitlab_path%%/*}"
                gitlab_project="${gitlab_path##*/}"
                gitlab_group_name="$gitlab_group"
                [[ "$gitlab_group" != "$GITLAB_GROUP_PATH" ]] || gitlab_group_name="$GITLAB_GROUP_NAME"
                step "Configuring and initializing $github_slug <-> $gitlab_path..."
                GITHUB_OWNER="${github_slug%%/*}" \
                GITHUB_REPOSITORY="${github_slug##*/}" \
                GITLAB_GROUP_PATH="$gitlab_group" \
                GITLAB_GROUP_NAME="$gitlab_group_name" \
                GITLAB_PROJECT_PATH="$gitlab_path" \
                GITLAB_PROJECT_NAME="$gitlab_project" \
                GITLAB_PUBLIC_URL="https://gitlab.$PLATFORM_DOMAIN" \
                CONFIGURE_REPOSITORY_SYNC=true \
                    "$GITLAB_CI_SCRIPT"
            done
        else
            GITLAB_PROJECT_PATH="${GITLAB_PROJECT_PATH:-$GITLAB_GROUP_PATH/$(basename "$SCRIPT_DIR")}" \
            GITLAB_PUBLIC_URL="https://gitlab.$PLATFORM_DOMAIN" \
            CONFIGURE_REPOSITORY_SYNC=false \
                "$GITLAB_CI_SCRIPT"
        fi
        gitlab_revoke_ephemeral_admin_token
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
            --values "$ARGOCD_VALUES_FILE" \
            --set-string "global.image.tag=$ARGOCD_IMAGE_TAG" \
            --wait --timeout "$ARGOCD_HELM_TIMEOUT"

        step "Applying GitLab-backed Argo CD applications..."
        for manifest in "${POST_ARGOCD_MANIFEST_ARRAY[@]}"; do
            kubectl apply -f "$K8S_DIR/$manifest"
        done
    fi
else
    warn "All Kubernetes feature groups were skipped."
fi

info ""
info "============================================="
info " Installation complete!"
info "============================================="

echo ""
echo "Cluster topology:"
echo "  Total nodes: $CLUSTER_NODE_COUNT"
echo "  Worker nodes: $PLANNED_WORKER_COUNT"
if [[ "$CONTROL_PLANE_SCHEDULABLE" == "true" ]]; then
    echo "  Control plane: controller-worker"
else
    echo "  Control plane: controller-only (NoSchedule)"
fi
echo "  Longhorn replicas: $((PLANNED_WORKER_COUNT > 0 ? PLANNED_WORKER_COUNT : 1))"
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
        echo "Service dashboard: https://dashboard.$PLATFORM_DOMAIN"
    fi

    echo ""
    echo "Retrieve credentials:"
    echo "  Keycloak SSO administrator: kubectl get secret -n infra keycloak-sso-credentials -o go-template='{{printf \"%s:%s\" (index .data \"SSO_BOOTSTRAP_USERNAME\" | base64decode) (index .data \"SSO_BOOTSTRAP_PASSWORD\" | base64decode)}}'"
    echo "  ArgoCD:   kubectl -n infra get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
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
