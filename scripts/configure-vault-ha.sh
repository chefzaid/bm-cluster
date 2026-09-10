#!/usr/bin/env bash
# Opt-in Helm reconciliation and guarded singleton-to-three-peer migration.
set -euo pipefail
set +x
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=config/platform.env
source "$REPO_ROOT/config/platform.env"
# shellcheck source=lib/vault-access.sh
source "$SCRIPT_DIR/lib/vault-access.sh"
NAMESPACE=infra
VALUES="$REPO_ROOT/config/vault-values.yaml"
CHART_VERSION="${VAULT_CHART_VERSION:-$DEFAULT_VAULT_CHART_VERSION}"
STATE_DIR="${VAULT_STATE_DIR:-/var/lib/bm-cluster}"
MIGRATE="${VAULT_HA_MIGRATE_EXISTING:-false}"
VERIFY=false
VAULT_POD=""
VAULT_ADDR=http://127.0.0.1:8200
error() { echo "[ERROR] $*" >&2; exit 1; }

vault_auth() {
  # The recovery token is streamed, never placed in exec arguments or output.
  { sudo cat "$STATE_DIR/vault-bootstrap-token"; printf '\n'; } |
    kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN VAULT_ADDR="$1"
      shift
      exec vault "$@"
    ' sh "$VAULT_ADDR" "$@"
}

select_peer() {
  VAULT_POD="$(vault_runtime_pod "$NAMESPACE")"
}

verify_ha() {
  local pods peers autopilot
  pods="$(kubectl get pods -n "$NAMESPACE" \
    -l app.kubernetes.io/name=vault,app.kubernetes.io/instance=vault,component=server -o json)" || return 1
  # Three Ready servers on three different hosts, owned by the expected release.
  jq -e '[.items[] | select(.metadata.name | test("^vault-[012]$")) |
      select(.metadata.deletionTimestamp == null and .spec.nodeName != null) |
      select(any(.metadata.ownerReferences[]?; .kind == "StatefulSet" and .name == "vault")) |
      select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
      .spec.nodeName] | length == 3 and (unique | length == 3)' <<< "$pods" >/dev/null || return 1
  select_peer || return 1
  peers="$(vault_auth operator raft list-peers -format=json 2>/dev/null)" || return 1
  jq -e '.data.config.servers | length == 3 and all(.voter == true) and
    ([.[].address | split(":")[0]] | unique | length == 3)' <<< "$peers" >/dev/null || return 1
  autopilot="$(vault_auth operator raft autopilot state -format=json 2>/dev/null)" || return 1
  jq -e '.healthy == true and .failure_tolerance >= 1 and (.voters | length == 3)
    and ([.servers[] | select(.healthy == true)] | length == 3)' <<< "$autopilot" >/dev/null
}

unseal_peers() {
  sudo env VAULT_NAMESPACE="$NAMESPACE" VAULT_UNSEAL_KEY_FILE="$STATE_DIR/vault-unseal-key" \
    KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}" bash "$SCRIPT_DIR/vault-unseal.sh"
}

wait_healthy() {
  local attempt
  for (( attempt=0; attempt<60; attempt++ )); do
    unseal_peers || true
    if verify_ha; then return 0; fi
    sleep 5
  done
  error "Vault has not reached three healthy Raft voters; existing pods and all PVCs are retained."
}

delete_exact_object() {
  local path="$1" uid="$2" propagation="$3"
  [[ -n "$uid" && "$uid" != null ]] || error "Missing object identity for guarded deletion"
  jq -n --arg uid "$uid" --arg propagation "$propagation" \
    '{apiVersion:"v1",kind:"DeleteOptions",propagationPolicy:$propagation,preconditions:{uid:$uid}}' |
    kubectl delete --raw "$path" -f - >/dev/null
}

