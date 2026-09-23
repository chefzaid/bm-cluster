#!/usr/bin/env bash
# Topology planning only; callers supply prompts, logging, and AUTO_APPROVE.

cluster_plan_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ && ${#1} -le 9 ]]
}

cluster_plan_target_count() {
    local targets="$1" target
    local -a entries=()
    local -A seen=()
    [[ -n "$targets" ]] || { printf '0\n'; return; }
    [[ "$targets" != ,* && "$targets" != *, && "$targets" != *,,* ]] || \
        { printf 'Target lists cannot contain empty entries.\n' >&2; return 1; }
    IFS=',' read -r -a entries <<< "$targets"
    for target in "${entries[@]}"; do
        [[ "$target" != *[[:space:]]* && -n "$target" && -z "${seen[$target]:-}" ]] || \
            { printf 'Target lists must contain unique hosts without whitespace.\n' >&2; return 1; }
        seen[$target]=1
    done
    printf '%s\n' "${#entries[@]}"
}

cluster_plan_inventory() {
    # Count registered nodes, including NotReady nodes, so reruns cannot silently
    # replace a failed etcd member or plan removal of an existing worker.
    # An operator's kubeconfig can point at a different cluster. Only inventory
    # the local server that this installer is allowed to extend.
    systemctl cat k3s.service >/dev/null 2>&1 || return 0
    command -v k3s >/dev/null 2>&1 || {
        error "The local K3s service has no binary; restore it before planning enrollment."
        return 1
    }
    local inventory
    if inventory="$(sudo k3s kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{$cp := false}}{{range $key, $value := .metadata.labels}}{{if or (eq $key "node-role.kubernetes.io/control-plane") (eq $key "node-role.kubernetes.io/master")}}{{$cp = true}}{{end}}{{end}}{{if $cp}}control-plane{{else}}worker{{end}}{{"\n"}}{{end}}' 2>/dev/null)"; then
        printf '%s\n' "$inventory"
    else
        error "Cannot read existing cluster nodes; restore API access before planning enrollment."
        return 1
    fi
}

