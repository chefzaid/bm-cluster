#!/usr/bin/env bash
# Exercise canonical Service selection, failover and unsafe/stale targets offline.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/postgres-access.sh
source "$SCRIPT_DIR/lib/postgres-access.sh"
kubectl() {
    case "$*" in
        '-n infra get service postgres -o json') printf '%s\n' "$SERVICE" ;;
        '-n infra get cluster.postgresql.cnpg.io postgres-ha '*) printf '%s' "$PRIMARY" ;;
        '-n infra get pod postgres-ha-'*' -o json') printf '%s\n' "$POD" ;;
        *) printf 'Unexpected kubectl command: %s\n' "$*" >&2; return 1 ;;
    esac
}
SERVICE='{"spec":{"selector":{"app":"postgres"}}}'
[[ "$(postgres_runtime_target)" == deployment/postgres ]]
SERVICE='{"spec":{"selector":{"cnpg.io/cluster":"postgres-ha","cnpg.io/instanceRole":"primary"}}}'
for PRIMARY in postgres-ha-1 postgres-ha-3; do
    POD='{"metadata":{"labels":{"cnpg.io/cluster":"postgres-ha","cnpg.io/instanceRole":"primary"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
    [[ "$(postgres_runtime_target)" == "pod/$PRIMARY" ]]
done
POD='{"metadata":{"labels":{"cnpg.io/cluster":"postgres-ha","cnpg.io/instanceRole":"replica"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
if postgres_runtime_target >/dev/null 2>&1; then printf 'Accepted a stale primary label\n' >&2; exit 1; fi
POD='{"metadata":{"deletionTimestamp":"2026-01-01T00:00:00Z","labels":{"cnpg.io/cluster":"postgres-ha","cnpg.io/instanceRole":"primary"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
if postgres_runtime_target >/dev/null 2>&1; then printf 'Accepted a terminating primary\n' >&2; exit 1; fi
PRIMARY=''
if postgres_runtime_target >/dev/null 2>&1; then printf 'Accepted absent primary\n' >&2; exit 1; fi
SERVICE='{"spec":{"selector":{"app":"postgres","unexpected":"other"}}}'
if postgres_runtime_target >/dev/null 2>&1; then printf 'Accepted ambiguous Service selector\n' >&2; exit 1; fi
printf 'PostgreSQL primary selection tests passed.\n'