rollout_changed_peers() {
  local state controller_uid revision pods candidate pod pod_uid replacement attempt replaced
  # OnDelete leaves healthy old pods running after Helm succeeds. Wait until
  # the StatefulSet controller has actually observed this desired template.
  for (( attempt=0; attempt<60; attempt++ )); do
    state="$(kubectl get statefulset vault -n "$NAMESPACE" -o json)"
    if jq -e '.status.observedGeneration >= .metadata.generation and
      (.status.updateRevision | type == "string" and length > 0)' <<< "$state" >/dev/null; then break; fi
    sleep 5
  done
  (( attempt < 60 )) || error "Vault controller has not observed the desired template; no routine pod replacement performed"
  controller_uid="$(jq -r '.metadata.uid' <<< "$state")"
  revision="$(jq -r '.status.updateRevision' <<< "$state")"
  [[ -n "$controller_uid" && "$controller_uid" != null ]] || error "Vault controller identity is missing"
  for (( replaced=0; replaced<3; replaced++ )); do
    state="$(kubectl get statefulset vault -n "$NAMESPACE" -o json)"
    jq -e --arg uid "$controller_uid" --arg revision "$revision" \
      '.metadata.uid == $uid and .status.observedGeneration >= .metadata.generation and
       .status.updateRevision == $revision' <<< "$state" >/dev/null || \
      error "Vault controller/template changed during rollout; remaining peers were retained"
    pods="$(kubectl get pods -n "$NAMESPACE" \
      -l app.kubernetes.io/name=vault,app.kubernetes.io/instance=vault,component=server -o json)"
    jq -e --arg revision "$revision" 'any(.items[];
      (.metadata.name | test("^vault-[012]$")) and
      any(.metadata.ownerReferences[]?; .kind == "StatefulSet" and .name == "vault") and
      .metadata.deletionTimestamp == null and .metadata.labels["controller-revision-hash"] != $revision)' \
      <<< "$pods" >/dev/null || return 0
    # Refresh Raft health immediately before every deletion. Its selected peer
    # is the current leader, so outdated standbys sort ahead of the active pod.
    verify_ha || error "Vault health changed before replacement; remaining peers were retained"
    candidate="$(jq -r --arg revision "$revision" --arg active "$VAULT_POD" '
      [.items[] | select(.metadata.name | test("^vault-[012]$")) |
       select(any(.metadata.ownerReferences[]?; .kind == "StatefulSet" and .name == "vault")) |
       select(.metadata.deletionTimestamp == null) |
       select(.metadata.labels["controller-revision-hash"] != $revision)] |
      sort_by(.metadata.name == $active, .metadata.name) | .[0] |
      [.metadata.name, .metadata.uid] | @tsv' <<< "$pods")"
    read -r pod pod_uid <<< "$candidate"
    echo "[INFO] Replacing Vault peer $pod on the observed desired revision"
    delete_exact_object "/api/v1/namespaces/$NAMESPACE/pods/$pod" "$pod_uid" Background
    for (( attempt=0; attempt<60; attempt++ )); do
      replacement="$(kubectl get pod "$pod" -n "$NAMESPACE" --ignore-not-found -o json)"
      if [[ -n "$replacement" ]] && jq -e --arg old "$pod_uid" --arg revision "$revision" \
        '.metadata.uid != $old and .metadata.deletionTimestamp == null and .status.phase == "Running" and
         .metadata.labels["controller-revision-hash"] == $revision' <<< "$replacement" >/dev/null; then break; fi
      sleep 5
    done
    (( attempt < 60 )) || error "Replacement $pod has not started on the desired revision; remaining peers and all PVCs were retained"
    wait_healthy
  done
}

save_migration_backup() {
  local remote_file backup
  select_peer || error "An initialized, unsealed Vault peer is required before migration"
  backup="$STATE_DIR/backups/vault-ha-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  sudo install -d -o root -g root -m 0700 "$backup"
  remote_file="$(kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu \
    'umask 077; mktemp /vault/data/.bm-ha-snapshot.XXXXXX')"
  [[ "$remote_file" =~ ^/vault/data/\.bm-ha-snapshot\.[A-Za-z0-9]+$ ]] || error "Unexpected snapshot path"
  if ! vault_auth operator raft snapshot save "$remote_file" >/dev/null; then
    kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- rm -f -- "$remote_file" >/dev/null
    error "Raft snapshot failed; no controller or pod has been replaced"
  fi
  kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- cat "$remote_file" |
    sudo tee "$backup/raft.snap" >/dev/null
  kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- rm -f -- "$remote_file" >/dev/null
  sudo test -s "$backup/raft.snap" || error "Empty Raft backup"
  kubectl get statefulset vault -n "$NAMESPACE" -o yaml | sudo tee "$backup/statefulset.yaml" >/dev/null
  helm get values vault -n "$NAMESPACE" -o yaml | sudo tee "$backup/helm-values.yaml" >/dev/null
  sudo chmod 0600 "$backup/raft.snap" "$backup/statefulset.yaml" "$backup/helm-values.yaml"
  sudo sha256sum "$backup/raft.snap" | sudo tee "$backup/SHA256SUMS" >/dev/null
  sudo sha256sum --check "$backup/SHA256SUMS" >/dev/null
  echo "[INFO] Private migration backup saved under $backup"
}

