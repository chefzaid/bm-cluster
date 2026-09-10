#!/usr/bin/env bash
# Shared shell/Ansible ingress installation, including safe HA opt-in.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../config/platform.env
source "$ROOT/config/platform.env"
VALUES="${INGRESS_VALUES_FILE:-$ROOT/config/ingress-nginx-values.yaml}"
NAMESPACE="${INGRESS_NAMESPACE:-infra}"
MODE="${HIGH_AVAILABILITY_ENABLED:-}"
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
[[ $# == 0 ]] || { printf 'Usage: HIGH_AVAILABILITY_ENABLED=true INGRESS_VALUES_FILE=rendered/config/ingress-nginx-values.yaml %s\n' "$0"; exit 0; }
state="$(kubectl get configmap bm-cluster-public-ingress -n "$NAMESPACE" --ignore-not-found -o json)"
[[ -n "$state" ]] || state='{}'
stored_mode="$(jq -r '.data.mode // "direct"' <<< "$state")"
[[ -n "$MODE" ]] || { MODE=false; [[ "$stored_mode" != tunnel ]] || MODE=true; }
[[ "$MODE" =~ ^(true|false)$ ]] || fail 'HIGH_AVAILABILITY_ENABLED must be true or false.'
[[ "$stored_mode" != tunnel || "$MODE" == true ]] || fail 'Existing HA ingress cannot be downgraded by a single-node installer run.'
temporary="$(mktemp -d /tmp/bm-ingress.XXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT
args=(--values "$VALUES")
if [[ "$MODE" == true ]]; then
    HIGH_AVAILABILITY_ENABLED=true "$SCRIPT_DIR/reconcile-cluster-topology.sh" --print-longhorn-replicas >/dev/null
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || ! kubectl get secret cloudflare-tunnel -n "$NAMESPACE" >/dev/null 2>&1; then
        python3 "$SCRIPT_DIR/configure-cloudflare-tunnel.py" --namespace "$NAMESPACE"
    else
        [[ "$stored_mode" == tunnel ]] || fail 'Tunnel credentials exist without a managed tunnel identity; reconcile with a Cloudflare token.'
    fi
    # Helm replaces lists. Preserve the base read-only-rootfs writable mounts
    # when adding the connector credential volume and sidecar.
    python3 - "$VALUES" "$ROOT/config/ingress-nginx-ha-values.yaml" "$temporary/ha.yaml" <<'PY'
import sys, yaml
from pathlib import Path
base, overlay = (yaml.safe_load(Path(p).read_text()) for p in sys.argv[1:3])
for key in ('extraVolumes', 'extraContainers'):
    overlay['controller'][key] = base.get('controller', {}).get(key, []) + overlay['controller'].get(key, [])
Path(sys.argv[3]).write_text(yaml.safe_dump(overlay, sort_keys=False))
PY
    # The tunnel uses the public apex as TLS SNI even before an application
    # owns that host. Avoid NGINX's self-signed catch-all certificate.
    args+=(--values "$temporary/ha.yaml" --set-string
        "controller.extraArgs.default-ssl-certificate=$NAMESPACE/${CLOUDFLARE_TLS_SECRET_NAME:-swirlit-dev-tls}")
else
    args+=(--set controller.service.type=LoadBalancer
        --set controller.service.enableHttp=true
        --set-string 'controller.nodeSelector.node-role\.kubernetes\.io/control-plane=true'
        --set-string 'controller.nodeSelector.svccontroller\.k3s\.cattle\.io/enablelb=true'
        --set-string 'controller.tolerations[0].key=node-role.kubernetes.io/control-plane'
        --set-string 'controller.tolerations[0].operator=Exists'
        --set-string 'controller.tolerations[0].effect=NoSchedule')
fi
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
helm repo update >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "$NAMESPACE" --version "${INGRESS_NGINX_CHART_VERSION:-$DEFAULT_INGRESS_NGINX_CHART_VERSION}" \
    --reset-values "${args[@]}" --wait --timeout "${INGRESS_HELM_TIMEOUT:-$DEFAULT_INGRESS_HELM_TIMEOUT}"
if [[ "$MODE" == true ]]; then
    printf '[INFO] HA ingress is ready. Run configure-cloudflare.sh to publish the tunnel CNAMEs.\n'
fi
