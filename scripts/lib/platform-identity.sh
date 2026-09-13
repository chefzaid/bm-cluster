#!/usr/bin/env bash
# Public installation identity shared by entrypoints and provisioning helpers.

platform_identity_defaults() {
    local identity_domain="${PLATFORM_DOMAIN:-platform}" identity_project="${GITLAB_PROJECT_PATH:-}"
    if [[ -n "${TLS_SECRET_NAME:-}" && -n "${CLOUDFLARE_TLS_SECRET_NAME:-}" && "$TLS_SECRET_NAME" != "$CLOUDFLARE_TLS_SECRET_NAME" ]]; then
        printf '[ERROR] TLS_SECRET_NAME and CLOUDFLARE_TLS_SECRET_NAME must agree.\n' >&2
        return 1
    fi
    ORGANIZATION_SLUG="${ORGANIZATION_SLUG:-${identity_domain%%.*}}"
    ORGANIZATION_SLUG="${ORGANIZATION_SLUG:-platform}"
    ORGANIZATION_NAME="${ORGANIZATION_NAME:-$ORGANIZATION_SLUG}"
    GITLAB_GROUP_PATH="${GITLAB_GROUP_PATH:-${identity_project%/*}}"
    GITLAB_GROUP_PATH="${GITLAB_GROUP_PATH:-$ORGANIZATION_SLUG}"
    GITLAB_GROUP_NAME="${GITLAB_GROUP_NAME:-$ORGANIZATION_NAME}"
    GITLAB_PROJECT_NAME="${GITLAB_PROJECT_NAME:-${identity_project##*/}}"
    GITLAB_PROJECT_NAME="${GITLAB_PROJECT_NAME:-bm-cluster}"
    GITLAB_PROJECT_PATH="${GITLAB_PROJECT_PATH:-$GITLAB_GROUP_PATH/$GITLAB_PROJECT_NAME}"
    KEYCLOAK_REALM="${KEYCLOAK_REALM:-$ORGANIZATION_SLUG}"
    TLS_SECRET_NAME="${TLS_SECRET_NAME:-${CLOUDFLARE_TLS_SECRET_NAME:-${identity_domain//./-}-tls}}"
    CLOUDFLARE_TLS_SECRET_NAME="$TLS_SECRET_NAME"
    SONAR_ALM_SETTING="${SONAR_ALM_SETTING:-$ORGANIZATION_SLUG-gitlab}"
    CLOUDFLARE_ACCESS_IDP_NAME="${CLOUDFLARE_ACCESS_IDP_NAME:-$ORGANIZATION_NAME Keycloak}"
    export ORGANIZATION_NAME ORGANIZATION_SLUG GITLAB_GROUP_PATH GITLAB_GROUP_NAME
    export GITLAB_PROJECT_NAME GITLAB_PROJECT_PATH KEYCLOAK_REALM TLS_SECRET_NAME
    export CLOUDFLARE_TLS_SECRET_NAME SONAR_ALM_SETTING CLOUDFLARE_ACCESS_IDP_NAME
}

platform_identity_validate() {
    local name value
    value="$ORGANIZATION_SLUG"
    [[ "$value" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#value} -le 63 ]] || {
        printf '[ERROR] ORGANIZATION_SLUG must be a lowercase DNS label (maximum 63 characters).\n' >&2; return 1;
    }
    for name in ORGANIZATION_NAME GITLAB_GROUP_NAME CLOUDFLARE_ACCESS_IDP_NAME; do
        value="${!name}"
        [[ "$value" =~ [^[:space:]] && ${#value} -le 160 && ! "$value" =~ [[:cntrl:]] ]] || {
            printf '[ERROR] %s must contain 1–160 printable characters.\n' "$name" >&2; return 1;
        }
    done
    [[ "$GITLAB_GROUP_PATH" =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*(/[A-Za-z0-9_-][A-Za-z0-9_.-]*)*$ &&
       "$GITLAB_PROJECT_NAME" =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ &&
       "$GITLAB_PROJECT_PATH" == "$GITLAB_GROUP_PATH/$GITLAB_PROJECT_NAME" ]] || {
        printf '[ERROR] GitLab group, project name and project path must identify the same repository.\n' >&2; return 1;
    }
    [[ "$KEYCLOAK_REALM" =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ && "$KEYCLOAK_REALM" != master &&
       "$SONAR_ALM_SETTING" =~ ^[A-Za-z0-9_-][A-Za-z0-9_.-]*$ ]] || {
        printf '[ERROR] Set a valid application KEYCLOAK_REALM and SONAR_ALM_SETTING (master is reserved).\n' >&2; return 1;
    }
    [[ "$TLS_SECRET_NAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && ${#TLS_SECRET_NAME} -le 253 ]] || {
        printf '[ERROR] TLS_SECRET_NAME must be a Kubernetes DNS subdomain.\n' >&2; return 1;
    }
    [[ -z "${CLOUDFLARE_TLS_SECRET_NAME:-}" || "$CLOUDFLARE_TLS_SECRET_NAME" == "$TLS_SECRET_NAME" ]] || return 1
}

platform_identity_load() {
    # A public ConfigMap records installed choices. Explicit environment inputs
    # take precedence; values are decoded as data and are never sourced/eval'd.
    local name value identity_script identity_json
    TLS_SECRET_NAME="${TLS_SECRET_NAME:-${CLOUDFLARE_TLS_SECRET_NAME:-}}"
    identity_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/platform-identity.py"
    if command -v python3 >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
        identity_json="$(python3 "$identity_script" --discover)" || return 1
        while IFS= read -r -d '' name && IFS= read -r -d '' value; do
            if [[ -z "${!name:-}" ]]; then
                printf -v "$name" '%s' "$value"
                export "${name?}"
            fi
        done < <(python3 "$identity_script" --json "$identity_json" --pairs)
    fi
}
