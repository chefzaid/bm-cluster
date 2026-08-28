#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_SOURCE="$SCRIPT_DIR/../config/apparmor/cri-containerd.apparmor.d"
PROFILE_TARGET="/etc/apparmor.d/cri-containerd.apparmor.d"

if [[ ! -r "$PROFILE_SOURCE" ]]; then
    echo "AppArmor profile not found: $PROFILE_SOURCE" >&2
    exit 1
fi

if ! command -v apparmor_parser >/dev/null 2>&1; then
    echo "AppArmor parser is not installed; skipping K3s profile configuration."
    exit 0
fi

if [[ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || true)" != "Y" ]]; then
    echo "AppArmor is not enabled; skipping K3s profile configuration."
    exit 0
fi

# Parse without changing kernel policy before replacing the persisted profile.
sudo apparmor_parser -Q "$PROFILE_SOURCE"
sudo install -o root -g root -m 0644 "$PROFILE_SOURCE" "$PROFILE_TARGET"
sudo apparmor_parser -r -W "$PROFILE_TARGET"

echo "K3s runtime-default AppArmor profile installed and enforced."
