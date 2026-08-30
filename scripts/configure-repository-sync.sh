#!/usr/bin/env bash
set -euo pipefail
umask 077

REPOSITORY_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
REPOSITORY_NAME="${REPOSITORY_NAME:-$(basename "$REPOSITORY_ROOT")}"
GITLAB_PROJECT_PATH="${GITLAB_PROJECT_PATH:-swirlit/$REPOSITORY_NAME}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.swirlit.dev}"
GITHUB_OWNER="${GITHUB_OWNER:-chefzaid}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$REPOSITORY_NAME}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
SYNC_TOKEN_NAME="${SYNC_TOKEN_NAME:-github-actions-sync}"
SYNC_TOKEN_LIFETIME_DAYS="${SYNC_TOKEN_LIFETIME_DAYS:-364}"
SYNC_TOKEN_ROTATION_DAYS="${SYNC_TOKEN_ROTATION_DAYS:-90}"
ROTATE_SYNC_TOKEN="${ROTATE_SYNC_TOKEN:-false}"
TEST_REPOSITORY_SYNC_WEBHOOK="${TEST_REPOSITORY_SYNC_WEBHOOK:-false}"

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

for command_name in curl date git jq python3; do
  command -v "$command_name" >/dev/null || fail "$command_name is required"
done

[[ -n "${GITLAB_ADMIN_TOKEN:-}" ]] ||   fail "Set GITLAB_ADMIN_TOKEN to an API token that can manage $GITLAB_PROJECT_PATH"
[[ -n "${GITHUB_ADMIN_TOKEN:-}" ]] ||   fail "Set GITHUB_ADMIN_TOKEN to a token that can manage actions secrets and dispatch workflows for $GITHUB_OWNER/$GITHUB_REPOSITORY"

work_dir="$(mktemp -d "/tmp/$REPOSITORY_NAME-repository-sync.XXXXXX")"
trap 'rm -r -- "$work_dir"; unset GITLAB_ADMIN_TOKEN GITHUB_ADMIN_TOKEN sync_token' EXIT
gitlab_config="$work_dir/gitlab-curl.conf"
github_config="$work_dir/github-curl.conf"
printf 'silent\nshow-error\nheader = "PRIVATE-TOKEN: %s"\n' "$GITLAB_ADMIN_TOKEN" > "$gitlab_config"
printf 'silent\nshow-error\nheader = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2022-11-28"\n'   "$GITHUB_ADMIN_TOKEN" > "$github_config"

gitlab_api() {
  local method="$1" path="$2"
  shift 2
  curl --config "$gitlab_config" --fail-with-body --request "$method"     "$GITLAB_URL/api/v4/$path" "$@"
}

github_api() {
  local method="$1" path="$2"
  shift 2
  curl --config "$github_config" --fail-with-body --request "$method"     "$GITHUB_API_URL/$path" "$@"
}

encrypt_github_secret() {
  local public_key="$1" secret_value="$2"
  { printf '%s\n' "$public_key"; printf '%s' "$secret_value"; } | python3 -c '
import base64
import ctypes
import ctypes.util
import sys

encoded_key = sys.stdin.buffer.readline().strip()
secret = sys.stdin.buffer.read()
library_name = ctypes.util.find_library("sodium")
if not library_name:
    raise SystemExit("libsodium is required to encrypt GitHub Actions secrets")
sodium = ctypes.cdll.LoadLibrary(library_name)
if sodium.sodium_init() < 0:
    raise SystemExit("libsodium initialization failed")

public_key = base64.b64decode(encoded_key, validate=True)
if len(public_key) != 32:
    raise SystemExit("GitHub returned an invalid Actions public key")

output = (ctypes.c_ubyte * (len(secret) + 48))()
message = (ctypes.c_ubyte * len(secret)).from_buffer_copy(secret)
key = (ctypes.c_ubyte * len(public_key)).from_buffer_copy(public_key)
sodium.crypto_box_seal.argtypes = [
    ctypes.POINTER(ctypes.c_ubyte),
    ctypes.POINTER(ctypes.c_ubyte),
    ctypes.c_ulonglong,
    ctypes.POINTER(ctypes.c_ubyte),
]
sodium.crypto_box_seal.restype = ctypes.c_int
if sodium.crypto_box_seal(output, message, len(secret), key) != 0:
    raise SystemExit("GitHub secret encryption failed")
print(base64.b64encode(bytes(output)).decode("ascii"))
'
}

