#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR=""
PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-}"
INTERNAL_DNS_ZONE="${INTERNAL_DNS_ZONE:-}"
GITOPS_REPOSITORY_URL="${GITOPS_REPOSITORY_URL:-}"
GITLAB_GROUP_PATH="${GITLAB_GROUP_PATH:-swirlit}"
GITLAB_PROJECT_NAME="${GITLAB_PROJECT_NAME:-bm-cluster}"
CLOUDFLARE_ACCESS_TEAM_NAME="${CLOUDFLARE_ACCESS_TEAM_NAME:-}"
INSTALL_APPS="${INSTALL_APPS:-true}"
INSTALL_DESCHEDULER="${INSTALL_DESCHEDULER:-true}"

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

while (( $# > 0 )); do
  case "$1" in
    --output) (( $# >= 2 )) || fail "--output requires a directory"; OUTPUT_DIR="$2"; shift 2 ;;
    --domain) (( $# >= 2 )) || fail "--domain requires a value"; PLATFORM_DOMAIN="$2"; shift 2 ;;
    --internal-domain) (( $# >= 2 )) || fail "--internal-domain requires a value"; INTERNAL_DNS_ZONE="$2"; shift 2 ;;
    --gitops-repository) (( $# >= 2 )) || fail "--gitops-repository requires a URL"; GITOPS_REPOSITORY_URL="$2"; shift 2 ;;
    --gitlab-group) (( $# >= 2 )) || fail "--gitlab-group requires a path"; GITLAB_GROUP_PATH="$2"; shift 2 ;;
    --gitlab-project) (( $# >= 2 )) || fail "--gitlab-project requires a name"; GITLAB_PROJECT_NAME="$2"; shift 2 ;;
    --cloudflare-access-team) (( $# >= 2 )) || fail "--cloudflare-access-team requires a name"; CLOUDFLARE_ACCESS_TEAM_NAME="$2"; shift 2 ;;
    --apps-enabled) (( $# >= 2 )) || fail "--apps-enabled requires true or false"; INSTALL_APPS="$2"; shift 2 ;;
    --descheduler-enabled) (( $# >= 2 )) || fail "--descheduler-enabled requires true or false"; INSTALL_DESCHEDULER="$2"; shift 2 ;;
    -h|--help)
      printf 'Usage: %s --output DIR --domain DOMAIN --internal-domain DOMAIN --gitops-repository URL\n' "$0"
      exit 0
      ;;
    *) fail "Unknown option: $1" ;;
  esac
done

[[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" != / && "$OUTPUT_DIR" != "$REPOSITORY_ROOT" ]] || \
  fail "Choose a dedicated output directory."
[[ "$PLATFORM_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || \
  fail "Invalid public domain: $PLATFORM_DOMAIN"
[[ "$INTERNAL_DNS_ZONE" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || \
  fail "Invalid internal DNS domain: $INTERNAL_DNS_ZONE"
[[ "$INTERNAL_DNS_ZONE" != "$PLATFORM_DOMAIN" ]] || fail "Public and internal DNS domains must differ."
[[ "$GITOPS_REPOSITORY_URL" =~ ^https?://[^[:space:]]+\.git$ ]] || \
  fail "The GitOps repository must be an HTTP(S) .git URL."
[[ "$GITLAB_GROUP_PATH" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]] || fail "Invalid GitLab group path."
[[ "$GITLAB_PROJECT_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "Invalid GitLab project name."
[[ "$CLOUDFLARE_ACCESS_TEAM_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail "Invalid Cloudflare Access team name."
[[ "$INSTALL_APPS" =~ ^(true|false)$ ]] || fail "--apps-enabled must be true or false."
[[ "$INSTALL_DESCHEDULER" =~ ^(true|false)$ ]] || fail "--descheduler-enabled must be true or false."

install -d -m 0700 "$OUTPUT_DIR/k8s" "$OUTPUT_DIR/config"
cp -a "$REPOSITORY_ROOT/k8s/." "$OUTPUT_DIR/k8s/"
install -m 0600 "$REPOSITORY_ROOT/config/argocd-values.yaml" "$OUTPUT_DIR/config/argocd-values.yaml"

escape_sed() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
public_domain="$(escape_sed "$PLATFORM_DOMAIN")"
internal_domain="$(escape_sed "$INTERNAL_DNS_ZONE")"
gitops_repository="$(escape_sed "$GITOPS_REPOSITORY_URL")"
gitlab_group="$(escape_sed "$GITLAB_GROUP_PATH")"
gitlab_project="$(escape_sed "$GITLAB_PROJECT_NAME")"
cloudflare_access_team="$(escape_sed "$CLOUDFLARE_ACCESS_TEAM_NAME")"

while IFS= read -r -d '' file; do
  sed -i \
    -e "s|__PUBLIC_DOMAIN__|$public_domain|g" \
    -e "s|__INTERNAL_DNS_ZONE__|$internal_domain|g" \
    -e "s|__GITOPS_REPOSITORY_URL__|$gitops_repository|g" \
    -e "s|__GITLAB_GROUP_PATH__|$gitlab_group|g" \
    -e "s|__GITLAB_PROJECT_NAME__|$gitlab_project|g" \
    -e "s|__CLOUDFLARE_ACCESS_TEAM_NAME__|$cloudflare_access_team|g" \
    -e "s|__APPS_ENABLED__|$INSTALL_APPS|g" \
    -e "s|__DESCHEDULER_ENABLED__|$INSTALL_DESCHEDULER|g" \
    "$file"
done < <(find "$OUTPUT_DIR/k8s" "$OUTPUT_DIR/config" -type f -print0)

render_token_pattern='__(PUBLIC_DOMAIN|INTERNAL_DNS_ZONE|GITOPS_REPOSITORY_URL|GITLAB_GROUP_PATH|GITLAB_PROJECT_NAME|CLOUDFLARE_ACCESS_TEAM_NAME|APPS_ENABLED|DESCHEDULER_ENABLED)__'
if grep -REn "$render_token_pattern" "$OUTPUT_DIR/k8s" "$OUTPUT_DIR/config" >/dev/null; then
  grep -REn "$render_token_pattern" "$OUTPUT_DIR/k8s" "$OUTPUT_DIR/config" >&2
  fail "Rendered configuration still contains unresolved placeholders."
fi

printf '%s\n' "$OUTPUT_DIR"
