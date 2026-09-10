#!/usr/bin/env bash
# Reuse TLS for shared infra/apps; optionally include centrally managed corp.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tls.sh
source "$SCRIPT_DIR/lib/tls.sh"
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[INFO] %s\n' "$*"; }

apps_enabled=false
if [[ $# == 2 && "$1" == --apps-enabled && "$2" =~ ^(true|false)$ ]]; then
    apps_enabled="$2"
elif [[ $# != 0 ]]; then
    printf 'Usage: configure-local-tls.sh [--apps-enabled true|false]\n' >&2
    exit 2
fi
if [[ ! "${PLATFORM_DOMAIN:-}" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    printf 'Set PLATFORM_DOMAIN to the cluster base domain.\n' >&2
    exit 2
fi

ensure_tls_secret infra swirlit-dev-tls "$PLATFORM_DOMAIN" "*.$PLATFORM_DOMAIN"
ensure_tls_secret apps swirlit-dev-tls "$PLATFORM_DOMAIN" "*.$PLATFORM_DOMAIN"
if [[ "$apps_enabled" == true ]]; then
    ensure_tls_secret corp swirlit-dev-tls "$PLATFORM_DOMAIN" "*.$PLATFORM_DOMAIN"
fi