encoded_project_path="$(jq -rn --arg value "$GITLAB_PROJECT_PATH" '$value|@uri')"
gitlab_api GET "projects/$encoded_project_path" > "$work_dir/project.json"
project_id="$(jq -er '.id' "$work_dir/project.json")"

github_api GET "repos/$GITHUB_OWNER/$GITHUB_REPOSITORY" > "$work_dir/github-repository.json"
github_api GET "repos/$GITHUB_OWNER/$GITHUB_REPOSITORY/actions/secrets?per_page=100"   > "$work_dir/github-secrets.json"
github_api GET "repos/$GITHUB_OWNER/$GITHUB_REPOSITORY/actions/secrets/public-key"   > "$work_dir/github-public-key.json"

gitlab_api GET "projects/$project_id/access_tokens?per_page=100" > "$work_dir/gitlab-access-tokens.json"
rotation_date="$(date -u -d "+$SYNC_TOKEN_ROTATION_DAYS days" +%F)"
managed_token_id="$(jq -r --arg name "$SYNC_TOKEN_NAME" --arg rotation_date "$rotation_date" '
  .[]
  | select(.name == $name and .active == true and .revoked == false)
  | select((.scopes | index("write_repository")) != null)
  | select((.scopes | index("self_rotate")) != null)
  | select(.expires_at == null or .expires_at > $rotation_date)
  | .id
' "$work_dir/gitlab-access-tokens.json" | head -n 1)"
github_username_secret="$(jq -r '[.secrets[].name] | index("GITLAB_SYNC_USERNAME") != null' "$work_dir/github-secrets.json")"
github_token_secret="$(jq -r '[.secrets[].name] | index("GITLAB_SYNC_TOKEN") != null' "$work_dir/github-secrets.json")"
github_admin_token_secret="$(jq -r '[.secrets[].name] | index("REPOSITORY_SYNC_ADMIN_TOKEN") != null' "$work_dir/github-secrets.json")"

if [[ "$ROTATE_SYNC_TOKEN" == "true" || -z "$managed_token_id" ||
      "$github_username_secret" != "true" || "$github_token_secret" != "true" ||
      "$github_admin_token_secret" != "true" ]]; then
  mapfile -t old_token_ids < <(
    jq -r --arg name "$SYNC_TOKEN_NAME"       '.[] | select(.name == $name and .active == true and .revoked == false) | .id'       "$work_dir/gitlab-access-tokens.json"
  )
  for old_token_id in "${old_token_ids[@]}"; do
    info "Revoking superseded GitLab repository-sync token $old_token_id"
    gitlab_api DELETE "projects/$project_id/access_tokens/$old_token_id" >/dev/null
  done

  token_expires_at="$(date -u -d "+$SYNC_TOKEN_LIFETIME_DAYS days" +%F)"
  info "Creating a least-privilege GitLab repository-sync token"
  gitlab_api POST "projects/$project_id/access_tokens"     --form-string "name=$SYNC_TOKEN_NAME"     --form-string "expires_at=$token_expires_at"     --form-string 'access_level=40'     --form-string 'scopes[]=write_repository'     --form-string 'scopes[]=self_rotate'     > "$work_dir/gitlab-sync-token.json"
  sync_token="$(jq -er '.token' "$work_dir/gitlab-sync-token.json")"
  sync_user_id="$(jq -er '.user_id' "$work_dir/gitlab-sync-token.json")"
  sync_username="$(gitlab_api GET "users/$sync_user_id" | jq -er '.username')"

  github_key_id="$(jq -er '.key_id' "$work_dir/github-public-key.json")"
  github_public_key="$(jq -er '.key' "$work_dir/github-public-key.json")"

  put_github_secret() {
    local name="$1" value="$2" encrypted_value status
    encrypted_value="$(encrypt_github_secret "$github_public_key" "$value")"
    jq -n --arg encrypted_value "$encrypted_value" --arg key_id "$github_key_id"       '{encrypted_value:$encrypted_value,key_id:$key_id}' > "$work_dir/github-secret.json"
    status="$(curl --config "$github_config" --request PUT       --header 'Content-Type: application/json'       --data-binary "@$work_dir/github-secret.json"       --output "$work_dir/github-secret-response.json"       --write-out '%{http_code}'       "$GITHUB_API_URL/repos/$GITHUB_OWNER/$GITHUB_REPOSITORY/actions/secrets/$name")"
    case "$status" in
      201|204) ;;
      *) fail "GitHub returned HTTP $status while setting $name" ;;
    esac
  }

  put_github_secret GITLAB_SYNC_USERNAME "$sync_username"
  put_github_secret GITLAB_SYNC_TOKEN "$sync_token"
  put_github_secret REPOSITORY_SYNC_ADMIN_TOKEN "$GITHUB_ADMIN_TOKEN"
  unset sync_token
  info "Installed encrypted GitLab sync credentials in GitHub Actions"
