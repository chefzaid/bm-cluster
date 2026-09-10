#!/usr/bin/env bash
# Reconcile control-plane scheduling and Longhorn replication from live nodes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_CONFIG="$REPOSITORY_ROOT/config/platform.env"
CONTROL_PLANE_SCHEDULABLE="${CONTROL_PLANE_SCHEDULABLE:-preserve}"
HIGH_AVAILABILITY_ENABLED="${HIGH_AVAILABILITY_ENABLED:-}"
ALLOW_HA_DISABLE=false
EXPECTED_NODE_COUNT="${CLUSTER_NODE_COUNT:-}"
EXPECTED_CONTROL_PLANE_COUNT=""
UPDATE_LONGHORN_HELM=false
PRINT_REPLICA_COUNT=false
CALCULATE_WORKER_COUNT=""
LONGHORN_CHART_VERSION=""
LONGHORN_HELM_TIMEOUT="1200s"

if [[ -r "$PLATFORM_CONFIG" ]]; then
    # shellcheck source=../config/platform.env
    source "$PLATFORM_CONFIG"
    LONGHORN_CHART_VERSION="${DEFAULT_LONGHORN_CHART_VERSION:-}"
    LONGHORN_HELM_TIMEOUT="${DEFAULT_LONGHORN_HELM_TIMEOUT:-1200s}"
fi

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

longhorn_replica_count() {
    local worker_count="$1"

    [[ "$worker_count" =~ ^[0-9]+$ ]] || return 1
    (( worker_count >= 1 )) && printf '%s\n' "$worker_count" || printf '1\n'
}

usage() {
    cat <<'EOF'
Reconcile topology-dependent cluster configuration from registered Kubernetes nodes.

Usage: scripts/reconcile-cluster-topology.sh [options]

  --control-plane-schedulable true|false|preserve
  --expected-node-count COUNT
  --expected-control-plane-count COUNT
  --update-longhorn-helm
  --longhorn-chart-version VERSION
  --longhorn-timeout DURATION
  --print-longhorn-replicas
  --replicas-for-worker-count COUNT
  --allow-ha-disable

Expected counts require the corresponding registered nodes to be Ready.
The control-plane count must be odd: 1 for standalone or 3, 5, ... for HA.
HIGH_AVAILABILITY_ENABLED=true requires at least three registered control planes
and three storage-eligible nodes, and selects three Longhorn replicas. Schedulable
control planes participate in HA storage alongside workers.
Otherwise, Longhorn uses max(registered workers, 1) replicas and excludes control
planes from storage when workers exist. Existing volumes are never automatically
reduced. --replicas-for-worker-count is the offline non-HA replica calculator.
An omitted HIGH_AVAILABILITY_ENABLED inherits the persisted topology mode.
Disabling a persisted HA mode requires explicit HIGH_AVAILABILITY_ENABLED=false
and --allow-ha-disable, after a separately planned application/storage migration.
This override does not migrate databases or shrink existing volume replicas.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --control-plane-schedulable)
            (( $# >= 2 )) || fail "$1 requires true, false, or preserve"
            CONTROL_PLANE_SCHEDULABLE="$2"
            shift 2
            ;;
        --expected-node-count)
            (( $# >= 2 )) || fail "$1 requires a positive integer"
            EXPECTED_NODE_COUNT="$2"
            shift 2
            ;;
        --expected-control-plane-count)
            (( $# >= 2 )) || fail "$1 requires a positive odd integer"
            EXPECTED_CONTROL_PLANE_COUNT="$2"
            shift 2
            ;;
        --update-longhorn-helm)
            UPDATE_LONGHORN_HELM=true
            shift
            ;;
        --longhorn-chart-version)
            (( $# >= 2 )) || fail "$1 requires a version"
            LONGHORN_CHART_VERSION="$2"
            shift 2
            ;;
        --longhorn-timeout)
            (( $# >= 2 )) || fail "$1 requires a duration"
            LONGHORN_HELM_TIMEOUT="$2"
            shift 2
            ;;
        --print-longhorn-replicas)
            PRINT_REPLICA_COUNT=true
            shift
            ;;
        --replicas-for-worker-count)
            (( $# >= 2 )) || fail "$1 requires a non-negative integer"
            CALCULATE_WORKER_COUNT="$2"
            shift 2
            ;;
        --allow-ha-disable)
            ALLOW_HA_DISABLE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[[ -z "$HIGH_AVAILABILITY_ENABLED" || "$HIGH_AVAILABILITY_ENABLED" == true || "$HIGH_AVAILABILITY_ENABLED" == false ]] || \
    fail "HIGH_AVAILABILITY_ENABLED must be true or false"
[[ "$ALLOW_HA_DISABLE" == false || "$HIGH_AVAILABILITY_ENABLED" == false ]] || \
    fail "--allow-ha-disable requires explicit HIGH_AVAILABILITY_ENABLED=false"
case "${CONTROL_PLANE_SCHEDULABLE,,}" in
    1|true|yes|y|worker|controller-worker) CONTROL_PLANE_SCHEDULABLE=true ;;
    0|false|no|n|controller|controller-only) CONTROL_PLANE_SCHEDULABLE=false ;;
    preserve|'') CONTROL_PLANE_SCHEDULABLE=preserve ;;
    *) fail "--control-plane-schedulable must be true, false, or preserve" ;;
