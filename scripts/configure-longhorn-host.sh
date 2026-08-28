#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SOURCE="$SCRIPT_DIR/../config/multipath/multipath-longhorn.conf"
CONFIG_TARGET="/etc/multipath.conf"

[[ -f "$CONFIG_SOURCE" ]] || { echo "Missing $CONFIG_SOURCE" >&2; exit 1; }

if command -v multipathd >/dev/null 2>&1; then
  sudo install -o root -g root -m 0644 "$CONFIG_SOURCE" "$CONFIG_TARGET"
  sudo systemctl reload multipathd 2>/dev/null || sudo multipathd reconfigure
fi

echo "Longhorn host storage prerequisites configured."
