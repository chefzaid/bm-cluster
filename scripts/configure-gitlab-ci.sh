#!/usr/bin/env bash
set -euo pipefail
umask 077

NAMESPACE="${NAMESPACE:-infra}"
RUNNER_NAMESPACE="${RUNNER_NAMESPACE:-gitlab-runners}"
GITLAB_URL="${GITLAB_URL:-}"
GITLAB_GROUP_PATH="${GITLAB_GROUP_PATH:-swirlit}"
GITLAB_GROUP_NAME="${GITLAB_GROUP_NAME:-SwirlIT}"
GITLAB_PROJECT_PATH="${GITLAB_PROJECT_PATH:-$GITLAB_GROUP_PATH/bm-cluster}"
GITLAB_PROJECT_NAME="${GITLAB_PROJECT_NAME:-bm-cluster}"
RUNNER_DESCRIPTION="${RUNNER_DESCRIPTION:-bm-cluster-kubernetes}"
RUNNER_TAGS="${RUNNER_TAGS:-bm-cluster,kubernetes}"
RETENTION_TOKEN_NAME="${RETENTION_TOKEN_NAME:-bm-cluster-registry-retention}"
RETENTION_TOKEN_LIFETIME_DAYS="${RETENTION_TOKEN_LIFETIME_DAYS:-364}"
# GitLab requires max_artifacts_size to be a positive signed 32-bit integer;
# unlike its ingress setting, zero means zero bytes rather than unlimited. Use
# the largest value GitLab can store so artifact uploads are constrained only
# by the instance's available storage.
MAX_ARTIFACTS_SIZE_MB=2147483647
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_TOKEN_FILE="${VAULT_BOOTSTRAP_TOKEN_FILE:-/var/lib/bm-cluster/vault-bootstrap-token}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

for command_name in curl jq kubectl sudo; do
  command -v "$command_name" >/dev/null || fail "$command_name is required"
done

if [[ -z "$GITLAB_URL" ]]; then
  gitlab_service_ip="$(kubectl get service gitlab -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')"
  [[ -n "$gitlab_service_ip" ]] || fail "Unable to resolve the internal GitLab service address"
  GITLAB_URL="http://$gitlab_service_ip"
fi

[[ -n "${GITLAB_ADMIN_TOKEN:-}" ]] || fail "Set GITLAB_ADMIN_TOKEN to an API token that can create projects and instance runners"
sudo test -s "$VAULT_TOKEN_FILE" || fail "Vault bootstrap token is missing from $VAULT_TOKEN_FILE"

work_dir="$(mktemp -d /tmp/bm-gitlab-ci.XXXXXX)"
trap 'rm -r -- "$work_dir"; unset GITLAB_ADMIN_TOKEN GITLAB_RETENTION_TOKEN vault_token runner_token retention_api_token elastic_ci_username elastic_ci_password' EXIT
api_config="$work_dir/curl-api.conf"
printf 'silent\nshow-error\nheader = "PRIVATE-TOKEN: %s"\n' "$GITLAB_ADMIN_TOKEN" > "$api_config"

api_json() {
  local method="$1" path="$2"
  shift 2
  curl --config "$api_config" --fail-with-body --request "$method" \
    "$GITLAB_URL/api/v4/$path" "$@"
}

upsert_project_variable() {
  local key="$1" value="$2" encoded_key status
  encoded_key="$(jq -rn --arg value "$key" '$value|@uri')"
  status="$(curl --config "$api_config" --request GET \
    --output /dev/null --write-out '%{http_code}' \
    "$GITLAB_URL/api/v4/projects/$project_id/variables/$encoded_key")"
  case "$status" in
    200)
      api_json PUT "projects/$project_id/variables/$encoded_key" \
        --form-string "value=$value" \
        --form-string variable_type=env_var \
        --form-string protected=true \
        --form-string masked=true \
        --form-string raw=true >/dev/null
      ;;
    404)
      api_json POST "projects/$project_id/variables" \
        --form-string "key=$key" \
        --form-string "value=$value" \
        --form-string variable_type=env_var \
        --form-string protected=true \
        --form-string masked=true \
        --form-string raw=true >/dev/null
      ;;
    *)
      fail "GitLab returned HTTP $status while reconciling CI variable $key"
      ;;
  esac
}

