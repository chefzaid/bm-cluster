#!/usr/bin/env bash
# Reconcile control-plane scheduling and Longhorn replication from live nodes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_CONFIG="$REPOSITORY_ROOT/config/platform.env"
CONTROL_PLANE_SCHEDULABLE="${CONTROL_PLANE_SCHEDULABLE:-preserve}"
EXPECTED_NODE_COUNT="${CLUSTER_NODE_COUNT:-}"
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
Reconcile topology-dependent cluster configuration from Ready Kubernetes nodes.

Usage: scripts/reconcile-cluster-topology.sh [options]

  --control-plane-schedulable true|false|preserve
  --expected-node-count COUNT
  --update-longhorn-helm
  --longhorn-chart-version VERSION
  --longhorn-timeout DURATION
  --print-longhorn-replicas
  --replicas-for-worker-count COUNT

Longhorn uses one replica on a control-plane-only cluster. As soon as workers
exist, the control plane is excluded from Longhorn storage scheduling and the
default replica count equals the number of Ready workers.
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
        -h|--help)
            usage
            exit 0
            ;;
        *) fail "Unknown option: $1" ;;
    esac
done

case "${CONTROL_PLANE_SCHEDULABLE,,}" in
    1|true|yes|y|worker|controller-worker) CONTROL_PLANE_SCHEDULABLE=true ;;
    0|false|no|n|controller|controller-only) CONTROL_PLANE_SCHEDULABLE=false ;;
    preserve|'') CONTROL_PLANE_SCHEDULABLE=preserve ;;
    *) fail "--control-plane-schedulable must be true, false, or preserve" ;;
esac
[[ -z "$EXPECTED_NODE_COUNT" || "$EXPECTED_NODE_COUNT" =~ ^[1-9][0-9]*$ ]] || \
    fail "--expected-node-count must be a positive integer"
if [[ -n "$CALCULATE_WORKER_COUNT" ]]; then
    longhorn_replica_count "$CALCULATE_WORKER_COUNT" || \
        fail "--replicas-for-worker-count must be a non-negative integer"
    exit 0
fi

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
kubectl cluster-info >/dev/null 2>&1 || fail "Cannot reach the Kubernetes API"

nodes_json="$(kubectl get nodes -o json)"
ready_node_count="$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<< "$nodes_json")"
ready_worker_count="$(jq '[.items[] |
    select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
    select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) | not) |
    select((.metadata.labels | has("node-role.kubernetes.io/master")) | not)
] | length' <<< "$nodes_json")"
replica_count="$(longhorn_replica_count "$ready_worker_count")"

if [[ "$PRINT_REPLICA_COUNT" == "true" ]]; then
    printf '%s\n' "$replica_count"
    exit 0
fi

(( ready_node_count >= 1 )) || fail "No Ready Kubernetes node was found"
if [[ -n "$EXPECTED_NODE_COUNT" && "$ready_node_count" -ne "$EXPECTED_NODE_COUNT" ]]; then
    fail "Expected $EXPECTED_NODE_COUNT Ready nodes, but found $ready_node_count"
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
    elif jq -e '[.items[] |
        select((.metadata.labels | has("node-role.kubernetes.io/control-plane")) or
               (.metadata.labels | has("node-role.kubernetes.io/master"))) |
        .spec.taints[]? |
        select((.key == "node-role.kubernetes.io/control-plane" or
                .key == "node-role.kubernetes.io/master") and .effect == "NoSchedule")
    ] | length > 0' <<< "$nodes_json" >/dev/null; then
        CONTROL_PLANE_SCHEDULABLE=false
    else
        CONTROL_PLANE_SCHEDULABLE=true
    fi
fi

if [[ "$ready_node_count" -eq 1 && "$CONTROL_PLANE_SCHEDULABLE" != "true" ]]; then
    fail "A control-plane-only cluster must allow workloads on its control plane"
fi

if [[ "$CONTROL_PLANE_SCHEDULABLE" == "true" ]]; then
    for taint_key in node-role.kubernetes.io/control-plane node-role.kubernetes.io/master; do
        kubectl taint nodes "${control_plane_nodes[@]}" \
            "$taint_key:NoSchedule-" >/dev/null 2>&1 || true
    done
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
    helm upgrade longhorn longhorn \
        --repo https://charts.longhorn.io \
        --namespace longhorn-system \
        --version "$LONGHORN_CHART_VERSION" \
        --reuse-values \
        --set "defaultSettings.defaultReplicaCount=$replica_count" \
        --set "persistence.defaultClassReplicaCount=$replica_count" \
        --wait --timeout "$LONGHORN_HELM_TIMEOUT" >/dev/null
fi

if [[ "$longhorn_installed" == "true" ]]; then
    if kubectl -n longhorn-system get configmap longhorn-default-setting >/dev/null 2>&1; then
        default_setting_yaml="$(kubectl -n longhorn-system get configmap longhorn-default-setting \
            -o jsonpath='{.data.default-setting\.yaml}')"
        default_setting_yaml="$(sed -E \
            "s/^([[:space:]]*default-replica-count:).*/\\1 \"$replica_count\"/" \
            <<< "$default_setting_yaml")"
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

    allow_control_plane_storage=true
    eviction_requested=false
    if (( ready_worker_count > 0 )); then
        allow_control_plane_storage=false
        eviction_requested=true
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

    mapfile -t longhorn_volumes < <(kubectl -n longhorn-system get volumes.longhorn.io -o json |
        jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name')
    volume_patch="$(jq -cn --argjson replicas "$replica_count" \
        '{spec: {numberOfReplicas: $replicas}}')"
    for volume in "${longhorn_volumes[@]}"; do
        kubectl -n longhorn-system patch volumes.longhorn.io "$volume" \
            --type=merge -p "$volume_patch" >/dev/null
    done

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
    info "Longhorn defaults and ${#longhorn_volumes[@]} existing volume(s) use $replica_count replica(s); control-plane storage scheduling is $allow_control_plane_storage."
fi

if kubectl get namespace infra >/dev/null 2>&1; then
    kubectl -n infra create configmap bm-cluster-topology \
        --from-literal="expectedNodeCount=${EXPECTED_NODE_COUNT:-$ready_node_count}" \
        --from-literal="readyNodeCount=$ready_node_count" \
        --from-literal="readyWorkerCount=$ready_worker_count" \
        --from-literal="controlPlaneSchedulable=$CONTROL_PLANE_SCHEDULABLE" \
        --from-literal="longhornReplicaCount=$replica_count" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    info "Cluster topology configuration is reconciled in infra/bm-cluster-topology."
fi
