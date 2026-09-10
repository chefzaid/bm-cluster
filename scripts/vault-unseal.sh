#!/bin/bash
set -euo pipefail
set +x

NAMESPACE="${VAULT_NAMESPACE:-infra}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
UNSEAL_KEY_FILE="${VAULT_UNSEAL_KEY_FILE:-/var/lib/bm-cluster/vault-unseal-key}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
[[ -s "$UNSEAL_KEY_FILE" ]] || exit 0

status() {
  timeout "${VAULT_EXEC_TIMEOUT:-10s}" kubectl --request-timeout=10s exec -n "$NAMESPACE" "$1" -- env VAULT_CLIENT_TIMEOUT=5s VAULT_ADDR="$VAULT_ADDR" \
    vault status -format=json 2>/dev/null || true
}

# Explicit pods support isolated recovery tests. Timer runs discover all servers
# so losing vault-0 does not disable recovery on the surviving members.
if [[ -n "${VAULT_POD:-}" ]]; then
  phase="$(kubectl --request-timeout=10s get pod "$VAULT_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == Running ]] || exit 0
  pods=("$VAULT_POD")
else
  inventory="$(kubectl --request-timeout=10s get pods -n "$NAMESPACE" \
    -l app.kubernetes.io/name=vault,app.kubernetes.io/instance=vault,component=server -o json)"
  mapfile -t pods < <(jq -r '.items[] | select(.status.phase == "Running") |
    select(any(.metadata.ownerReferences[]?; .kind == "StatefulSet" and .name == "vault")) |
    .metadata.name | select(test("^vault-[0-9]+$"))' <<< "$inventory")
fi

failed=0
leader=""
pending=()
unseal() {
  local pod="$1" result
  # No key in process arguments, logs, or Kubernetes exec metadata.
  if ! jq -Rs '{key: sub("\n+$"; "")}' < "$UNSEAL_KEY_FILE" | \
    timeout "${VAULT_EXEC_TIMEOUT:-10s}" kubectl --request-timeout=10s exec -i -n "$NAMESPACE" "$pod" -- \
      env VAULT_CLIENT_TIMEOUT=5s VAULT_ADDR="$VAULT_ADDR" vault write -format=json sys/unseal - >/dev/null 2>&1; then
    echo "Vault unseal request failed on $pod." >&2
    return 1
  fi
  result="$(status "$pod")"
  if [[ -z "$result" ]] || ! jq -e '.sealed == false' <<< "$result" >/dev/null; then
    echo "Vault remains sealed or its status is unavailable on $pod after unseal." >&2
    return 1
  fi
}

# Unseal existing Raft members first. Never initialize an empty replacement.
for pod in "${pods[@]}"; do
  result="$(status "$pod")"
  [[ -n "$result" ]] || continue
  if jq -e '.initialized == false' <<< "$result" >/dev/null; then
    pending+=("$pod")
    continue
  fi
  if jq -e '.sealed == true' <<< "$result" >/dev/null; then
    if ! unseal "$pod"; then failed=1; continue; fi
  elif ! jq -e '.sealed == false' <<< "$result" >/dev/null; then
    continue
  fi
  # An unsealed standby forwards join requests to the active peer.
  leader="$pod"
done

for pod in "${pending[@]}"; do
  [[ -n "$leader" ]] || continue
  if ! timeout "${VAULT_EXEC_TIMEOUT:-10s}" kubectl --request-timeout=10s exec -n "$NAMESPACE" "$pod" -- env VAULT_CLIENT_TIMEOUT=5s VAULT_ADDR="$VAULT_ADDR" \
    vault operator raft join "http://$leader.vault-internal.$NAMESPACE.svc:8200" >/dev/null 2>&1; then
    echo "Vault Raft join is pending on $pod." >&2
    failed=1
    continue
  fi
  if ! unseal "$pod"; then failed=1; fi
done
exit "$failed"
