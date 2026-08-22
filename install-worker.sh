#!/bin/bash
# Install the current machine as a worker in an existing K3s cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_INSTALLER="$SCRIPT_DIR/scripts/install-k3s-worker.sh"

if [[ ! -x "$WORKER_INSTALLER" ]]; then
    printf 'Worker installer is missing or not executable: %s\n' "$WORKER_INSTALLER" >&2
    exit 1
fi

exec "$WORKER_INSTALLER" "$@"