esac
[[ -z "$EXPECTED_NODE_COUNT" || "$EXPECTED_NODE_COUNT" =~ ^[1-9][0-9]*$ ]] || \
    fail "--expected-node-count must be a positive integer"
if [[ -n "$EXPECTED_CONTROL_PLANE_COUNT" ]]; then
    [[ "$EXPECTED_CONTROL_PLANE_COUNT" =~ ^[1-9][0-9]*$ &&
       "${EXPECTED_CONTROL_PLANE_COUNT: -1}" =~ ^[13579]$ ]] || \
        fail "--expected-control-plane-count must be a positive odd integer"
    [[ -z "$EXPECTED_NODE_COUNT" || "$EXPECTED_CONTROL_PLANE_COUNT" -le "$EXPECTED_NODE_COUNT" ]] || \
        fail "The expected control-plane count cannot exceed the expected node count"
fi
if [[ -n "$CALCULATE_WORKER_COUNT" ]]; then
    longhorn_replica_count "$CALCULATE_WORKER_COUNT" || \
        fail "--replicas-for-worker-count must be a non-negative integer"
    exit 0
fi

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
kubectl cluster-info >/dev/null 2>&1 || fail "Cannot reach the Kubernetes API"
stored_ha_mode="$(kubectl -n infra get configmap bm-cluster-topology --ignore-not-found \
    -o jsonpath='{.data.highAvailabilityEnabled}')" || fail "Cannot read persisted HA topology mode"
[[ -z "$stored_ha_mode" || "$stored_ha_mode" == true || "$stored_ha_mode" == false ]] || \
    fail "Persisted highAvailabilityEnabled must be true or false"
if [[ "$stored_ha_mode" == true && "$HIGH_AVAILABILITY_ENABLED" == false && "$ALLOW_HA_DISABLE" != true ]]; then
    fail "Cannot disable persisted HA mode without --allow-ha-disable and a planned migration"
fi
HIGH_AVAILABILITY_ENABLED="${HIGH_AVAILABILITY_ENABLED:-${stored_ha_mode:-false}}"

