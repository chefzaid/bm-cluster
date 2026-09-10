#!/usr/bin/env bash
# Exercise reconciliation through its CLI without contacting a cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPOLOGY_SCRIPT="$SCRIPT_DIR/reconcile-cluster-topology.sh"
unset CLUSTER_NODE_COUNT CONTROL_PLANE_COUNT CONTROL_PLANE_SCHEDULABLE HIGH_AVAILABILITY_ENABLED

command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 1; }

kubectl() {
    case "$*" in
        cluster-info|'get namespace infra') return 0 ;;
        'get nodes -o json') printf '%s\n' "$MOCK_NODES_JSON" ;;
        '-n infra get configmap bm-cluster-topology --ignore-not-found '*)
            printf '%s' "${MOCK_STORED_HA_MODE:-}"
            return "${MOCK_STORED_HA_EXIT:-0}"
            ;;
        '-n infra get configmap bm-cluster-topology '*) printf '%s' "${MOCK_STORED_MODE:-}" ;;
        '-n longhorn-system get settings.longhorn.io default-replica-count')
            [[ "${MOCK_LONGHORN:-false}" == true ]]
            ;;
        '-n longhorn-system get settings.longhorn.io default-replica-count -o '*) printf '1' ;;
        '-n longhorn-system get configmap '*) return 1 ;;
        '-n longhorn-system get volumes.longhorn.io -o json')
            printf '%s\n' "${MOCK_VOLUMES_JSON:-{\"items\":[]}}"
            ;;
        'get storageclass longhorn '*) return 1 ;;
        'taint nodes '*)
            printf 'MOCK %s\n' "$*" >&3
            return "${MOCK_TAINT_EXIT:-0}"
            ;;
        '-n longhorn-system patch volumes.longhorn.io '*)
            printf 'MOCK %s\n' "$*" >&3
            return "${MOCK_VOLUME_PATCH_EXIT:-0}"
            ;;
        'label nodes '*|'-n longhorn-system patch '*|'-n infra create configmap '*)
            printf 'MOCK %s\n' "$*" >&3
            ;;
        'apply -f -') while IFS= read -r _line; do :; done ;;
        *) printf 'Unexpected kubectl invocation: %s\n' "$*" >&2; return 99 ;;
    esac
}
export -f kubectl

helm() { printf 'MOCK helm %s\n' "$*" >&3; }
export -f helm

nodes() {
    local cp_count="$1" workers="$2" ready_cps="${3:-$1}" ready_workers="${4:-$2}" taints="${5:-none}"
    MOCK_NODES_JSON="$(jq -cn \
        --argjson cps "$cp_count" --argjson workers "$workers" \
        --argjson readyCps "$ready_cps" --argjson readyWorkers "$ready_workers" \
        --arg taints "$taints" '
        {items: (
            [range(0; $cps) | . as $index |
                {metadata: {name: ("cp-" + tostring), labels: {"node-role.kubernetes.io/control-plane": "true"}},
                 status: {conditions: [{type: "Ready", status: (if . < $readyCps then "True" else "False" end)}]},
                 spec: {taints: (
                    if $taints == "all" or ($taints == "mixed" and $index == 0) then
                        [{key: "node-role.kubernetes.io/control-plane", effect: "NoSchedule"}]
                    elif $taints == "legacy" then
                        [{key: "node-role.kubernetes.io/master", effect: "NoSchedule"},
                         {key: "maintenance", effect: "NoExecute"}]
                    else [] end)}}] +
            [range(0; $workers) |
                {metadata: {name: ("worker-" + tostring), labels: {}},
                 status: {conditions: [{type: "Ready", status: (if . < $readyWorkers then "True" else "False" end)}]},
                 spec: {}}])}')"
    export MOCK_NODES_JSON
    unset MOCK_STORED_MODE MOCK_LONGHORN MOCK_TAINT_EXIT MOCK_VOLUMES_JSON MOCK_VOLUME_PATCH_EXIT
    unset MOCK_STORED_HA_MODE MOCK_STORED_HA_EXIT
    unset HIGH_AVAILABILITY_ENABLED
}

