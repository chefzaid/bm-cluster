#!/bin/bash
# Unified entry point for adding K3s workers from either side of the connection.
set -euo pipefail
# A caller may have exported shell tracing; never trace token handling.
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROL_PLANE_INSTALLER="$SCRIPT_DIR/scripts/add-k3s-workers.sh"
LOCAL_WORKER_INSTALLER="$SCRIPT_DIR/scripts/install-k3s-worker.sh"

error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Add one or more machines to an existing K3s cluster as workers.

Interactive usage:
  ./install-worker.sh

The assistant asks where it is running:
  1. Control plane - enroll one or more remote workers over SSH
  2. Worker machine - join this machine using the control-plane URL and token

Both paths ask whether workers are internet-facing or local/private. Every
worker receives UFW; only internet-facing workers receive Fail2ban and CrowdSec.

Explicit mode selection:
  ./install-worker.sh --control-plane [control-plane options]
  ./install-worker.sh --worker [worker options]

Use a mode followed by --help to see its automation options:
  ./install-worker.sh --control-plane --help
  ./install-worker.sh --worker --help
EOF
}

[[ -x "$CONTROL_PLANE_INSTALLER" ]] || error "Control-plane worker installer is missing or not executable: $CONTROL_PLANE_INSTALLER"
[[ -x "$LOCAL_WORKER_INSTALLER" ]] || error "Local worker installer is missing or not executable: $LOCAL_WORKER_INSTALLER"

mode=""
case "${1:-}" in
    --control-plane)
        mode="control-plane"
        shift
        ;;
    --worker)
        mode="worker"
        shift
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        error "Select --control-plane or --worker before providing mode-specific options (use --help)."
        ;;
esac

if [[ -z "$mode" ]]; then
    printf '%s\n' \
        "Where are you running this installer?" \
        "  1) On the control plane - add one or more workers remotely over SSH" \
        "  2) On the worker machine - join this machine to the control plane"
    while true; do
        read -rp "Select 1 or 2: " selection
        case "$selection" in
            1|control-plane|control|server)
                mode="control-plane"
                break
                ;;
            2|worker|agent)
                mode="worker"
                break
                ;;
            *)
                printf 'Please enter 1 for control plane or 2 for worker.\n' >&2
                ;;
        esac
    done
fi

if [[ "$mode" == "control-plane" ]]; then
    exec "$CONTROL_PLANE_INSTALLER" "$@"
fi

exec "$LOCAL_WORKER_INSTALLER" "$@"
