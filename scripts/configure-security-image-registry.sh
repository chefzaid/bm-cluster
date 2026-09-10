#!/usr/bin/env bash
# Provision a project-scoped, pull-only token for patched platform images.
set -euo pipefail
set +x
umask 077
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
# shellcheck source=scripts/lib/gitlab-admin-token.sh
source "$script_dir/lib/gitlab-admin-token.sh"
# shellcheck source=lib/vault-access.sh
source "$script_dir/lib/vault-access.sh"
vault_pod="$(vault_runtime_pod infra)"
work_dir="$(mktemp -d /tmp/bm-security-registry.XXXXXX)"
cleanup() {
  rm -r -- "$work_dir"
  gitlab_revoke_ephemeral_admin_token
}
trap cleanup EXIT
gitlab_acquire_admin_token
vault_token="$(sudo cat "${VAULT_BOOTSTRAP_TOKEN_FILE:-/var/lib/bm-cluster/vault-bootstrap-token}")"
{ printf '%s\n' "$vault_token"; } | kubectl exec -i -n infra "$vault_pod" -- sh -ceu '
  IFS= read -r VAULT_TOKEN
  export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
  vault kv get -format=json secret/infra/gitlab
' > "$work_dir/stored.json"
registry_username="$(jq -r '.data.data.registry_pull_username // empty' "$work_dir/stored.json")"
registry_token="$(jq -r '.data.data.registry_pull_token // empty' "$work_dir/stored.json")"
gitlab_ip="$(kubectl get service gitlab -n infra -o jsonpath='{.spec.clusterIP}')"
if [[ -n "$registry_username" && -n "$registry_token" ]]; then
  printf 'user = "%s:%s"\n' "$registry_username" "$registry_token" > "$work_dir/registry.conf"
  if curl --config "$work_dir/registry.conf" --fail --silent --show-error --get \
    --data-urlencode service=container_registry \
    --data-urlencode "scope=repository:${GITLAB_PROJECT_PATH:-swirlit/bm-cluster}/security/postgres-client:pull" \
    "http://$gitlab_ip/jwt/auth" > "$work_dir/auth.json"; then
    info "Existing platform registry pull token is valid"
    exit 0
  fi
fi
printf 'header = "PRIVATE-TOKEN: %s"\n' "$GITLAB_ADMIN_TOKEN" > "$work_dir/api.conf"
project_path="$(jq -rn --arg value "${GITLAB_PROJECT_PATH:-swirlit/bm-cluster}" '$value|@uri')"
project_id="$(curl --config "$work_dir/api.conf" --fail --silent --show-error \
  "http://$gitlab_ip/api/v4/projects/$project_path" | jq -er '.id')"
jq -n --arg expiry "$(date -u -d '+364 days' +%Y-%m-%dT00:00:00Z)" \
  '{name:"bm-cluster-runtime-images",scopes:["read_registry"],expires_at:$expiry}' > "$work_dir/request.json"
curl --config "$work_dir/api.conf" --fail --silent --show-error --request POST \
  --header 'Content-Type: application/json' --data-binary "@$work_dir/request.json" \
  "http://$gitlab_ip/api/v4/projects/$project_id/deploy_tokens" > "$work_dir/token.json"
jq '{registry_pull_username:.username,registry_pull_token:.token,registry_pull_token_id:(.id|tostring)}' \
  "$work_dir/token.json" > "$work_dir/vault.json"
{ printf '%s\n' "$vault_token"; cat "$work_dir/vault.json"; } | kubectl exec -i -n infra "$vault_pod" -- sh -ceu '
  IFS= read -r VAULT_TOKEN
  export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
  vault kv patch secret/infra/gitlab - >/dev/null
'
info "Stored the platform registry pull token in Vault; External Secrets refreshes its projections"