api_json PUT application/settings \
  --form-string "max_artifacts_size=$MAX_ARTIFACTS_SIZE_MB" >/dev/null

encoded_group_path="$(jq -rn --arg value "$GITLAB_GROUP_PATH" '$value|@uri')"
group_status="$(curl --config "$api_config" --request GET \
  --output "$work_dir/group.json" --write-out '%{http_code}' \
  "$GITLAB_URL/api/v4/groups/$encoded_group_path")"
case "$group_status" in
  200)
    info "Using existing GitLab group $GITLAB_GROUP_PATH"
    ;;
  404)
    info "Creating GitLab group $GITLAB_GROUP_PATH for the container dependency proxy"
    jq -n --arg name "$GITLAB_GROUP_NAME" --arg path "$GITLAB_GROUP_PATH" \
      '{name:$name,path:$path,visibility:"public"}' > "$work_dir/create-group.json"
    api_json POST groups --header 'Content-Type: application/json' \
      --data-binary "@$work_dir/create-group.json" > "$work_dir/group.json"
    ;;
  *)
    cat "$work_dir/group.json" >&2
    fail "GitLab returned HTTP $group_status while looking up $GITLAB_GROUP_PATH"
    ;;
esac
group_id="$(jq -er '.id' "$work_dir/group.json")"
jq -n --arg group_path "$GITLAB_GROUP_PATH" \
  '{query:"mutation($groupPath: ID!) { updateDependencyProxySettings(input: {enabled: true, groupPath: $groupPath}) { dependencyProxySetting { enabled } errors } }",variables:{groupPath:$group_path}}' \
  > "$work_dir/dependency-proxy.json"
curl --config "$api_config" --fail-with-body \
  --header 'Content-Type: application/json' \
  --data-binary "@$work_dir/dependency-proxy.json" \
  "$GITLAB_URL/api/graphql" > "$work_dir/dependency-proxy-response.json"
if ! jq -e '((.errors // []) | length) == 0 and ((.data.updateDependencyProxySettings.errors // []) | length) == 0 and .data.updateDependencyProxySettings.dependencyProxySetting.enabled == true' \
  "$work_dir/dependency-proxy-response.json" >/dev/null; then
  cat "$work_dir/dependency-proxy-response.json" >&2
  fail "GitLab did not enable the dependency proxy for $GITLAB_GROUP_PATH"
fi

encoded_project_path="$(jq -rn --arg value "$GITLAB_PROJECT_PATH" '$value|@uri')"
project_json="$(curl --config "$api_config" --request GET \
  --output "$work_dir/project.json" --write-out '%{http_code}' \
  "$GITLAB_URL/api/v4/projects/$encoded_project_path")"

case "$project_json" in
  200)
    info "Using existing GitLab project $GITLAB_PROJECT_PATH"
    ;;
  404)
    info "Creating GitLab project $GITLAB_PROJECT_PATH"
    jq -n \
      --arg name "$GITLAB_PROJECT_NAME" \
      --arg path "${GITLAB_PROJECT_PATH##*/}" \
      --argjson namespace_id "$group_id" \
      '{name:$name,path:$path,namespace_id:$namespace_id,visibility:"public",container_registry_access_level:"private",package_registry_access_level:"private",builds_access_level:"enabled"}' \
      > "$work_dir/create-project.json"
    api_json POST projects --header 'Content-Type: application/json' \
      --data-binary "@$work_dir/create-project.json" > "$work_dir/project.json"
    ;;
  *)
    cat "$work_dir/project.json" >&2
    fail "GitLab returned HTTP $project_json while looking up $GITLAB_PROJECT_PATH"
    ;;
esac

project_id="$(jq -er '.id' "$work_dir/project.json")"
jq -n \
  '{visibility:"public",container_registry_access_level:"private",package_registry_access_level:"private",builds_access_level:"enabled"}' \
  > "$work_dir/update-project.json"
api_json PUT "projects/$project_id" --header 'Content-Type: application/json' \
  --data-binary "@$work_dir/update-project.json" > /dev/null