run_success() {
    if ! TEST_OUTPUT="$(bash "$TOPOLOGY_SCRIPT" "$@" 3>&1 2>&1)"; then
        printf 'Expected success: %s\n%s\n' "$*" "$TEST_OUTPUT" >&2
        exit 1
    fi
}

run_failure() {
    if TEST_OUTPUT="$(bash "$TOPOLOGY_SCRIPT" "$@" 3>&1 2>&1)"; then
        printf 'Expected failure: %s\n%s\n' "$*" "$TEST_OUTPUT" >&2
        exit 1
    fi
    if [[ "$TEST_OUTPUT" == *'MOCK '* ]]; then
        printf 'Validation failure changed cluster state:\n%s\n' "$TEST_OUTPUT" >&2
        exit 1
    fi
}

assert_output() {
    [[ "$TEST_OUTPUT" == *"$1"* ]] || {
        printf 'Expected output to contain %s:\n%s\n' "$1" "$TEST_OUTPUT" >&2
        exit 1
    }
}

assert_no_output() {
    [[ "$TEST_OUTPUT" != *"$1"* ]] || {
        printf 'Unexpected output containing %s:\n%s\n' "$1" "$TEST_OUTPUT" >&2
        exit 1
    }
}

for control_planes in 1 3 5; do
    nodes "$control_planes" 0
    run_success --expected-node-count "$control_planes" --expected-control-plane-count "$control_planes" --control-plane-schedulable true
    assert_output "--from-literal=controlPlaneCount=$control_planes"
    assert_output '--from-literal=workerCount=0'
    assert_output '--from-literal=longhornReplicaCount=1'
    run_failure --control-plane-schedulable false
    assert_output 'Controller-only mode requires at least one Ready worker'
done

for invalid_count in 0 2 4 invalid; do
    run_failure --expected-control-plane-count "$invalid_count"
    assert_output 'must be a positive odd integer'
done
run_failure --expected-node-count 2 --expected-control-plane-count 3
assert_output 'cannot exceed the expected node count'

nodes 3 2
export MOCK_LONGHORN=true
run_success --expected-node-count 5 --expected-control-plane-count 3 --control-plane-schedulable false
assert_output 'taint nodes cp-0 cp-1 cp-2 node-role.kubernetes.io/control-plane:NoSchedule --overwrite'
assert_output '--from-literal=readyControlPlaneCount=3'
assert_output '--from-literal=readyWorkerCount=2'
assert_output '--from-literal=longhornReplicaCount=2'
for node in cp-0 cp-1 cp-2; do
    assert_output "patch nodes.longhorn.io $node --type=merge -p {\"spec\":{\"allowScheduling\":false,\"evictionRequested\":true}}"
done
run_failure --expected-node-count 5 --expected-control-plane-count 1 --control-plane-schedulable false
assert_output 'Expected 1 registered control-plane nodes, but found 3'

nodes 3 3 3 2
run_failure --expected-node-count 5 --expected-control-plane-count 3 --control-plane-schedulable false
assert_output 'Expected 5 registered nodes, but found 6 (5 Ready)'
run_failure --expected-node-count 6 --control-plane-schedulable false
assert_output 'Expected 6 Ready nodes, but found 5'

nodes 3 2 2 2
run_failure --expected-control-plane-count 3 --control-plane-schedulable false
assert_output 'Expected 3 Ready control-plane nodes, but found 2'

nodes 3 2 3 0
run_failure --control-plane-schedulable false
assert_output 'Controller-only mode requires at least one Ready worker'
export MOCK_LONGHORN=true
run_success --control-plane-schedulable true
assert_output '"allowScheduling":false,"evictionRequested":false'
assert_output '--from-literal=workerCount=2'
assert_output '--from-literal=readyWorkerCount=0'
assert_output '--from-literal=longhornReplicaCount=2'

nodes 3 2 3 2 mixed
run_failure --control-plane-schedulable preserve
assert_output 'Control-plane scheduling is mixed'
export MOCK_STORED_MODE=false
run_success --control-plane-schedulable preserve
assert_output '--from-literal=controlPlaneSchedulable=false'

