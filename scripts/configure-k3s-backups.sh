#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v sudo >/dev/null || { echo "sudo is required." >&2; exit 1; }
command -v k3s >/dev/null || { echo "K3s is not installed." >&2; exit 1; }

if ! command -v sqlite3 >/dev/null; then
  sudo apt-get update -qq
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 >/dev/null
fi

sudo install -d -o root -g root -m 0700 /var/backups/bm-cluster/k3s
sudo install -o root -g root -m 0750 "$REPO_ROOT/scripts/backup-k3s.sh" /usr/local/sbin/bm-k3s-backup
sudo install -o root -g root -m 0644 "$REPO_ROOT/config/systemd/bm-k3s-backup.service" /etc/systemd/system/bm-k3s-backup.service
sudo install -o root -g root -m 0644 "$REPO_ROOT/config/systemd/bm-k3s-backup.timer" /etc/systemd/system/bm-k3s-backup.timer
sudo systemctl daemon-reload
sudo systemctl enable --now bm-k3s-backup.timer >/dev/null
sudo systemctl start bm-k3s-backup.service

echo "K3s backups are enabled; the latest seven daily archives are kept in /var/backups/bm-cluster/k3s."
