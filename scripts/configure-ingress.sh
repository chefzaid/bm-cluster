#!/usr/bin/env bash
# Shared installation of native Traefik ingress and optional co-located Tunnel.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/platform-identity.sh
source "$SCRIPT_DIR/lib/platform-identity.sh"
# shellcheck source=../config/platform.env
source "$ROOT/config/platform.env"
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
[[ $# == 0 ]] || { printf 'Usage: INGRESS_VALUES_FILE=rendered/config/traefik-values.yaml %s\n' "$0"; exit 0; }
platform_identity_load
platform_identity_defaults
VALUES="${INGRESS_VALUES_FILE:-$ROOT/config/traefik-values.yaml}"
NAMESPACE="${INGRESS_NAMESPACE:-infra}"
MODE="${HIGH_AVAILABILITY_ENABLED:-}"
CANDIDATE="${INGRESS_MIGRATION_CANDIDATE:-false}"
[[ "$CANDIDATE" =~ ^(true|false)$ ]] || fail 'INGRESS_MIGRATION_CANDIDATE must be true or false.'
state="$(kubectl get configmap bm-cluster-public-ingress -n "$NAMESPACE" --ignore-not-found -o json)"
[[ -n "$state" ]] || state='{}'
stored_mode="$(jq -r '.data.mode // "direct"' <<< "$state")"
[[ -n "$MODE" ]] || { MODE=false; [[ "$stored_mode" != tunnel ]] || MODE=true; }
[[ "$MODE" =~ ^(true|false)$ ]] || fail 'HIGH_AVAILABILITY_ENABLED must be true or false.'
[[ "$CANDIDATE" == true || "$stored_mode" != tunnel || "$MODE" == true ]] || fail 'Existing HA ingress cannot be downgraded by a single-node installer run.'
releases="$(helm list -n "$NAMESPACE" -o json)"
jq -e 'type == "array" and all(.[]; type == "object" and (.name | type) == "string")' <<< "$releases" >/dev/null || fail 'Helm returned an invalid release inventory.'
if [[ "$CANDIDATE" == true ]] && jq -e 'any(.[]; .name == "traefik")' <<< "$releases" >/dev/null; then
    fail 'A traefik release already exists; candidate mode cannot replace an active ingress. Remove only a verified disposable candidate before repeating its installation.'
fi
if [[ "$CANDIDATE" != true ]] && jq -e 'any(.[]; .name == "ingress-nginx")' <<< "$releases" >/dev/null; then
    fail 'Migrate the existing ingress-nginx release first; see docs/platform-migration.md. Use INGRESS_MIGRATION_CANDIDATE=true for an isolated ClusterIP candidate.'
fi
temporary="$(mktemp -d /tmp/bm-ingress.XXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT
# Render the one TLS identity input for direct invocations of this helper too.
python3 - "$VALUES" "$temporary/base.yaml" "$TLS_SECRET_NAME" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[2]).write_text(Path(sys.argv[1]).read_text().replace('__TLS_SECRET_NAME__', sys.argv[3]))
PY
args=(--values "$temporary/base.yaml")
if [[ "$MODE" == true && "$CANDIDATE" != true ]]; then
    HIGH_AVAILABILITY_ENABLED=true "$SCRIPT_DIR/reconcile-cluster-topology.sh" --print-longhorn-replicas >/dev/null
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || ! kubectl get secret cloudflare-tunnel -n "$NAMESPACE" >/dev/null 2>&1; then
        python3 "$SCRIPT_DIR/configure-cloudflare-tunnel.py" --namespace "$NAMESPACE"
    else
        [[ "$stored_mode" == tunnel ]] || fail 'Tunnel credentials exist without a managed tunnel identity; reconcile with a Cloudflare token.'
    fi
    args+=(--values "$ROOT/config/traefik-ha-values.yaml")
else
    # Trust only the edge addresses, never an entire node or pod network.
    curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://www.cloudflare.com/ips-v4 > "$temporary/edge.txt"
    printf '\n' >> "$temporary/edge.txt"
    curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://www.cloudflare.com/ips-v6 >> "$temporary/edge.txt"
    python3 - "$temporary/edge.txt" "$temporary/trust.json" <<'PY'
import ipaddress, json, sys
from pathlib import Path
networks = sorted({str(ipaddress.ip_network(line.strip())) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()})
if not networks or any(ipaddress.ip_network(value).prefixlen == 0 for value in networks):
    raise SystemExit('Cloudflare returned an invalid trusted proxy inventory')
Path(sys.argv[2]).write_text(json.dumps({'ports': {name: {'forwardedHeaders': {'trustedIPs': networks}} for name in ('web', 'websecure')}}))
PY
    args+=(--values "$temporary/trust.json")
fi
if [[ "$CANDIDATE" == true ]]; then
    args+=(--set service.spec.type=ClusterIP --set service.spec.externalTrafficPolicy=null --set ingressClass.isDefaultClass=false)
fi
helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
helm repo update traefik --fail-on-repo-update-fail >/dev/null
helm upgrade --install traefik traefik/traefik \
    --namespace "$NAMESPACE" --version "${TRAEFIK_CHART_VERSION:-$DEFAULT_TRAEFIK_CHART_VERSION}" \
    --reset-values "${args[@]}" --wait --timeout "${INGRESS_HELM_TIMEOUT:-$DEFAULT_INGRESS_HELM_TIMEOUT}"
if [[ "$CANDIDATE" == true ]]; then
    printf '[INFO] Isolated ClusterIP candidate is ready; no tunnel connector was started. Follow docs/platform-migration.md.\n'
elif [[ "$MODE" == true ]]; then
    printf '[INFO] HA ingress is ready. Run configure-cloudflare.sh to publish the tunnel CNAMEs.\n'
fi
