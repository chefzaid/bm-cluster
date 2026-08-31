#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-infra}"
DELETE_LEGACY_PVCS="${DELETE_LEGACY_PVCS:-true}"

[[ "$DELETE_LEGACY_PVCS" =~ ^(true|false)$ ]] || {
  printf '[ERROR] DELETE_LEGACY_PVCS must be true or false.\n' >&2
  exit 1
}
for command_name in jq kubectl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '[ERROR] %s is required.\n' "$command_name" >&2
    exit 1
  }
done

kubectl delete role/bm-cluster-gitops-read rolebinding/bm-cluster-gitops-read \
  -n "$NAMESPACE" --ignore-not-found >/dev/null

mapfile -t completed_manual_jobs < <(
  kubectl get jobs -n "$NAMESPACE" -o json | jq -r '
    .items[]
    | select((.status.succeeded // 0) > 0)
    | select(.metadata.name | startswith("gitlab-registry-retention-manual-"))
    | .metadata.name
  '
)
for job in "${completed_manual_jobs[@]}"; do
  kubectl delete job "$job" -n "$NAMESPACE" --ignore-not-found >/dev/null
done

if [[ "$DELETE_LEGACY_PVCS" == "true" ]]; then
  legacy_pvcs=(
    postgres-data
    postgres-pvc
    zookeeper-data-zookeeper-0
    zookeeper-log-zookeeper-0
  )
  pod_claims="$(kubectl get pods -A -o json | jq -r '.items[].spec.volumes[]?.persistentVolumeClaim.claimName // empty' | sort -u)"
  for claim in "${legacy_pvcs[@]}"; do
    kubectl get pvc "$claim" -n "$NAMESPACE" >/dev/null 2>&1 || continue
    if grep -Fxq "$claim" <<< "$pod_claims"; then
      printf '[ERROR] Refusing to delete legacy PVC %s because a pod still mounts it.\n' "$claim" >&2
      exit 1
    fi
    kubectl delete pvc "$claim" -n "$NAMESPACE"
  done
fi

printf '[INFO] Superseded RBAC, completed manual jobs, and unmounted legacy storage are reconciled.\n'