nodes_json="$(kubectl get nodes -o json)"
node_count="$(jq '.items | length' <<< "$nodes_json")"
ready_node_count="$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<< "$nodes_json")"
control_plane_count="$(jq '[.items[] |
    select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
           (.metadata.labels | has("node-role.kubernetes.io/master")))
] | length' <<< "$nodes_json")"
ready_control_plane_count="$(jq '[.items[] |
    select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
    select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
           (.metadata.labels | has("node-role.kubernetes.io/master")))
] | length' <<< "$nodes_json")"
worker_count=$((node_count - control_plane_count))
ready_worker_count="$(jq '[.items[] |
    select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
    select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) | not) |
    select((.metadata.labels | has("node-role.kubernetes.io/master")) | not)
] | length' <<< "$nodes_json")"
replica_count="$(longhorn_replica_count "$worker_count")"

if [[ "$PRINT_REPLICA_COUNT" == "true" && "$HIGH_AVAILABILITY_ENABLED" == false ]]; then
    printf '%s\n' "$replica_count"
    exit 0
fi

(( ready_node_count >= 1 )) || fail "No Ready Kubernetes node was found"
if [[ -n "$EXPECTED_NODE_COUNT" ]]; then
    [[ "$node_count" -eq "$EXPECTED_NODE_COUNT" ]] || \
        fail "Expected $EXPECTED_NODE_COUNT registered nodes, but found $node_count ($ready_node_count Ready)"
    [[ "$ready_node_count" -eq "$EXPECTED_NODE_COUNT" ]] || \
        fail "Expected $EXPECTED_NODE_COUNT Ready nodes, but found $ready_node_count"
fi
if [[ -n "$EXPECTED_CONTROL_PLANE_COUNT" ]]; then
    [[ "$control_plane_count" -eq "$EXPECTED_CONTROL_PLANE_COUNT" ]] || \
        fail "Expected $EXPECTED_CONTROL_PLANE_COUNT registered control-plane nodes, but found $control_plane_count"
    [[ "$ready_control_plane_count" -eq "$EXPECTED_CONTROL_PLANE_COUNT" ]] || \
        fail "Expected $EXPECTED_CONTROL_PLANE_COUNT Ready control-plane nodes, but found $ready_control_plane_count"
fi

mapfile -t control_plane_nodes < <(jq -r '.items[] |
    select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
           (.metadata.labels | has("node-role.kubernetes.io/master"))) |
    .metadata.name' <<< "$nodes_json")