nodes 3 2 3 2 all
run_success --control-plane-schedulable preserve
assert_output '--from-literal=controlPlaneSchedulable=false'

nodes 3 2 3 2 legacy
run_success --control-plane-schedulable true
for node in cp-0 cp-1 cp-2; do
    assert_output "taint nodes $node node-role.kubernetes.io/master:NoSchedule-"
done
[[ "$TEST_OUTPUT" != *maintenance* ]] || { printf 'Unrelated taint was removed\n' >&2; exit 1; }
export MOCK_TAINT_EXIT=1
if TEST_OUTPUT="$(bash "$TOPOLOGY_SCRIPT" --control-plane-schedulable true 3>&1 2>&1)"; then
    printf 'Taint removal errors must fail reconciliation\n' >&2
    exit 1
fi
[[ "$TEST_OUTPUT" != *'create configmap'* ]] || { printf 'Failed taint change was persisted\n' >&2; exit 1; }

# A transient worker failure does not lower the desired storage redundancy.
nodes 3 3 3 2
export MOCK_LONGHORN=true
run_success --control-plane-schedulable false --update-longhorn-helm
assert_output '--set defaultSettings.defaultReplicaCount=3'
assert_output '--set persistence.defaultClassReplicaCount=3'
assert_output '--from-literal=longhornReplicaCount=3'
run_success --print-longhorn-replicas
[[ "$TEST_OUTPUT" == 3 ]] || { printf 'Replica preview changed during a worker outage\n' >&2; exit 1; }

# HA validates registered capacity before any cluster mutation, including preview.
nodes 1 3
export HIGH_AVAILABILITY_ENABLED=true
run_failure --control-plane-schedulable true
assert_output 'HA requires at least three registered control-plane nodes'
run_failure --control-plane-schedulable true --print-longhorn-replicas

nodes 3 2
export HIGH_AVAILABILITY_ENABLED=true
run_failure --control-plane-schedulable false
assert_output 'HA requires at least three registered storage-eligible nodes'
run_failure --control-plane-schedulable false --print-longhorn-replicas

nodes 3 0
export HIGH_AVAILABILITY_ENABLED=invalid
run_failure --control-plane-schedulable true
assert_output 'HIGH_AVAILABILITY_ENABLED must be true or false'

# Three schedulable control planes provide three independent HA storage peers.
nodes 3 0
export HIGH_AVAILABILITY_ENABLED=true MOCK_LONGHORN=true
run_success --control-plane-schedulable true --update-longhorn-helm
assert_output '--set defaultSettings.defaultReplicaCount=3'
assert_output '--set defaultSettings.replicaSoftAntiAffinity=false'
assert_output 'patch settings.longhorn.io replica-soft-anti-affinity --type=merge -p {"value":"false"}'
assert_output '--from-literal=longhornReplicaCount=3'
assert_output '--from-literal=highAvailabilityEnabled=true'
for node in cp-0 cp-1 cp-2; do
    assert_output "patch nodes.longhorn.io $node --type=merge -p {\"spec\":{\"allowScheduling\":true,\"evictionRequested\":false}}"
done
run_success --control-plane-schedulable preserve --print-longhorn-replicas
[[ "$TEST_OUTPUT" == 3 ]] || { printf 'HA replica preview is not three\n' >&2; exit 1; }

# Adding a worker in HA does not evict storage from schedulable control planes.
nodes 3 1 2 0
export HIGH_AVAILABILITY_ENABLED=true MOCK_LONGHORN=true
run_success --control-plane-schedulable true
assert_output '--from-literal=longhornReplicaCount=3'
assert_output '"allowScheduling":true,"evictionRequested":false'

# Dedicated HA workers retain three replicas even while one worker is down.
nodes 3 3 3 2 all
export HIGH_AVAILABILITY_ENABLED=true MOCK_LONGHORN=true
run_success --control-plane-schedulable preserve
assert_output '--from-literal=longhornReplicaCount=3'
assert_output '"allowScheduling":false,"evictionRequested":true'

