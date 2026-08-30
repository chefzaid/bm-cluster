#!/bin/bash
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/bm-cluster/k3s}"
RETENTION_COUNT="${RETENTION_COUNT:-7}"
K3S_DB="${K3S_DB:-/var/lib/rancher/k3s/server/db/state.db}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="$BACKUP_DIR/k3s-$TIMESTAMP.tar.gz"

[[ "$EUID" -eq 0 ]] || { echo "Run this backup as root." >&2; exit 1; }
[[ "$RETENTION_COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "RETENTION_COUNT must be a positive integer." >&2; exit 1; }
[[ -f "$K3S_DB" ]] || { echo "K3s SQLite database not found: $K3S_DB" >&2; exit 1; }
command -v sqlite3 >/dev/null || { echo "sqlite3 is required." >&2; exit 1; }

umask 077
install -d -o root -g root -m 0700 "$BACKUP_DIR"
exec 9>/run/lock/bm-k3s-backup.lock
flock -n 9 || exit 0

staging_dir="$(mktemp -d "$BACKUP_DIR/.staging.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
install -d -m 0700 "$staging_dir/k3s-db" "$staging_dir/k3s-server" \
  "$staging_dir/k3s-config" "$staging_dir/vault"

# SQLite's online backup API produces a transactionally consistent copy even
# while K3s is serving traffic and its WAL is changing.
backup_db="$staging_dir/k3s-db/state.db"
sqlite3 "$K3S_DB" ".timeout 60000" ".backup '$backup_db'"

# Compact only the staging copy to current state. Superseded revisions,
# tombstones, previous values, and SQLite free pages are not needed to restore
# the current Kubernetes objects and can retain deleted secrets indefinitely.
# Never run these statements against the live K3s database.
sqlite3 "$backup_db" <<'SQL'
BEGIN IMMEDIATE;
DELETE FROM kine
WHERE id IN (
  SELECT prev_revision
  FROM kine
  WHERE name != 'compact_rev_key' AND prev_revision != 0
  UNION
  SELECT id
  FROM kine
  WHERE deleted != 0
);
UPDATE kine
SET prev_revision = 0, old_value = X''
WHERE name != 'compact_rev_key';
COMMIT;
VACUUM;
SQL
[[ "$(sqlite3 "$backup_db" 'PRAGMA integrity_check;')" == "ok" ]] || {
  echo "Backup database integrity check failed." >&2
  exit 1
}

for source_file in \
  /var/lib/rancher/k3s/server/token \
  /var/lib/rancher/k3s/server/cred/encryption-config.json \
  /var/lib/rancher/k3s/server/cred/encryption-state.json; do
  [[ -f "$source_file" ]] && install -m 0600 "$source_file" "$staging_dir/k3s-server/$(basename "$source_file")"
done

for source_file in /etc/rancher/k3s/config.yaml /etc/rancher/k3s/registries.yaml; do
  [[ -f "$source_file" ]] && install -m 0600 "$source_file" "$staging_dir/k3s-config/$(basename "$source_file")"
done

for source_file in /var/lib/bm-cluster/vault-unseal-key /var/lib/bm-cluster/vault-bootstrap-token; do
  [[ -f "$source_file" ]] && install -m 0600 "$source_file" "$staging_dir/vault/$(basename "$source_file")"
done

cat > "$staging_dir/RESTORE.txt" <<EOF
Created: $TIMESTAMP
K3s version: $(k3s --version | head -1)

This archive contains credentials and encryption keys. Keep it root-only and
encrypt it before copying it off-node. Restore with the same K3s minor version;
stop K3s first, restore state.db, the server token, encryption files, and K3s
configuration, then start K3s and verify the output of: k3s secrets-encrypt status
EOF

tar -C "$staging_dir" -czf "$ARCHIVE" .
chmod 0600 "$ARCHIVE"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
chmod 0600 "$ARCHIVE.sha256"

mapfile -t archives < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'k3s-*.tar.gz' -printf '%f\n' | sort -r)
if (( ${#archives[@]} > RETENTION_COUNT )); then
  for old_archive in "${archives[@]:RETENTION_COUNT}"; do
    rm -f -- "$BACKUP_DIR/$old_archive" "$BACKUP_DIR/$old_archive.sha256"
  done
fi

echo "Created $ARCHIVE"
