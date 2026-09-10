#!/usr/bin/env bash
# Resolve the database serving the canonical Service, including CNPG failover.
postgres_runtime_target() {
    local namespace="${1:-infra}" service selector primary pod
    service="$(kubectl -n "$namespace" get service postgres -o json)" || return 1
    selector="$(jq -cS '.spec.selector' <<< "$service")" || return 1
    if [[ "$selector" == '{"app":"postgres"}' ]]; then
        printf 'deployment/postgres\n'
    elif [[ "$selector" == '{"cnpg.io/cluster":"postgres-ha","cnpg.io/instanceRole":"primary"}' ]]; then
        primary="$(kubectl -n "$namespace" get cluster.postgresql.cnpg.io postgres-ha \
            -o jsonpath='{.status.currentPrimary}')" || return 1
        [[ "$primary" =~ ^postgres-ha-[0-9]+$ ]] || {
            printf 'No current CNPG PostgreSQL primary is available\n' >&2
            return 1
        }
        pod="$(kubectl -n "$namespace" get pod "$primary" -o json)" || return 1
        jq -e '.metadata.deletionTimestamp == null and
            .metadata.labels["cnpg.io/cluster"] == "postgres-ha" and
            .metadata.labels["cnpg.io/instanceRole"] == "primary" and
            any(.status.conditions[]?; .type == "Ready" and .status == "True")' \
            <<< "$pod" >/dev/null || {
            printf 'The selected CNPG PostgreSQL primary is not Ready\n' >&2
            return 1
        }
        printf 'pod/%s\n' "$primary"
    else
        printf 'Unsupported canonical PostgreSQL Service selector; refusing a guessed database target\n' >&2
        return 1
    fi
}
