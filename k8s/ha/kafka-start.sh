#!/usr/bin/env bash
# Dynamic KRaft startup. Existing original PVCs must never silently reformat.
set -euo pipefail
# shellcheck source=/dev/null
. /etc/confluent/docker/bash-config

: "${POD_NAME:?}" "${POD_NAMESPACE:?}" "${CLUSTER_ID:?}" "${KAFKA_PROCESS_ROLES:?}"
: "${KAFKA_LOG_DIRS:?}" "${BM_KAFKA_ALLOW_INITIAL_FORMAT:?}"
ordinal="${POD_NAME##*-}"
[[ "$ordinal" =~ ^[0-2]$ ]] || { printf 'Unexpected Kafka ordinal\n' >&2; exit 1; }
case "$KAFKA_PROCESS_ROLES" in
    controller)
        export KAFKA_NODE_ID=$((3000 + ordinal))
        export KAFKA_LISTENERS=CONTROLLER://0.0.0.0:9093
        export KAFKA_ADVERTISED_LISTENERS="CONTROLLER://${POD_NAME}.kafka-controller.${POD_NAMESPACE}.svc.cluster.local:9093"
        ;;
    broker)
        export KAFKA_NODE_ID=$((1 + ordinal))
        export KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092
        export KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://${POD_NAME}.kafka.${POD_NAMESPACE}.svc.cluster.local:9092"
        ;;
    *) printf 'Kafka roles must remain separate controller/broker processes\n' >&2; exit 1 ;;
esac
export LOG_DIR=/tmp/kafka-runtime
mkdir -p "$LOG_DIR"
unset KAFKA_CONTROLLER_QUORUM_VOTERS
export KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT
export KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
ub path /etc/kafka/ writable
ub render-template "/etc/confluent/docker/${COMPONENT}.properties.template" > "/etc/${COMPONENT}/${COMPONENT}.properties"
ub render-template /etc/confluent/docker/log4j2.yaml.template > "/etc/${COMPONENT}/log4j2.yaml"
ub render-template /etc/confluent/docker/tools-log4j2.yaml.template > "/etc/${COMPONENT}/tools-log4j2.yaml"

mkdir -p "$KAFKA_LOG_DIRS"
if [[ -f "$KAFKA_LOG_DIRS/meta.properties" ]]; then
    stored_cluster="$(sed -n 's/^cluster.id=//p' "$KAFKA_LOG_DIRS/meta.properties")"
    stored_node="$(sed -n 's/^node.id=//p' "$KAFKA_LOG_DIRS/meta.properties")"
    [[ "$stored_cluster" == "$CLUSTER_ID" && "$stored_node" == "$KAFKA_NODE_ID" ]] || {
        printf 'Existing Kafka storage identity differs; refusing startup/reformat\n' >&2
        exit 1
    }
else
    [[ -z "$(find "$KAFKA_LOG_DIRS" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
        printf 'Kafka data exists without meta.properties; restore metadata before startup\n' >&2
        exit 1
    }
    if [[ "$ordinal" == 0 && "$BM_KAFKA_ALLOW_INITIAL_FORMAT" != true ]]; then
        printf 'Original Kafka PVC is unformatted; explicit fresh bootstrap or recovery is required\n' >&2
        exit 1
    fi
    format_option=--no-initial-controllers
    if [[ "$KAFKA_PROCESS_ROLES" == controller && "$ordinal" == 0 ]]; then
        format_option=--standalone
    fi
    kafka-storage format --cluster-id "$CLUSTER_ID" --config /etc/kafka/kafka.properties "$format_option"
fi
exec /etc/confluent/docker/launch
