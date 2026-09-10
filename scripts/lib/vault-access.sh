#!/usr/bin/env bash
# Select a running, initialized, unsealed member; prefer the active Raft peer.
vault_runtime_pod() {
  local namespace="${1:-infra}" inventory pod result standby=""
  inventory="$(kubectl --request-timeout=10s get pods -n "$namespace" \
    -l app.kubernetes.io/name=vault,app.kubernetes.io/instance=vault,component=server -o json)" || return 1
  while IFS= read -r pod; do
    result="$(timeout "${VAULT_EXEC_TIMEOUT:-10s}" kubectl --request-timeout=10s exec -n "$namespace" "$pod" -- env VAULT_CLIENT_TIMEOUT=5s VAULT_ADDR=http://127.0.0.1:8200 \
      vault status -format=json 2>/dev/null || true)"
    if jq -e '.initialized == true and .sealed == false' <<< "$result" >/dev/null 2>&1; then
      if jq -e '.is_self == true' <<< "$result" >/dev/null; then printf '%s\n' "$pod"; return; fi
      standby="$pod"
    fi
  done < <(jq -r '.items[] | select(.status.phase == "Running" and .metadata.deletionTimestamp == null) |
    select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
    select(any(.metadata.ownerReferences[]?; .kind == "StatefulSet" and .name == "vault")) |
    .metadata.name | select(test("^vault-[0-9]+$"))' <<< "$inventory")
  if [[ -n "$standby" ]]; then printf '%s\n' "$standby"; return; fi
  echo 'No initialized, unsealed Vault peer is available.' >&2
  return 1
}