jq -n \
  '{container_expiration_policy_attributes:{enabled:true,cadence:"1d",older_than:"1095d",keep_n:null,name_regex:".*",name_regex_keep:null}}' \
  > "$work_dir/registry-retention-policy.json"
api_json GET "groups/$group_id/projects?include_subgroups=true&with_shared=false&per_page=100" \
  > "$work_dir/group-projects.json"
mapfile -t group_project_ids < <(jq -r '.[].id' "$work_dir/group-projects.json")
for group_project_id in "${group_project_ids[@]}"; do
  api_json PUT "projects/$group_project_id" --header 'Content-Type: application/json' \
    --data-binary "@$work_dir/registry-retention-policy.json" > /dev/null
done
info "Configured three-year container image retention for ${#group_project_ids[@]} projects"

vault_token="$(sudo cat "$VAULT_TOKEN_FILE")"
elastic_ci_username="$({ printf '%s\n' "$vault_token"; } | \
  kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
    IFS= read -r VAULT_TOKEN
    export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
    vault kv get -field=ci_observer_username secret/infra/elasticsearch
  ')"
elastic_ci_password="$({ printf '%s\n' "$vault_token"; } | \
  kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
    IFS= read -r VAULT_TOKEN
    export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
    vault kv get -field=ci_observer_password secret/infra/elasticsearch
  ')"
[[ -n "$elastic_ci_username" && -n "$elastic_ci_password" ]] || \
  fail "Elastic CI observer credentials are missing from Vault"
upsert_project_variable ELASTICSEARCH_CI_USERNAME "$elastic_ci_username"
upsert_project_variable ELASTICSEARCH_CI_PASSWORD "$elastic_ci_password"
info "Configured protected, masked Elastic observer variables for delivery verification"

runner_token="$({ printf '%s\n' "$vault_token"; } | \
  kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
    IFS= read -r VAULT_TOKEN
    export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
    vault kv get -field=runner_token secret/infra/gitlab 2>/dev/null || true
  ')"
retention_api_token="${GITLAB_RETENTION_TOKEN:-}"
if [[ -z "$retention_api_token" ]]; then
  retention_api_token="$({ printf '%s\n' "$vault_token"; } | \
    kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
      vault kv get -field=retention_api_token secret/infra/gitlab 2>/dev/null || true
    ')"
fi

if [[ -n "$retention_api_token" ]]; then
  retention_token_status="$(curl --silent --show-error --request GET \
    --output /dev/null --write-out '%{http_code}' \
    --header "PRIVATE-TOKEN: $retention_api_token" \
    "$GITLAB_URL/api/v4/groups/$encoded_group_path/projects?per_page=1")"
  if [[ "$retention_token_status" != "200" ]]; then
    info "The stored registry-retention API token is stale and will be replaced"
    retention_api_token=""
  fi
fi

if [[ -z "$retention_api_token" ]]; then
  retention_token_expires_at="$(date -u -d "+$RETENTION_TOKEN_LIFETIME_DAYS days" +%F)"
  info "Creating a group-scoped GitLab registry-retention API token"
  api_json POST "groups/$group_id/access_tokens" \
    --form-string "name=$RETENTION_TOKEN_NAME" \
    --form-string "expires_at=$retention_token_expires_at" \
    --form-string "access_level=40" \
    --form-string "scopes[]=api" \
    > "$work_dir/retention-token.json"
  retention_api_token="$(jq -er '.token' "$work_dir/retention-token.json")"
fi

api_json GET "projects/$project_id/runners?type=project_type&per_page=100" > "$work_dir/legacy-runners.json"
mapfile -t legacy_runner_ids < <(
  jq -r --arg description "$RUNNER_DESCRIPTION" \
    '.[] | select(.description==$description) | .id' "$work_dir/legacy-runners.json"
)

api_json GET "runners/all?type=instance_type&per_page=100" > "$work_dir/runners.json"
runner_id="$(jq -r --arg description "$RUNNER_DESCRIPTION" '.[] | select(.description==$description) | .id' "$work_dir/runners.json" | head -n 1)"

