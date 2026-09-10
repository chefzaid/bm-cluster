#!/usr/bin/env bash
# Standalone repository onboarding; also called by install-control-plane.sh.
set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_LIBRARY="$SCRIPT_DIR/scripts/lib/installer-prompts.sh"
# shellcheck source=scripts/lib/installer-prompts.sh
source "$PROMPT_LIBRARY"
# shellcheck source=scripts/lib/gitlab-admin-token.sh
source "$SCRIPT_DIR/scripts/lib/gitlab-admin-token.sh"

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Import GitHub repositories into GitLab, configure two-way commit/tag sync,
then configure and deploy selected repositories through their onboarding contracts.

Usage: ./add-repos.sh [--yes] [--inputs FILE] [--state-dir DIR]

Interactive: enter your GitHub username, a hidden personal access token, and
comma-separated repository names (owner/name is also accepted). The deployment
answer is prefilled with all successfully imported names; enter "none" to skip.

Automation (--yes never prompts):
  GITHUB_USERNAME         GitHub login (GITHUB_OWNER is accepted as a default)
  GITHUB_ADMIN_TOKEN      GitHub PAT; never pass it as a command-line argument
  GITHUB_REPOSITORIES     Comma-separated names or owner/name entries
  GITLAB_PUBLIC_URL       Public HTTPS GitLab URL; defaults from PLATFORM_DOMAIN
  PLATFORM_DOMAIN        Public zone; otherwise read from the installed platform
  INTERNAL_DNS_ZONE      Private service zone; discovered, never guessed from public DNS
  KEYCLOAK_REALM         Existing application realm; otherwise read from the SSO issuer
  PLATFORM_SECURITY_PROJECT_PATH  Shared helper image prefix; read from platform GitOps
  GITLAB_GROUP_PATH       Destination group (default: swirlit)
  DEPLOY_REPOSITORIES     Required with --yes: comma-separated names, all, or none
  GITLAB_ADMIN_TOKEN      Optional on the control plane: issued locally otherwise
  CLOUDFLARE_API_TOKEN    Zone Read/DNS Edit token; prompted during interactive setup
  REPOSITORY_INPUTS_FILE  Private JSON: {"owner/repository":{"APP_SUBDOMAIN":"app"}}
  REPOSITORY_STATE_DIR    Private local directory for resumable deployment journals
  ONBOARDING_TIMEOUT     Delivery wait in seconds (default 3600)

Existing public choices are prefilled from each repository. Missing contracts or
prerequisites stop that deployment; imports and completed setup remain reusable.

Run on the control plane with its kubeconfig to deploy. GitLab and its instance
runner must already exist. See docs/repository-replication.md for permissions,
deployment file locations, prerequisites, and recovery after partial failures.
EOF
}

non_interactive=false
while (( $# > 0 )); do
    case "$1" in
        --yes) non_interactive=true ;;
        --inputs)
            [[ $# -ge 2 ]] || fail "--inputs requires a JSON file"
            REPOSITORY_INPUTS_FILE="$2"; export REPOSITORY_INPUTS_FILE; shift ;;
        --state-dir)
            [[ $# -ge 2 ]] || fail "--state-dir requires a directory"
            REPOSITORY_STATE_DIR="$2"; export REPOSITORY_STATE_DIR; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1 (use --help)" ;;
    esac
    shift
done
[[ -t 0 || "$non_interactive" == true ]] || fail "Use --yes with explicit inputs when stdin is not a terminal."
if [[ "$non_interactive" == true ]]; then
    [[ -n "${DEPLOY_REPOSITORIES:-}" ]] || fail "Set DEPLOY_REPOSITORIES to all, none, or a comma-separated selection with --yes."
fi

for command_name in curl date git jq python3; do
    command -v "$command_name" >/dev/null || fail "$command_name is required"
done
python3 -c 'import yaml, ctypes.util; assert ctypes.util.find_library("sodium")' 2>/dev/null || \
    fail "Install python3-yaml and libsodium23 (Ubuntu/Debian) before replication."

cleanup() {
    gitlab_revoke_ephemeral_admin_token
    unset GITHUB_ADMIN_TOKEN
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

GITHUB_USERNAME="${GITHUB_USERNAME:-${GITHUB_OWNER:-}}"
GITHUB_REPOSITORIES="${GITHUB_REPOSITORIES:-}"
GITLAB_GROUP_PATH="${GITLAB_GROUP_PATH:-swirlit}"
GITLAB_PUBLIC_URL="${GITLAB_PUBLIC_URL:-${PLATFORM_DOMAIN:+https://gitlab.$PLATFORM_DOMAIN}}"
export GITLAB_PUBLIC_URL
# Values are public JSON, never sourced shell code. Deployment revalidates that
# every required setting was explicit or discoverable before changing an app.
platform_settings="$(python3 "$SCRIPT_DIR/scripts/replicate-repositories.py" --platform-context)"
for setting in PLATFORM_DOMAIN INTERNAL_DNS_ZONE KEYCLOAK_REALM GITLAB_PUBLIC_URL PLATFORM_SECURITY_PROJECT_PATH; do
    setting_value="$(jq -r --arg name "$setting" '.[$name] // empty' <<< "$platform_settings")"
    if [[ -n "$setting_value" ]]; then
        printf -v "$setting" '%s' "$setting_value"
        export "${setting?}"
    fi
done

if [[ "$non_interactive" == false ]]; then
    installer_prompt_section "Replicate GitHub repositories" \
        "Repositories are copied to GitLab and kept in sync in both directions."
    installer_prompt_value GITHUB_USERNAME "GitHub username" "$GITHUB_USERNAME"
    if [[ -z "${GITHUB_ADMIN_TOKEN:-}" ]]; then
        cat >&2 <<'EOF'
Create a fine-grained token at https://github.com/settings/personal-access-tokens/new
for the selected repositories with Administration, Actions, Contents, Secrets,
Variables, and Workflows read/write. GitHub requires a token, not your account
password. It is stored as an encrypted Actions secret and webhook header for
ongoing sync; renew it by rerunning this command before its expiry.
EOF
        installer_prompt_secret GITHUB_ADMIN_TOKEN "GitHub personal access token (input hidden)"
    fi
    installer_prompt_value GITHUB_REPOSITORIES "Repositories to import (comma separated)" "$GITHUB_REPOSITORIES"
    installer_prompt_value GITLAB_PUBLIC_URL "Public GitLab HTTPS URL" "$GITLAB_PUBLIC_URL"
    installer_prompt_value GITLAB_GROUP_PATH "Destination GitLab group" "$GITLAB_GROUP_PATH"
fi
[[ -n "$GITHUB_USERNAME" && -n "${GITHUB_ADMIN_TOKEN:-}" && -n "$GITHUB_REPOSITORIES" ]] || \
    fail "GITHUB_USERNAME, GITHUB_ADMIN_TOKEN, and GITHUB_REPOSITORIES are required."
export GITHUB_USERNAME GITHUB_ADMIN_TOKEN GITHUB_REPOSITORIES GITLAB_PUBLIC_URL GITLAB_GROUP_PATH
python3 "$SCRIPT_DIR/scripts/replicate-repositories.py" --check-inputs
export REPOSITORY_NONINTERACTIVE="$non_interactive"
# Concurrent runs must not revoke one another's short-lived administrator token.
GITLAB_BOOTSTRAP_TOKEN_NAME="bm-cluster-repositories-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
GITLAB_ADMIN_TOKEN_NONINTERACTIVE="$non_interactive" gitlab_acquire_admin_token
python3 "$SCRIPT_DIR/scripts/replicate-repositories.py"