(( ${#control_plane_nodes[@]} >= 1 )) || fail "No control-plane node was found"

if [[ "$CONTROL_PLANE_SCHEDULABLE" == "preserve" ]]; then
    stored_mode="$(kubectl -n infra get configmap bm-cluster-topology \
        -o jsonpath='{.data.controlPlaneSchedulable}' 2>/dev/null || true)"
    if [[ "$stored_mode" =~ ^(true|false)$ ]]; then
        CONTROL_PLANE_SCHEDULABLE="$stored_mode"
    else
        tainted_control_plane_count="$(jq '[.items[] |
        select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
               (.metadata.labels | has("node-role.kubernetes.io/master"))) |
        select(any(.spec.taints[]?;
            (.key == "node-role.kubernetes.io/control-plane" or
             .key == "node-role.kubernetes.io/master") and .effect == "NoSchedule"))
        ] | length' <<< "$nodes_json")"
        if (( tainted_control_plane_count == control_plane_count )); then
            CONTROL_PLANE_SCHEDULABLE=false
        elif (( tainted_control_plane_count == 0 )); then
            CONTROL_PLANE_SCHEDULABLE=true
        else
            fail "Control-plane scheduling is mixed; explicitly choose --control-plane-schedulable true|false"
        fi
    fi
fi

if [[ "$CONTROL_PLANE_SCHEDULABLE" != "true" && "$ready_worker_count" -eq 0 ]]; then
    fail "Controller-only mode requires at least one Ready worker; a control-plane-only cluster must allow workloads on its control planes"
fi

if [[ "$HIGH_AVAILABILITY_ENABLED" == true ]]; then
    (( control_plane_count >= 3 )) || \
        fail "HA requires at least three registered control-plane nodes; found $control_plane_count"
    storage_node_count="$worker_count"
    if [[ "$CONTROL_PLANE_SCHEDULABLE" == true ]]; then
        storage_node_count=$((storage_node_count + control_plane_count))
    fi
    (( storage_node_count >= 3 )) || \
        fail "HA requires at least three registered storage-eligible nodes; found $storage_node_count"
    replica_count=3
fi

if [[ "$PRINT_REPLICA_COUNT" == true ]]; then
    printf '%s\n' "$replica_count"
    exit 0
fi

if [[ "$CONTROL_PLANE_SCHEDULABLE" == "true" ]]; then
    while IFS=$'\t' read -r node taint_key; do
        [[ -n "$node" ]] || continue
        kubectl taint nodes "$node" "$taint_key:NoSchedule-" >/dev/null
    done < <(jq -r '.items[] |
        select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
               (.metadata.labels | has("node-role.kubernetes.io/master"))) |
        .metadata.name as $node | .spec.taints[]? |
        select((.key == "node-role.kubernetes.io/control-plane" or
                .key == "node-role.kubernetes.io/master") and .effect == "NoSchedule") |
        [$node, .key] | @tsv' <<< "$nodes_json")
    control_plane_mode=controller-worker
    info "Control-plane nodes are schedulable controller-workers."
else
    kubectl taint nodes "${control_plane_nodes[@]}" \
        node-role.kubernetes.io/control-plane:NoSchedule --overwrite >/dev/null
    control_plane_mode=controller-only
    info "Control-plane nodes are controller-only."
fi
kubectl label nodes "${control_plane_nodes[@]}" \
    "node.bm-cluster.io/control-plane-mode=$control_plane_mode" \
    --overwrite >/dev/null

longhorn_installed=false
if kubectl -n longhorn-system get settings.longhorn.io default-replica-count >/dev/null 2>&1; then
    longhorn_installed=true
fi

if [[ "$longhorn_installed" == "true" && "$UPDATE_LONGHORN_HELM" == "true" ]]; then
    command -v helm >/dev/null 2>&1 || fail "helm is required to persist Longhorn topology values"
    [[ -n "$LONGHORN_CHART_VERSION" ]] || fail "The Longhorn chart version is required"
    info "Persisting Longhorn's $replica_count-replica default in its Helm release."
    longhorn_ha_values=()
    if [[ "$HIGH_AVAILABILITY_ENABLED" == true ]]; then
        longhorn_ha_values=(--set defaultSettings.replicaSoftAntiAffinity=false
            --set defaultSettings.nodeDownPodDeletionPolicy=do-nothing)
    fi
    helm upgrade longhorn longhorn \
        --repo https://charts.longhorn.io \
        --namespace longhorn-system \
        --version "$LONGHORN_CHART_VERSION" \
        --reuse-values \
        --set "defaultSettings.defaultReplicaCount=$replica_count" \
        --set "persistence.defaultClassReplicaCount=$replica_count" \
        "${longhorn_ha_values[@]}" \
        --wait --timeout "$LONGHORN_HELM_TIMEOUT" >/dev/null
fi

if [[ "$longhorn_installed" == "true" ]]; then
    if kubectl -n longhorn-system get configmap longhorn-default-setting >/dev/null 2>&1; then
        default_setting_yaml="$(kubectl -n longhorn-system get configmap longhorn-default-setting \
            -o jsonpath='{.data.default-setting\.yaml}')"
        default_setting_yaml="$(sed -E \
            "s/^([[:space:]]*default-replica-count:).*/\\1 \"$replica_count\"/" \
            <<< "$default_setting_yaml")"
        if [[ "$HIGH_AVAILABILITY_ENABLED" == true ]]; then
            if [[ "$default_setting_yaml" == *replica-soft-anti-affinity:* ]]; then
                default_setting_yaml="$(sed -E 's/^([[:space:]]*replica-soft-anti-affinity:).*/\1 "false"/' <<< "$default_setting_yaml")"
            else
                default_setting_yaml+=$'\nreplica-soft-anti-affinity: "false"'
            fi
            if [[ "$default_setting_yaml" == *node-down-pod-deletion-policy:* ]]; then
                default_setting_yaml="$(sed -E 's/^([[:space:]]*node-down-pod-deletion-policy:).*/\1 "do-nothing"/' <<< "$default_setting_yaml")"
            else
                default_setting_yaml+=$'\nnode-down-pod-deletion-policy: "do-nothing"'
            fi
        fi
        configmap_patch="$(jq -cn --arg value "$default_setting_yaml" \
            '{data: {"default-setting.yaml": $value}}')"
        kubectl -n longhorn-system patch configmap longhorn-default-setting \
            --type=merge -p "$configmap_patch" >/dev/null
    fi
    if kubectl -n longhorn-system get configmap longhorn-storageclass >/dev/null 2>&1; then
        storage_class_yaml="$(kubectl -n longhorn-system get configmap longhorn-storageclass \
            -o jsonpath='{.data.storageclass\.yaml}')"
        storage_class_yaml="$(sed -E \
            "s/^([[:space:]]*numberOfReplicas:).*/\\1 \"$replica_count\"/" \
            <<< "$storage_class_yaml")"
        configmap_patch="$(jq -cn --arg value "$storage_class_yaml" \
            '{data: {"storageclass.yaml": $value}}')"
        kubectl -n longhorn-system patch configmap longhorn-storageclass \
            --type=merge -p "$configmap_patch" >/dev/null
    fi

    current_setting="$(kubectl -n longhorn-system get settings.longhorn.io default-replica-count \
        -o jsonpath='{.value}')"
    if jq -e 'type == "object"' >/dev/null 2>&1 <<< "$current_setting"; then
        desired_setting="$(jq -c --arg replicas "$replica_count" 'with_entries(.value = $replicas)' <<< "$current_setting")"
    else
        desired_setting="$replica_count"
    fi
    setting_patch="$(jq -cn --arg value "$desired_setting" '{value: $value}')"
    kubectl -n longhorn-system patch settings.longhorn.io default-replica-count \
        --type=merge -p "$setting_patch" >/dev/null
    if [[ "$HIGH_AVAILABILITY_ENABLED" == true ]]; then
        kubectl -n longhorn-system patch settings.longhorn.io replica-soft-anti-affinity \
            --type=merge -p '{"value":"false"}' >/dev/null
    fi

    allow_control_plane_storage=true
    eviction_requested=false
    if [[ "$HIGH_AVAILABILITY_ENABLED" == true ]]; then
        allow_control_plane_storage="$CONTROL_PLANE_SCHEDULABLE"
        if [[ "$allow_control_plane_storage" == false && "$ready_worker_count" -gt 0 ]]; then
            eviction_requested=true
        fi
    elif (( worker_count > 0 )); then
        allow_control_plane_storage=false
        if (( ready_worker_count > 0 )); then
            eviction_requested=true
        fi
    fi
    longhorn_node_patch="$(jq -cn \
        --argjson allowed "$allow_control_plane_storage" \
        --argjson eviction "$eviction_requested" \
        '{spec: {allowScheduling: $allowed, evictionRequested: $eviction}}')"
    for node in "${control_plane_nodes[@]}"; do
        kubectl -n longhorn-system patch nodes.longhorn.io "$node" \
            --type=merge -p "$longhorn_node_patch" >/dev/null 2>&1 || \
            warn "Longhorn has not registered control-plane node $node yet."
    done

    longhorn_volumes_json="$(kubectl -n longhorn-system get volumes.longhorn.io -o json)"
    # Readiness and node removal must not silently reduce existing redundancy.
    # Test the observed count atomically so a concurrent increase is preserved.
    while IFS=$'\t' read -r volume previous_replicas; do
        [[ -n "$volume" ]] || continue
        volume_patch="$(jq -cn --argjson previous "$previous_replicas" --argjson replicas "$replica_count" '
            [{op: "test", path: "/spec/numberOfReplicas", value: $previous},
             {op: "replace", path: "/spec/numberOfReplicas", value: $replicas}]')"
        kubectl -n longhorn-system patch volumes.longhorn.io "$volume" \
            --type=json -p "$volume_patch" >/dev/null
    done < <(jq -r --argjson replicas "$replica_count" '
        .items[] | select(.metadata.deletionTimestamp == null) |
        select(.spec.numberOfReplicas < $replicas) |
        [.metadata.name, .spec.numberOfReplicas] | @tsv' <<< "$longhorn_volumes_json")
    if [[ "$HIGH_AVAILABILITY_ENABLED" == true ]]; then
        kubectl -n longhorn-system patch settings.longhorn.io node-down-pod-deletion-policy \
            --type=merge -p '{"value":"do-nothing"}' >/dev/null
        while IFS= read -r volume; do
            [[ -n "$volume" ]] || continue
            kubectl -n longhorn-system patch volumes.longhorn.io "$volume" --type=json -p \
                '[{"op":"test","path":"/spec/replicaSoftAntiAffinity","value":"enabled"},{"op":"replace","path":"/spec/replicaSoftAntiAffinity","value":"disabled"}]' >/dev/null
        done < <(jq -r '.items[] | select(.metadata.deletionTimestamp == null) |
            select(.spec.replicaSoftAntiAffinity == "enabled") | .metadata.name' <<< "$longhorn_volumes_json")
        info "Longhorn requires replicas on distinct hosts. Wait for rebuilding and verify actual healthy replica placement before declaring storage redundant."
    fi

    storage_class_replicas="$(kubectl get storageclass longhorn \
        -o jsonpath='{.parameters.numberOfReplicas}' 2>/dev/null || true)"
    if [[ -n "$storage_class_replicas" && "$storage_class_replicas" != "$replica_count" ]]; then
        warn "Recreating the Longhorn StorageClass with $replica_count replicas; existing PVCs and volumes are unaffected."
        kubectl get storageclass longhorn -o json |
            jq --arg replicas "$replica_count" '
                del(.metadata.creationTimestamp, .metadata.generation,
                    .metadata.managedFields, .metadata.resourceVersion,
                    .metadata.uid, .metadata.annotations["longhorn.io/last-applied-configmap"]) |
                .parameters.numberOfReplicas = $replicas
            ' |
            kubectl replace --force -f - >/dev/null
    fi
    info "Longhorn default is $replica_count replica(s); existing volumes retain at least their previous count. Control-plane storage scheduling is $allow_control_plane_storage."
fi

if kubectl get namespace infra >/dev/null 2>&1; then
    kubectl -n infra create configmap bm-cluster-topology \
        --from-literal="expectedNodeCount=${EXPECTED_NODE_COUNT:-$node_count}" \
        --from-literal="expectedControlPlaneCount=${EXPECTED_CONTROL_PLANE_COUNT:-$control_plane_count}" \
        --from-literal="nodeCount=$node_count" \
        --from-literal="readyNodeCount=$ready_node_count" \
        --from-literal="controlPlaneCount=$control_plane_count" \
        --from-literal="readyControlPlaneCount=$ready_control_plane_count" \
        --from-literal="workerCount=$worker_count" \
        --from-literal="readyWorkerCount=$ready_worker_count" \
        --from-literal="controlPlaneSchedulable=$CONTROL_PLANE_SCHEDULABLE" \
        --from-literal="highAvailabilityEnabled=$HIGH_AVAILABILITY_ENABLED" \
        --from-literal="longhornReplicaCount=$replica_count" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    info "Cluster topology configuration is reconciled in infra/bm-cluster-topology."
fi