configure_cluster_topology_plan() {
    local configured_workers configured_control_planes inventory existing_workers existing_control_planes
    local default_control_planes default_node_count control_plane_default

    [[ -z "${K3S_WORKER_HOSTS:-}" || -z "${K3S_WORKER_IPS:-}" ]] || \
        error "Use only one of K3S_WORKER_HOSTS and K3S_WORKER_IPS."
    [[ -z "${K3S_CONTROL_PLANE_HOSTS:-}" || -z "${K3S_CONTROL_PLANE_IPS:-}" ]] || \
        error "Use only one of K3S_CONTROL_PLANE_HOSTS and K3S_CONTROL_PLANE_IPS."
    configured_workers="$(cluster_plan_target_count "${K3S_WORKER_HOSTS:-${K3S_WORKER_IPS:-}}")" || \
        error "Invalid worker target list."
    configured_control_planes="$(cluster_plan_target_count "${K3S_CONTROL_PLANE_HOSTS:-${K3S_CONTROL_PLANE_IPS:-}}")" || \
        error "Invalid control-plane target list."
    if (( configured_workers > 0 && configured_control_planes > 0 )); then
        cluster_plan_target_count "${K3S_CONTROL_PLANE_HOSTS:-${K3S_CONTROL_PLANE_IPS:-}},${K3S_WORKER_HOSTS:-${K3S_WORKER_IPS:-}}" >/dev/null || \
            error "Control-plane and worker target lists must not overlap."
    fi
    inventory="$(cluster_plan_inventory)" || return 1
    existing_control_planes="$(awk '$2 == "control-plane" {n++} END {print n+0}' <<< "$inventory")"
    existing_workers="$(awk '$2 == "worker" {n++} END {print n+0}' <<< "$inventory")"
    default_control_planes="$existing_control_planes"
    (( default_control_planes > 0 )) || default_control_planes=1
    (( configured_control_planes == 0 )) || default_control_planes=$((configured_control_planes + 1))
    # A failed enrollment may temporarily leave two or four registered servers.
    (( default_control_planes % 2 == 1 )) || default_control_planes=$((default_control_planes + 1))

    if [[ "$AUTO_APPROVE" != "true" ]]; then
        while true; do
            installer_prompt_value CONTROL_PLANE_COUNT \
                "Number of control-plane nodes including this host (1, 3, 5, ...; 3 recommended for HA)" \
                "${CONTROL_PLANE_COUNT:-$default_control_planes}"
            if cluster_plan_positive_integer "$CONTROL_PLANE_COUNT" && (( CONTROL_PLANE_COUNT % 2 == 1 )); then
                break
            fi
            warn "Enter an odd positive control-plane count: 1, 3, 5, ...; etcd requires a majority for quorum."
            CONTROL_PLANE_COUNT=""
        done
    else
        CONTROL_PLANE_COUNT="${CONTROL_PLANE_COUNT:-$default_control_planes}"
    fi
    if ! cluster_plan_positive_integer "$CONTROL_PLANE_COUNT" || (( CONTROL_PLANE_COUNT % 2 != 1 )); then
        error "CONTROL_PLANE_COUNT must be an odd positive integer (1, 3, 5, ...)."
    fi
    (( existing_control_planes <= CONTROL_PLANE_COUNT )) || \
        error "The cluster already has $existing_control_planes registered control planes; this installer does not remove nodes."

    default_node_count=$((CONTROL_PLANE_COUNT + existing_workers))
    (( configured_workers == 0 )) || default_node_count=$((CONTROL_PLANE_COUNT + configured_workers))
    if [[ "$AUTO_APPROVE" != "true" ]]; then
        while true; do
            installer_prompt_value CLUSTER_NODE_COUNT \
                "Total number of cluster nodes, including all $CONTROL_PLANE_COUNT control planes" \
                "${CLUSTER_NODE_COUNT:-$default_node_count}"
            if cluster_plan_positive_integer "$CLUSTER_NODE_COUNT" && (( CLUSTER_NODE_COUNT >= CONTROL_PLANE_COUNT )); then
                break
            fi
            warn "Enter a whole number at least $CONTROL_PLANE_COUNT; remaining nodes are workers."
            CLUSTER_NODE_COUNT=""
        done
    else
        CLUSTER_NODE_COUNT="${CLUSTER_NODE_COUNT:-$default_node_count}"
    fi
    if ! cluster_plan_positive_integer "$CLUSTER_NODE_COUNT" || (( CLUSTER_NODE_COUNT < CONTROL_PLANE_COUNT )); then
        error "CLUSTER_NODE_COUNT must be a positive integer at least CONTROL_PLANE_COUNT."
    fi
    PLANNED_WORKER_COUNT=$((CLUSTER_NODE_COUNT - CONTROL_PLANE_COUNT))
    (( existing_workers <= PLANNED_WORKER_COUNT )) || \
        error "The cluster already has $existing_workers registered workers; this installer does not remove nodes."
    WORKERS_TO_ADD=$((PLANNED_WORKER_COUNT - existing_workers))
    (( existing_control_planes > 0 )) || existing_control_planes=1
    CONTROL_PLANES_TO_ADD=$((CONTROL_PLANE_COUNT - existing_control_planes))
    if (( configured_workers > 0 )); then
        (( configured_workers >= WORKERS_TO_ADD && configured_workers <= PLANNED_WORKER_COUNT )) || \
            error "The worker target list must cover $WORKERS_TO_ADD missing workers and cannot exceed $PLANNED_WORKER_COUNT planned workers."
        WORKERS_TO_ADD="$configured_workers"
    fi
    if (( configured_control_planes > 0 )); then
        (( configured_control_planes >= CONTROL_PLANES_TO_ADD && configured_control_planes < CONTROL_PLANE_COUNT )) || \
            error "The control-plane target list must cover $CONTROL_PLANES_TO_ADD missing servers and exclude the bootstrap host."
        CONTROL_PLANES_TO_ADD="$configured_control_planes"
    fi

    if [[ -z "$CONTROL_PLANE_SCHEDULABLE" ]]; then
        (( PLANNED_WORKER_COUNT == 0 )) && control_plane_default=Y || control_plane_default=N
        if ask_with_default \
            "Allow all control planes to run workloads? (No applies the control-plane NoSchedule taint)" \
            "$control_plane_default"; then
            CONTROL_PLANE_SCHEDULABLE=true
        else
            CONTROL_PLANE_SCHEDULABLE=false
        fi
    else
        case "${CONTROL_PLANE_SCHEDULABLE,,}" in
            1|true|yes|y|worker|controller-worker) CONTROL_PLANE_SCHEDULABLE=true ;;
            0|false|no|n|controller|controller-only) CONTROL_PLANE_SCHEDULABLE=false ;;
            *) error "CONTROL_PLANE_SCHEDULABLE must be true or false." ;;
        esac
    fi
    if (( PLANNED_WORKER_COUNT == 0 )) && [[ "$CONTROL_PLANE_SCHEDULABLE" != "true" ]]; then
        error "A cluster without workers must allow workloads on its control planes."
    fi
    export CLUSTER_NODE_COUNT CONTROL_PLANE_COUNT CONTROL_PLANE_SCHEDULABLE
    info "Topology plan: $CONTROL_PLANE_COUNT control plane(s), $PLANNED_WORKER_COUNT worker(s), $CLUSTER_NODE_COUNT total; control-plane schedulable=$CONTROL_PLANE_SCHEDULABLE."
    if (( CONTROL_PLANE_COUNT > 1 )); then
        info "Embedded etcd quorum: $((CONTROL_PLANE_COUNT / 2 + 1)) servers; tolerates $((CONTROL_PLANE_COUNT / 2)) server failure(s)."
    fi
}
