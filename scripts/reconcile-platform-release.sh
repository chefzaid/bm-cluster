#!/usr/bin/env bash
# Shared Helm installation and readiness operations for platform entrypoints.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../config/platform.env
source "$REPO_ROOT/config/platform.env"

usage() {
    cat <<'EOF'
Usage: reconcile-platform-release.sh SERVICE [--namespace NAME]

Services: longhorn, vault, external-secrets, argocd, wait-vault-stack

Uses the shared platform.env versions/timeouts and their existing environment
overrides. Longhorn requires LONGHORN_REPLICA_COUNT from the topology policy.
VAULT_VALUES_FILE and ARGOCD_VALUES_FILE select rendered chart values.
HIGH_AVAILABILITY_ENABLED selects the existing Vault migration helper and the
External Secrets/Argo CD HA values. Vault readiness stays separate from install:
call wait-vault-stack after applying Vault resources and before bootstrapping it.
EOF
}
error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

SERVICE="${1:-}"
case "$SERVICE" in
    -h|--help) usage; exit 0 ;;
    longhorn|vault|external-secrets|argocd|wait-vault-stack) shift ;;
    *) usage >&2; exit 1 ;;
esac
NAMESPACE=infra
[[ "$SERVICE" != longhorn ]] || NAMESPACE=longhorn-system
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace) shift; [[ $# -gt 0 ]] || error "Missing namespace"; NAMESPACE="$1" ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1" ;;
    esac
    shift
done
[[ "$NAMESPACE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#NAMESPACE} -le 63 ]] || error "Invalid namespace"
HIGH_AVAILABILITY_ENABLED="${HIGH_AVAILABILITY_ENABLED:-false}"
[[ "$HIGH_AVAILABILITY_ENABLED" == true || "$HIGH_AVAILABILITY_ENABLED" == false ]] || error "Invalid HA mode"
command -v kubectl >/dev/null || error "kubectl is required"

if [[ "$SERVICE" == wait-vault-stack ]]; then
    kubectl wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 \
        -n "$NAMESPACE" --timeout="${VAULT_WAIT_TIMEOUT:-$DEFAULT_VAULT_WAIT_TIMEOUT}"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=external-secrets \
        -n "$NAMESPACE" --timeout="${VAULT_WAIT_TIMEOUT:-$DEFAULT_VAULT_WAIT_TIMEOUT}"
    exit 0
fi

command -v helm >/dev/null || error "helm is required"
values=()
case "$SERVICE" in
    longhorn)
        [[ "${LONGHORN_REPLICA_COUNT:-}" =~ ^[1-9][0-9]*$ ]] || error "Set LONGHORN_REPLICA_COUNT from the cluster topology policy"
        repository=longhorn
        repository_url=https://charts.longhorn.io
        ;;
    vault)
        VAULT_VALUES_FILE="${VAULT_VALUES_FILE:-$REPO_ROOT/config/vault-values.yaml}"
        [[ -r "$VAULT_VALUES_FILE" ]] || error "Vault values are missing: $VAULT_VALUES_FILE"
        repository=hashicorp
        repository_url=https://helm.releases.hashicorp.com
        ;;
    external-secrets)
        repository=external-secrets
        repository_url=https://charts.external-secrets.io
        values=(--values "$REPO_ROOT/config/external-secrets-values.yaml")
        [[ "$HIGH_AVAILABILITY_ENABLED" != true ]] || values+=(--values "$REPO_ROOT/config/external-secrets-ha-values.yaml")
        ;;
    argocd)
        ARGOCD_VALUES_FILE="${ARGOCD_VALUES_FILE:-$REPO_ROOT/config/argocd-values.yaml}"
        [[ -r "$ARGOCD_VALUES_FILE" ]] || error "Argo CD values are missing: $ARGOCD_VALUES_FILE"
        repository=argo
        repository_url=https://argoproj.github.io/argo-helm
        values=(--values "$ARGOCD_VALUES_FILE")
        [[ "$HIGH_AVAILABILITY_ENABLED" != true ]] || values+=(--values "$REPO_ROOT/config/argocd-ha-values.yaml")
        ;;
esac
helm repo add "$repository" "$repository_url" --force-update >/dev/null
helm repo update "$repository" --fail-on-repo-update-fail >/dev/null

case "$SERVICE" in
    longhorn)
        helm upgrade --install longhorn longhorn/longhorn \
            --namespace "$NAMESPACE" --create-namespace \
            --version "${LONGHORN_CHART_VERSION:-$DEFAULT_LONGHORN_CHART_VERSION}" \
            --set "defaultSettings.defaultReplicaCount=$LONGHORN_REPLICA_COUNT" \
            --set "persistence.defaultClassReplicaCount=$LONGHORN_REPLICA_COUNT" \
            --set defaultSettings.defaultDataLocality=best-effort \
            --set defaultSettings.concurrentAutomaticEngineUpgradePerNodeLimit=1 \
            --set defaultSettings.storageMinimalAvailablePercentage=20 \
            --set defaultSettings.storageOverProvisioningPercentage=110 \
            --wait --timeout "${LONGHORN_HELM_TIMEOUT:-$DEFAULT_LONGHORN_HELM_TIMEOUT}"
        kubectl patch storageclass longhorn -p \
            '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
        kubectl patch storageclass local-path -p \
            '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
        kubectl wait --for=condition=ready pod -l app=longhorn-manager \
            -n "$NAMESPACE" --timeout="${LONGHORN_POD_WAIT_TIMEOUT:-$DEFAULT_LONGHORN_POD_WAIT_TIMEOUT}"
        ;;
    vault)
        if [[ "$HIGH_AVAILABILITY_ENABLED" == true ]]; then
            exec "$SCRIPT_DIR/configure-vault-ha.sh" --namespace "$NAMESPACE" \
                --values "$VAULT_VALUES_FILE" --chart-version "${VAULT_CHART_VERSION:-$DEFAULT_VAULT_CHART_VERSION}"
        fi
        # A sealed Vault cannot pass Helm --wait before its separate bootstrap.
        helm upgrade --install vault hashicorp/vault \
            --namespace "$NAMESPACE" --version "${VAULT_CHART_VERSION:-$DEFAULT_VAULT_CHART_VERSION}" \
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
        ;;
    external-secrets)
        helm upgrade --install external-secrets external-secrets/external-secrets \
            --namespace "$NAMESPACE" --version "${EXTERNAL_SECRETS_CHART_VERSION:-$DEFAULT_EXTERNAL_SECRETS_CHART_VERSION}" \
            "${values[@]}" --set installCRDs=true \
            --wait --timeout "${EXTERNAL_SECRETS_HELM_TIMEOUT:-$DEFAULT_EXTERNAL_SECRETS_HELM_TIMEOUT}"
        ;;
    argocd)
        helm upgrade --install argocd argo/argo-cd \
            --namespace "$NAMESPACE" --version "${ARGOCD_CHART_VERSION:-$DEFAULT_ARGOCD_CHART_VERSION}" \
            "${values[@]}" --set-string "global.image.tag=${ARGOCD_IMAGE_TAG:-$DEFAULT_ARGOCD_IMAGE_TAG}" \
            --wait --timeout "${ARGOCD_HELM_TIMEOUT:-$DEFAULT_ARGOCD_HELM_TIMEOUT}"
        ;;
esac
