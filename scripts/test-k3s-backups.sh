#!/usr/bin/env bash
# Exercise datastore selection and recovery archives without a running cluster.
# Mock functions are invoked from the sourced production script.
# ShellCheck 0.10 reports indirect mock calls as SC2317; 0.11 uses SC2329.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d /tmp/bm-cluster-backup-test.XXXXXX)"
trap 'rm -r -- "$TEST_DIR"' EXIT
command -v sqlite3 >/dev/null || { printf 'sqlite3 is required for backup tests.\n' >&2; exit 1; }

mkdir -p "$TEST_DIR/data/server/db" "$TEST_DIR/config/config.yaml.d" "$TEST_DIR/vault" "$TEST_DIR/locks"
printf 'fixture-token\n' > "$TEST_DIR/data/server/token"
printf 'node-ip: 10.40.0.1\n' > "$TEST_DIR/config/config.yaml.d/20-bm-private-node-network.yaml"
sqlite3 "$TEST_DIR/data/server/db/state.db" <<'SQL'
CREATE TABLE kine (id INTEGER PRIMARY KEY, name TEXT, prev_revision INTEGER, deleted INTEGER, old_value BLOB);
INSERT INTO kine VALUES (1, '/test', 0, 0, X'');
INSERT INTO kine VALUES (2, '/test', 1, 0, X'736563726574');
INSERT INTO kine VALUES (3, '/deleted', 0, 1, X'736563726574');
SQL

run_backup() (
    export BACKUP_DIR="$TEST_DIR/$1" K3S_DATA_DIR="$TEST_DIR/data" K3S_CONFIG_DIR="$TEST_DIR/config"
    export BACKUP_ENVIRONMENT_FILE="$TEST_DIR/absent.env" RESTIC_REPOSITORY=''
    unset K3S_DB
    install() {
        local -a arguments=()
        while [[ $# -gt 0 ]]; do
            case "$1" in -o|-g) shift 2 ;; *) arguments+=("$1"); shift ;; esac
        done
        command install "${arguments[@]}"
    }
    k3s() {
        local snapshot_dir='' snapshot_name=''
        if [[ "$1" == --version ]]; then printf 'k3s version v1.35.0+k3s1 (fixture)\n'; return; fi
        [[ "$1 $2" == 'etcd-snapshot save' ]] || return 1
        [[ "${MOCK_SNAPSHOT_FAIL:-false}" != true ]] || return 1
        shift 2
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --etcd-snapshot-dir) snapshot_dir="$2"; shift 2 ;;
                --name) snapshot_name="$2"; shift 2 ;;
                --data-dir) [[ "$2" == "$K3S_DATA_DIR" ]] || return 1; shift 2 ;;
                --etcd-s3=false) shift ;;
                *) return 1 ;;
            esac
        done
        [[ -d "$snapshot_dir" && -n "$snapshot_name" ]] || return 1
        printf 'fixture-etcd-snapshot\n' > "$snapshot_dir/$snapshot_name-node-1234"
    }
    kubectl() { return 1; }
    export -f install k3s kubectl
    # Only replace privilege checks and fixed host paths. All datastore, archive,
    # integrity, and retention logic comes from the production script.
    # shellcheck disable=SC1090
    source <(sed \
        -e '/^\[\[ "\$EUID" -eq 0 \]\]/d' \
        -e "s|^POSTGRES_ACCESS_LIBRARY=.*|POSTGRES_ACCESS_LIBRARY='$SCRIPT_DIR/lib/postgres-access.sh'|" \
        -e "s|/run/lock/|$TEST_DIR/locks/|g" \
        -e "s|/var/lib/bm-cluster/|$TEST_DIR/vault/|g" \
        "$SCRIPT_DIR/backup-k3s.sh")
)

# SQLite servers can have an empty etcd directory from initial installation.
mkdir "$TEST_DIR/data/server/db/etcd"
run_backup sqlite >/dev/null
mapfile -t sqlite_archives < <(find "$TEST_DIR/sqlite" -name 'k3s-*.tar.gz')
[[ ${#sqlite_archives[@]} -eq 1 ]]
mkdir "$TEST_DIR/sqlite-extracted"
tar -xzf "${sqlite_archives[0]}" -C "$TEST_DIR/sqlite-extracted"
grep -Fxq 'Datastore: sqlite' "$TEST_DIR/sqlite-extracted/RESTORE.txt"
[[ "$(sqlite3 "$TEST_DIR/sqlite-extracted/k3s-db/state.db" 'SELECT count(*) FROM kine;')" == 1 ]]
[[ "$(sqlite3 "$TEST_DIR/data/server/db/state.db" 'SELECT count(*) FROM kine;')" == 3 ]]
cmp "$TEST_DIR/data/server/token" "$TEST_DIR/sqlite-extracted/k3s-server/token"
cmp "$TEST_DIR/config/config.yaml.d/20-bm-private-node-network.yaml" \
    "$TEST_DIR/sqlite-extracted/k3s-config/config.yaml.d/20-bm-private-node-network.yaml"

# Retain state.db to prove an etcd migration can never silently back up stale SQLite.
mkdir "$TEST_DIR/data/server/db/etcd/member"
run_backup etcd >/dev/null
mapfile -t etcd_archives < <(find "$TEST_DIR/etcd" -name 'k3s-*.tar.gz')
[[ ${#etcd_archives[@]} -eq 1 ]]
mkdir "$TEST_DIR/etcd-extracted"
tar -xzf "${etcd_archives[0]}" -C "$TEST_DIR/etcd-extracted"
grep -Fxq 'Datastore: etcd' "$TEST_DIR/etcd-extracted/RESTORE.txt"
grep -Fq -- '--cluster-reset-restore-path=' "$TEST_DIR/etcd-extracted/RESTORE.txt"
[[ ! -f "$TEST_DIR/etcd-extracted/k3s-db/state.db" ]]
mapfile -t snapshot_files < <(find "$TEST_DIR/etcd-extracted/k3s-db" -type f)
[[ ${#snapshot_files[@]} -eq 1 ]]
grep -Fxq 'fixture-etcd-snapshot' "${snapshot_files[0]}"
cmp "$TEST_DIR/data/server/token" "$TEST_DIR/etcd-extracted/k3s-server/token"

# Execute failure cases in independent shells so errexit remains active even
# while the caller checks the exit status.
export SCRIPT_DIR TEST_DIR
export -f run_backup
if MOCK_SNAPSHOT_FAIL=true bash -c 'set -e; run_backup snapshot-failed' >/dev/null 2>&1; then
    printf 'Failed etcd snapshot was accepted.\n' >&2
    exit 1
fi
[[ -z "$(find "$TEST_DIR/snapshot-failed" -name 'k3s-*.tar.gz')" ]]
mv "$TEST_DIR/data/server/token" "$TEST_DIR/saved-token"
if bash -c 'set -e; run_backup missing-token' >/dev/null 2>&1; then
    printf 'A backup without the server token was accepted.\n' >&2
    exit 1
fi

printf '[PASS] SQLite and etcd recovery archives, migration detection, token requirement, and snapshot failure\n'