main() {
  local option nodes state existing=false template_migration=false pod_migration=false pod_uid state_uid attempt
  while (( $# )); do
    case "$1" in
      --namespace|--values|--chart-version)
        option="$1"; shift; (( $# )) || error "Missing value for $option"
        case "$option" in --namespace) NAMESPACE="$1" ;; --values) VALUES="$1" ;; --chart-version) CHART_VERSION="$1" ;; esac ;;
      --migrate-existing) MIGRATE=true ;;
      --verify) VERIFY=true ;;
      -h|--help)
        echo 'Usage: configure-vault-ha.sh [--namespace infra] [--values FILE] [--chart-version VERSION] [--migrate-existing | --verify]'
        echo 'Existing singleton migration requires an explicit maintenance gate and three Ready control planes.'
        return ;;
      *) error "Unknown option: $1" ;;
    esac
    shift
  done
  [[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || error "Invalid namespace"
  if [[ "$VERIFY" == true ]]; then verify_ha; return; fi
  [[ -r "$VALUES" ]] || error "Vault base values are unreadable"
  nodes="$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true -o json)"
  jq -e '[.items[] | select(.spec.unschedulable != true) |
    select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length >= 3' \
    <<< "$nodes" >/dev/null || error "Vault HA requires at least three Ready schedulable control-plane nodes"
  kubectl get storageclass longhorn local-path >/dev/null
  sudo install -d -o root -g root -m 0700 "$STATE_DIR"
  state="$(kubectl get statefulset vault -n "$NAMESPACE" --ignore-not-found -o json)"
  if [[ -n "$state" ]]; then
    existing=true
    if ! jq -e 'any(.spec.volumeClaimTemplates[]?; .metadata.name == "audit")' <<< "$state" >/dev/null; then
      template_migration=true
      jq -e '.spec.replicas == 1 and (.spec.volumeClaimTemplates | length == 1) and
        .spec.volumeClaimTemplates[0].metadata.name == "data" and
        any(.spec.template.spec.volumes[]?; .name == "audit" and .persistentVolumeClaim.claimName == "vault-audit")' \
        <<< "$state" >/dev/null || error "Unsupported existing Vault storage layout; inspect before migration"
    fi
    if kubectl get pod vault-0 -n "$NAMESPACE" -o json | jq -e \
      'any(.spec.volumes[]?; .name == "audit" and .persistentVolumeClaim.claimName == "vault-audit")' >/dev/null; then
      pod_migration=true
    fi
  elif helm status vault -n "$NAMESPACE" >/dev/null 2>&1; then
    error "Vault Helm release exists without its StatefulSet; recover the controller before continuing"
  elif kubectl get pvc -n "$NAMESPACE" -o json | jq -e \
    'any(.items[]; .metadata.name | test("^(data-vault-|audit-vault-)"))' >/dev/null; then
    error "Retained Vault PVCs exist without a release; restore the existing cluster before installing"
  fi
  if [[ "$template_migration" == true || "$pod_migration" == true ]]; then
    [[ "$MIGRATE" == true ]] || error "Existing Vault audit storage needs maintenance migration. Set VAULT_HA_MIGRATE_EXISTING=true after checking recovery backups."
    if ! sudo test -s "$STATE_DIR/vault-unseal-key" || ! sudo test -s "$STATE_DIR/vault-bootstrap-token"; then
      error "Host recovery material is required"
    fi
    save_migration_backup
  fi
  if [[ "$template_migration" == true ]]; then
    state_uid="$(jq -r '.metadata.uid' <<< "$state")"
    # Keep vault-0 running and retain data-vault-0 and vault-audit. The new
    # controller adopts it; OnDelete prevents replacement before quorum exists.
    delete_exact_object "/apis/apps/v1/namespaces/$NAMESPACE/statefulsets/vault" "$state_uid" Orphan
    kubectl wait --for=delete statefulset/vault -n "$NAMESPACE" --timeout=120s >/dev/null
  fi
  helm upgrade --install vault hashicorp/vault --namespace "$NAMESPACE" --version "$CHART_VERSION" \
    --values "$VALUES" --values "$REPO_ROOT/config/vault-ha-values.yaml"
  if [[ "$existing" == false ]]; then
    echo '[INFO] Vault HA pods created. Run configure-vault.sh to initialize once and join/unseal the peers.'
    return
  fi
  wait_healthy
  if [[ "$pod_migration" == true ]]; then
    # Both new servers are already unsealed, caught up, and voting. Only now
    # replace the old pod so it uses audit-vault-0; retain its original audit PVC.
    pod_uid="$(kubectl get pod vault-0 -n "$NAMESPACE" -o jsonpath='{.metadata.uid}')"
    verify_ha || error "Raft health changed; refusing to replace vault-0"
    delete_exact_object "/api/v1/namespaces/$NAMESPACE/pods/vault-0" "$pod_uid" Background
    for (( attempt=0; attempt<60; attempt++ )); do
      if kubectl get pod vault-0 -n "$NAMESPACE" -o json | jq -e --arg old "$pod_uid" \
        '.metadata.uid != $old and .status.phase == "Running"' >/dev/null; then break; fi
      sleep 5
    done
    (( attempt < 60 )) || error "Replacement vault-0 has not started; all PVCs remain retained"
    wait_healthy
    kubectl get pod vault-0 -n "$NAMESPACE" -o json | jq -e \
      'any(.spec.volumes[]?; .name == "audit" and .persistentVolumeClaim.claimName == "audit-vault-0")' >/dev/null || \
      error "vault-0 has not adopted its per-pod audit storage"
  fi
  rollout_changed_peers
  echo '[INFO] Vault has three healthy Raft voters. All original PVCs are retained.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