# Existing volumes only grow. Higher counts and deleting volumes remain untouched.
export MOCK_VOLUMES_JSON='{"items":[
    {"metadata":{"name":"grow"},"spec":{"numberOfReplicas":1}},
    {"metadata":{"name":"equal"},"spec":{"numberOfReplicas":3}},
    {"metadata":{"name":"larger"},"spec":{"numberOfReplicas":4}},
    {"metadata":{"name":"deleting","deletionTimestamp":"2026-01-01T00:00:00Z"},"spec":{"numberOfReplicas":1}}
]}'
run_success --control-plane-schedulable false
assert_output 'patch volumes.longhorn.io grow --type=json -p [{"op":"test","path":"/spec/numberOfReplicas","value":1},{"op":"replace","path":"/spec/numberOfReplicas","value":3}]'
for volume in equal larger deleting; do
    assert_no_output "patch volumes.longhorn.io $volume "
done
assert_no_output '"size"'

# A volume override must not permit three nominal replicas on one host.
export MOCK_VOLUMES_JSON='{"items":[
    {"metadata":{"name":"colocated"},"spec":{"numberOfReplicas":4,"replicaSoftAntiAffinity":"enabled"}},
    {"metadata":{"name":"inherited"},"spec":{"numberOfReplicas":3,"replicaSoftAntiAffinity":"ignored"}},
    {"metadata":{"name":"deleting","deletionTimestamp":"2026-01-01T00:00:00Z"},"spec":{"numberOfReplicas":3,"replicaSoftAntiAffinity":"enabled"}}
]}'
run_success --control-plane-schedulable false
assert_output 'patch volumes.longhorn.io colocated --type=json -p [{"op":"test","path":"/spec/replicaSoftAntiAffinity","value":"enabled"},{"op":"replace","path":"/spec/replicaSoftAntiAffinity","value":"disabled"}]'
assert_no_output '/spec/numberOfReplicas'
assert_no_output 'patch volumes.longhorn.io inherited '
assert_no_output 'patch volumes.longhorn.io deleting '

# An actual concurrent replica change fails its atomic test instead of overwriting.
export MOCK_VOLUME_PATCH_EXIT=1
if TEST_OUTPUT="$(bash "$TOPOLOGY_SCRIPT" --control-plane-schedulable false 3>&1 2>&1)"; then
    printf 'Concurrent replica changes must fail reconciliation\n' >&2
    exit 1
fi
assert_no_output 'create configmap bm-cluster-topology'

# Explicit node removal can lower the default, but cannot shrink existing volumes.
nodes 1 1
export MOCK_LONGHORN=true
export MOCK_VOLUMES_JSON='{"items":[{"metadata":{"name":"preserve"},"spec":{"numberOfReplicas":3}}]}'
run_success --control-plane-schedulable false
assert_output '--from-literal=longhornReplicaCount=1'
assert_no_output 'patch volumes.longhorn.io preserve '

# Persisted HA cannot disappear through an ordinary rerun or read-only query.
nodes 3 0
export MOCK_STORED_HA_MODE=true
run_success --print-longhorn-replicas
[[ "$TEST_OUTPUT" == 3 ]]
run_success --control-plane-schedulable true
assert_output '--from-literal=highAvailabilityEnabled=true'
export HIGH_AVAILABILITY_ENABLED=false
run_failure --print-longhorn-replicas
assert_output 'Cannot disable persisted HA mode'
run_success --allow-ha-disable --control-plane-schedulable true
assert_output '--from-literal=highAvailabilityEnabled=false'
assert_output '--from-literal=longhornReplicaCount=1'
unset HIGH_AVAILABILITY_ENABLED
run_failure --allow-ha-disable
assert_output 'requires explicit HIGH_AVAILABILITY_ENABLED=false'
export MOCK_STORED_HA_MODE=invalid
run_failure
assert_output 'Persisted highAvailabilityEnabled must be true or false'
export MOCK_STORED_HA_MODE='' MOCK_STORED_HA_EXIT=1
run_failure
assert_output 'Cannot read persisted HA topology mode'

printf 'Topology CLI tests passed (quorum, persisted HA, storage capacity, outages, placement and non-decreasing volume replicas).\n'
