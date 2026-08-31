#!/bin/bash
set -euo pipefail

BACKUP_ENVIRONMENT_FILE="${BACKUP_ENVIRONMENT_FILE:-/etc/bm-cluster/backup.env}"
if [[ -r "$BACKUP_ENVIRONMENT_FILE" ]]; then
  # This root-owned file is written with shell-safe escaped values.
  # shellcheck disable=SC1090
  source "$BACKUP_ENVIRONMENT_FILE"
fi

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
  "$staging_dir/k3s-config" "$staging_dir/vault" "$staging_dir/application-data" \
  "$staging_dir/kubernetes"

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

if command -v kubectl >/dev/null 2>&1 && kubectl get --raw=/readyz >/dev/null 2>&1; then
  kubectl get persistentvolumeclaims -A -o yaml > "$staging_dir/kubernetes/persistentvolumeclaims.yaml"
  kubectl get volumes.longhorn.io -n longhorn-system -o yaml \
    > "$staging_dir/kubernetes/longhorn-volumes.yaml" 2>/dev/null || true
  if kubectl get recurringjob.longhorn.io bm-cluster-daily-backup -n longhorn-system >/dev/null 2>&1; then
    kubectl label volumes.longhorn.io -n longhorn-system --all \
      recurring-job-group.longhorn.io/bm-cluster=enabled --overwrite >/dev/null 2>&1 || true
  fi

  if kubectl get pod vault-0 -n infra >/dev/null 2>&1 && [[ -s /var/lib/bm-cluster/vault-bootstrap-token ]]; then
    vault_snapshot_path="/tmp/bm-cluster-$TIMESTAMP.snap"
    vault_token="$(< /var/lib/bm-cluster/vault-bootstrap-token)"
    { printf '%s\n' "$vault_token"; } | kubectl exec -i -n infra vault-0 -- sh -ceu '
      IFS= read -r VAULT_TOKEN
      export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
      vault operator raft snapshot save "$1"
    ' sh "$vault_snapshot_path" >/dev/null
    kubectl cp "infra/vault-0:$vault_snapshot_path" "$staging_dir/vault/raft.snap" >/dev/null
    kubectl exec -n infra vault-0 -- rm -f -- "$vault_snapshot_path"
    unset vault_token
  fi

  if kubectl get deployment postgres -n infra >/dev/null 2>&1; then
    postgres_username="$(kubectl get secret postgres-secret -n infra -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)"
    postgres_password="$(kubectl get secret postgres-secret -n infra -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
    { printf '%s\n%s\n' "$postgres_username" "$postgres_password"; } | kubectl exec -i -n infra deployment/postgres -- sh -ceu '
      IFS= read -r postgres_username
      IFS= read -r PGPASSWORD
      export PGPASSWORD
      exec pg_dumpall --username="$postgres_username" --clean --if-exists
    ' | gzip -9 > "$staging_dir/application-data/postgresql.sql.gz"
    unset postgres_username postgres_password
  fi

  if kubectl get deployment mongodb -n infra >/dev/null 2>&1; then
    mongodb_username="$(kubectl get secret mongodb-secret -n infra -o jsonpath='{.data.MONGO_INITDB_ROOT_USERNAME}' | base64 -d)"
    mongodb_password="$(kubectl get secret mongodb-secret -n infra -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d)"
    { printf '%s\n%s\n' "$mongodb_username" "$mongodb_password"; } | kubectl exec -i -n infra deployment/mongodb -- sh -ceu '
      IFS= read -r mongodb_username
      IFS= read -r mongodb_password
      exec mongodump --username "$mongodb_username" --password "$mongodb_password" \
        --authenticationDatabase admin --archive --gzip
    ' > "$staging_dir/application-data/mongodb.archive.gz"
    unset mongodb_username mongodb_password
  fi
fi

cat > "$staging_dir/RESTORE.txt" <<EOF
Created: $TIMESTAMP
K3s version: $(k3s --version | head -1)

This archive contains credentials and encryption keys. Keep it root-only and
is uploaded through an encrypted restic repository when off-node storage is
configured. It also contains a Vault Raft snapshot and logical PostgreSQL and
MongoDB dumps when those services were present. Longhorn recurring backups hold
the remaining PVC data. Restore with the same K3s minor version; stop K3s first,
restore state.db, the server token, encryption files, and K3s configuration,
then start K3s and verify the output of: k3s secrets-encrypt status
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

if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
  command -v restic >/dev/null || { echo "restic is required for off-node backup storage." >&2; exit 1; }
  if ! restic snapshots --no-lock >/dev/null 2>&1; then
    restic init
  fi
  restic backup --tag bm-cluster-k3s "$ARCHIVE" "$ARCHIVE.sha256"
  restic forget --tag bm-cluster-k3s --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
fi

echo "Created $ARCHIVE"