else
  info "The managed GitLab token and GitHub Actions secrets are current"
fi

webhook_url="$GITHUB_API_URL/repos/$GITHUB_OWNER/$GITHUB_REPOSITORY/dispatches"
webhook_template='{"event_type":"gitlab_push","client_payload":{"ref":"{{ref}}","after":"{{after}}","project":"{{project.path_with_namespace}}"}}'
gitlab_api GET "projects/$project_id/hooks?per_page=100" > "$work_dir/gitlab-hooks.json"
hook_id="$(jq -r --arg url "$webhook_url" '.[] | select(.url == $url) | .id'   "$work_dir/gitlab-hooks.json" | head -n 1)"

webhook_args=(
  --form-string "url=$webhook_url"
  --form-string 'name=GitHub repository sync'
  --form-string 'description=Dispatch the repository reconciler after every GitLab branch or tag push'
  --form-string 'push_events=true'
  --form-string 'tag_push_events=true'
  --form-string 'enable_ssl_verification=true'
  --form-string 'branch_filter_strategy=all_branches'
  --form-string "custom_webhook_template=$webhook_template"
)
if [[ -z "$hook_id" ]]; then
  info "Creating the GitLab-to-GitHub repository dispatch webhook"
  hook_id="$(gitlab_api POST "projects/$project_id/hooks" "${webhook_args[@]}" | jq -er '.id')"
else
  info "Updating the GitLab-to-GitHub repository dispatch webhook"
  gitlab_api PUT "projects/$project_id/hooks/$hook_id" "${webhook_args[@]}" >/dev/null
fi

gitlab_api PUT "projects/$project_id/hooks/$hook_id/custom_headers/Authorization"   --form-string "value=Bearer $GITHUB_ADMIN_TOKEN" >/dev/null
gitlab_api PUT "projects/$project_id/hooks/$hook_id/custom_headers/Accept"   --form-string 'value=application/vnd.github+json' >/dev/null
gitlab_api PUT "projects/$project_id/hooks/$hook_id/custom_headers/X-GitHub-Api-Version"   --form-string 'value=2022-11-28' >/dev/null

gitlab_api GET "projects/$project_id/hooks/$hook_id" > "$work_dir/verified-hook.json"
jq -e --arg url "$webhook_url" '
  .url == $url
  and .push_events == true
  and .tag_push_events == true
  and .enable_ssl_verification == true
  and .custom_webhook_template != null
  and ([.custom_headers[].key] | sort
       == ["Accept", "Authorization", "X-GitHub-Api-Version"])
' "$work_dir/verified-hook.json" >/dev/null || fail "The repository-sync webhook did not validate"

if [[ "$TEST_REPOSITORY_SYNC_WEBHOOK" == "true" ]]; then
  info "Sending a GitLab push-event test to the GitHub repository dispatcher"
  gitlab_api POST "projects/$project_id/hooks/$hook_id/test/push_events" >/dev/null
fi

info "$GITHUB_OWNER/$GITHUB_REPOSITORY and $GITLAB_PROJECT_PATH repository sync is configured"