if [[ -n "$runner_token" ]]; then
  runner_token_status="$(curl --silent --show-error --request POST \
    --output /dev/null --write-out '%{http_code}' \
    --form-string "token=$runner_token" "$GITLAB_URL/api/v4/runners/verify")"
  if [[ "$runner_token_status" != "200" ]]; then
    info "The stored runner token is stale and will be replaced"
    runner_token=""
  fi
fi

if [[ -n "$runner_id" ]] &&
   { [[ -z "$runner_token" ]] || (( ${#legacy_runner_ids[@]} > 0 )); }; then
  info "Resetting the stored token for GitLab runner $RUNNER_DESCRIPTION"
  runner_token="$(api_json POST "runners/$runner_id/reset_authentication_token" | jq -er '.token')"
elif [[ -z "$runner_id" ]]; then
  info "Creating instance-scoped GitLab runner $RUNNER_DESCRIPTION"
  api_json POST user/runners \
    --form-string runner_type=instance_type \
    --form-string "description=$RUNNER_DESCRIPTION" \
    --form-string "tag_list=$RUNNER_TAGS" \
    --form-string run_untagged=false \
    --form-string locked=false \
    > "$work_dir/runner.json"
  runner_id="$(jq -er '.id' "$work_dir/runner.json")"
  runner_token="$(jq -er '.token' "$work_dir/runner.json")"
fi

[[ -n "$runner_token" ]] || fail "The GitLab runner exists but its authentication token is not available in Vault"

api_json PUT "runners/$runner_id" \
  --form-string "tag_list=$RUNNER_TAGS" \
  --form-string run_untagged=false \
  --form-string locked=false > /dev/null

for legacy_runner_id in "${legacy_runner_ids[@]}"; do
  info "Removing legacy project-scoped runner $legacy_runner_id"
  api_json DELETE "runners/$legacy_runner_id" > /dev/null
done

if { printf '%s\n' "$vault_token"; } | kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
  IFS= read -r VAULT_TOKEN
  export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
  vault kv get secret/infra/gitlab >/dev/null 2>&1
'; then
  { printf '%s\n%s\n%s\n' "$vault_token" "$runner_token" "$retention_api_token"; } | \
    kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
      IFS= read -r VAULT_TOKEN
      IFS= read -r runner_token
      IFS= read -r retention_api_token
      export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
      vault kv patch secret/infra/gitlab \
        runner_token="$runner_token" \
        retention_api_token="$retention_api_token" >/dev/null
    '
else
  { printf '%s\n%s\n%s\n' "$vault_token" "$runner_token" "$retention_api_token"; } | \
    kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
      IFS= read -r VAULT_TOKEN
      IFS= read -r runner_token
      IFS= read -r retention_api_token
      export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
      vault kv put secret/infra/gitlab \
        runner_token="$runner_token" \
        retention_api_token="$retention_api_token" >/dev/null
    '
fi

if kubectl get externalsecret gitlab-runner-token -n "$RUNNER_NAMESPACE" >/dev/null 2>&1; then
  kubectl annotate externalsecret gitlab-runner-token -n "$RUNNER_NAMESPACE" \
    force-sync="$(date +%s)" --overwrite >/dev/null
  kubectl wait --for=condition=Ready externalsecret/gitlab-runner-token \
    -n "$RUNNER_NAMESPACE" --timeout=3m >/dev/null
  kubectl rollout restart deployment/gitlab-runner -n "$RUNNER_NAMESPACE" >/dev/null
  kubectl rollout status deployment/gitlab-runner -n "$RUNNER_NAMESPACE" --timeout=5m >/dev/null
fi

if kubectl get externalsecret gitlab-registry-retention-token -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl annotate externalsecret gitlab-registry-retention-token -n "$NAMESPACE" \
    force-sync="$(date +%s)" --overwrite >/dev/null
  kubectl wait --for=condition=Ready externalsecret/gitlab-registry-retention-token \
    -n "$NAMESPACE" --timeout=3m >/dev/null
fi

GITLAB_URL="$GITLAB_URL" "$REPOSITORY_ROOT/scripts/configure-repository-sync.sh"

info "GitLab project, bidirectional GitHub sync, package/container registries, three-year retention, and instance-scoped Kubernetes runner are configured"
