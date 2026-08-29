#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_CONFIG="$SCRIPT_DIR/../config/platform.env"
if [[ -r "$PLATFORM_CONFIG" ]]; then
    # shellcheck source=../config/platform.env
    source "$PLATFORM_CONFIG"
fi

REGISTRY_HOST="${K3S_REGISTRY_HOST:-${DEFAULT_K3S_REGISTRY_HOST:-registry.swirlit.dev}}"
REGISTRY_ENDPOINT="${K3S_REGISTRY_ENDPOINT:-${DEFAULT_K3S_REGISTRY_ENDPOINT:-http://10.43.255.251:5050}}"
REMOVED_REGISTRY_HOSTS="${K3S_REMOVED_REGISTRY_HOSTS:-gitlab.swirlit.dev}"
RETAIN_LEGACY_REGISTRY="${K3S_RETAIN_LEGACY_REGISTRY:-false}"
REGISTRY_CONFIG="${K3S_REGISTRY_CONFIG:-/etc/rancher/k3s/registries.yaml}"
sudo_command=()

info() { printf '[INFO] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

case "$RETAIN_LEGACY_REGISTRY" in
    true|false) ;;
    *) error "K3S_RETAIN_LEGACY_REGISTRY must be true or false" ;;
esac

if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || error "sudo is required when not running as root"
    sudo_command=(sudo)
fi

registry_dir="${REGISTRY_CONFIG%/*}"
"${sudo_command[@]}" install -d -o root -g root -m 0755 "$registry_dir"
changed=false

if ! "${sudo_command[@]}" test -f "$REGISTRY_CONFIG"; then
    printf 'mirrors:\n  "%s":\n    endpoint:\n      - "%s"\n' \
        "$REGISTRY_HOST" "$REGISTRY_ENDPOINT" | \
        "${sudo_command[@]}" install -o root -g root -m 0600 /dev/stdin "$REGISTRY_CONFIG"
    changed=true
elif ! "${sudo_command[@]}" grep -Fq "\"$REGISTRY_HOST\"" "$REGISTRY_CONFIG"; then
    "${sudo_command[@]}" grep -Eq '^mirrors:[[:space:]]*$' "$REGISTRY_CONFIG" || \
        error "$REGISTRY_CONFIG exists without a top-level mirrors mapping"
    temporary_config="$(mktemp)"
    trap 'rm -f "$temporary_config"' EXIT
    "${sudo_command[@]}" awk \
        -v registry_host="$REGISTRY_HOST" \
        -v registry_endpoint="$REGISTRY_ENDPOINT" '
          { print }
          !inserted && /^mirrors:[[:space:]]*$/ {
            printf "  \"%s\":\n    endpoint:\n      - \"%s\"\n", registry_host, registry_endpoint
            inserted = 1
          }
        ' "$REGISTRY_CONFIG" > "$temporary_config"
    "${sudo_command[@]}" install -o root -g root -m 0600 "$temporary_config" "$REGISTRY_CONFIG"
    rm -f "$temporary_config"
    trap - EXIT
    changed=true
fi

if [[ "$RETAIN_LEGACY_REGISTRY" == "false" ]]; then
    # Dependency Proxy requests must retain their canonical URL. A containerd
    # mirror adds an ns= query parameter that breaks GitLab Workhorse uploads.
    IFS=',' read -r -a legacy_registry_hosts <<< "$REMOVED_REGISTRY_HOSTS"
    for legacy_registry_host in "${legacy_registry_hosts[@]}"; do
        [[ -n "$legacy_registry_host" && "$legacy_registry_host" != "$REGISTRY_HOST" ]] || continue
        if "${sudo_command[@]}" grep -Fq "\"$legacy_registry_host\"" "$REGISTRY_CONFIG"; then
            temporary_config="$(mktemp)"
            trap 'rm -f "$temporary_config"' EXIT
            "${sudo_command[@]}" awk \
                -v legacy_header="  \"$legacy_registry_host\":" '
                  $0 == legacy_header {
                    skipping_legacy_mirror = 1
                    next
                  }
                  skipping_legacy_mirror && (/^[^[:space:]]/ || /^  [^[:space:]].*:[[:space:]]*$/) {
                    skipping_legacy_mirror = 0
                  }
                  !skipping_legacy_mirror { print }
                ' "$REGISTRY_CONFIG" > "$temporary_config"
            "${sudo_command[@]}" install -o root -g root -m 0600 "$temporary_config" "$REGISTRY_CONFIG"
            rm -f "$temporary_config"
            trap - EXIT
            changed=true
        fi
    done
fi

if [[ "$changed" == "true" ]]; then
    for service_name in k3s k3s-agent; do
        if "${sudo_command[@]}" systemctl is-active --quiet "$service_name" 2>/dev/null; then
            info "Restarting $service_name to load the $REGISTRY_HOST mirror"
            "${sudo_command[@]}" systemctl restart "$service_name"
            if [[ "$service_name" == "k3s" ]] && command -v kubectl >/dev/null 2>&1; then
                for attempt in $(seq 1 30); do
                    if kubectl get --raw=/readyz >/dev/null 2>&1; then
                        break
                    fi
                    (( attempt < 30 )) || error "Kubernetes did not become ready after restarting k3s"
                    sleep 2
                done
            fi
            break
        fi
    done
    info "Configured the K3s mirror for $REGISTRY_HOST"
else
    info "The K3s mirror is already configured for $REGISTRY_HOST"
fi
