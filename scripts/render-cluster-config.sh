#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OUTPUT_DIR=""
PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-}"
INTERNAL_DNS_ZONE="${INTERNAL_DNS_ZONE:-}"
GITOPS_REPOSITORY_URL="${GITOPS_REPOSITORY_URL:-}"
GITLAB_GROUP_PATH="${GITLAB_GROUP_PATH:-}"
GITLAB_PROJECT_NAME="${GITLAB_PROJECT_NAME:-}"
CLOUDFLARE_ACCESS_TEAM_NAME="${CLOUDFLARE_ACCESS_TEAM_NAME:-}"
INSTALL_APPS="${INSTALL_APPS:-true}"
INSTALL_DESCHEDULER="${INSTALL_DESCHEDULER:-true}"

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ -z "${SECURITY_IMAGES_ENABLED:-}" ]] || fail "SECURITY_IMAGES_ENABLED has been retired; follow docs/platform-migration.md and unset it."

while (( $# > 0 )); do
  case "$1" in
    --output) (( $# >= 2 )) || fail "--output requires a directory"; OUTPUT_DIR="$2"; shift 2 ;;
    --domain) (( $# >= 2 )) || fail "--domain requires a value"; PLATFORM_DOMAIN="$2"; shift 2 ;;
    --internal-domain) (( $# >= 2 )) || fail "--internal-domain requires a value"; INTERNAL_DNS_ZONE="$2"; shift 2 ;;
    --gitops-repository) (( $# >= 2 )) || fail "--gitops-repository requires a URL"; GITOPS_REPOSITORY_URL="$2"; shift 2 ;;
    --organization-name) (( $# >= 2 )) || fail "--organization-name requires a name"; ORGANIZATION_NAME="$2"; shift 2 ;;
    --organization-slug) (( $# >= 2 )) || fail "--organization-slug requires a label"; ORGANIZATION_SLUG="$2"; shift 2 ;;
    --keycloak-realm) (( $# >= 2 )) || fail "--keycloak-realm requires a name"; KEYCLOAK_REALM="$2"; shift 2 ;;
    --tls-secret-name) (( $# >= 2 )) || fail "--tls-secret-name requires a name"; TLS_SECRET_NAME="$2"; shift 2 ;;
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

# shellcheck source=lib/platform-identity.sh
source "$SCRIPT_DIR/lib/platform-identity.sh"
platform_identity_defaults
platform_identity_validate
export PLATFORM_DOMAIN INTERNAL_DNS_ZONE GITOPS_REPOSITORY_URL CLOUDFLARE_ACCESS_TEAM_NAME INSTALL_APPS INSTALL_DESCHEDULER

[[ -n "$OUTPUT_DIR" ]] || fail "Choose a dedicated output directory."
OUTPUT_DIR="$(realpath -m -- "$OUTPUT_DIR")"
case "$OUTPUT_DIR/" in
  "$REPOSITORY_ROOT/"*) fail "Render outside the repository checkout." ;;
esac
[[ "$OUTPUT_DIR" != / && ( ! -e "$OUTPUT_DIR" || -d "$OUTPUT_DIR" ) ]] || \
  fail "Choose a dedicated output directory."
# Reusing a populated directory can retain removed manifests or an old HA
# profile. Refuse it instead of deleting files the renderer may not own.
[[ ! -d "$OUTPUT_DIR" || -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || \
  fail "The output directory must be empty; choose a fresh staging directory."
[[ "$PLATFORM_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || \
  fail "Invalid public domain: $PLATFORM_DOMAIN"
[[ "$INTERNAL_DNS_ZONE" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || \
  fail "Invalid internal DNS domain: $INTERNAL_DNS_ZONE"
[[ "$INTERNAL_DNS_ZONE" != "$PLATFORM_DOMAIN" ]] || fail "Public and internal DNS domains must differ."
[[ "$GITOPS_REPOSITORY_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9_.~%+-]+)+\.git$ ]] || \
  fail "The GitOps repository must be an HTTP(S) .git URL without embedded credentials."
[[ "$GITLAB_GROUP_PATH" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]] || fail "Invalid GitLab group path."
[[ "$GITLAB_PROJECT_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "Invalid GitLab project name."
[[ "$CLOUDFLARE_ACCESS_TEAM_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail "Invalid Cloudflare Access team name."
[[ "$INSTALL_APPS" =~ ^(true|false)$ ]] || fail "--apps-enabled must be true or false."
[[ "$INSTALL_DESCHEDULER" =~ ^(true|false)$ ]] || fail "--descheduler-enabled must be true or false."
[[ "${HIGH_AVAILABILITY_ENABLED:-false}" =~ ^(true|false)$ ]] || fail "HIGH_AVAILABILITY_ENABLED must be true or false."

install -d -m 0700 "$OUTPUT_DIR" "$OUTPUT_DIR/k8s" "$OUTPUT_DIR/config"
cp -a "$REPOSITORY_ROOT/k8s/." "$OUTPUT_DIR/k8s/"
install -m 0600 "$REPOSITORY_ROOT/config/argocd-values.yaml" "$OUTPUT_DIR/config/argocd-values.yaml"
install -m 0600 "$REPOSITORY_ROOT/config/vault-values.yaml" "$OUTPUT_DIR/config/vault-values.yaml"
install -m 0600 "$REPOSITORY_ROOT/config/traefik-values.yaml" "$OUTPUT_DIR/config/traefik-values.yaml"

python3 "$SCRIPT_DIR/render-identity.py" --root "$OUTPUT_DIR"

# Reuse Helm's workload rendering for native installs too, including startup
# ConfigMaps required by the default (non-HA) Kafka deployment.
profile_args=(--root "$OUTPUT_DIR")
[[ -z "${PLATFORM_HA_VALUES_FILE:-}" ]] || profile_args+=(--values "$PLATFORM_HA_VALUES_FILE")
PLATFORM_DOMAIN="$PLATFORM_DOMAIN" INTERNAL_DNS_ZONE="$INTERNAL_DNS_ZONE" \
  GITOPS_REPOSITORY_URL="$GITOPS_REPOSITORY_URL" CLOUDFLARE_ACCESS_TEAM_NAME="$CLOUDFLARE_ACCESS_TEAM_NAME" \
  INSTALL_APPS="$INSTALL_APPS" INSTALL_DESCHEDULER="$INSTALL_DESCHEDULER" \
  python3 "$SCRIPT_DIR/render-platform-ha.py" "${profile_args[@]}"

printf '%s\n' "$OUTPUT_DIR"
