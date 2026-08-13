#!/bin/bash
set -euo pipefail

NAMESPACE="${VAULT_NAMESPACE:-infra}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
UNSEAL_KEY_FILE="${VAULT_UNSEAL_KEY_FILE:-/var/lib/bm-cluster/vault-unseal-key}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

[[ -s "$UNSEAL_KEY_FILE" ]] || exit 0

phase="$(kubectl get pod "$VAULT_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$phase" == "Running" ]] || exit 0

status_json="$(kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- \
  env VAULT_ADDR="$VAULT_ADDR" vault status -format=json 2>/dev/null || true)"
[[ -n "$status_json" ]] || exit 0

sealed="$(jq -r '.sealed // empty' <<<"$status_json")"
[[ "$sealed" == "true" ]] || exit 0

unseal_key="$(<"$UNSEAL_KEY_FILE")"
printf '%s\n' "$unseal_key" | kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- \
  env VAULT_ADDR="$VAULT_ADDR" vault operator unseal >/dev/null
unset unseal_key
