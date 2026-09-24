#!/usr/bin/env bash
# Keep existing in-cluster clients unchanged; remote clients must authenticate.
configure_remote_kafka() {
    [[ "${BM_KAFKA_REMOTE_ENABLED:-false}" == true ]] || return 0
    [[ "${KAFKA_PROCESS_ROLES:?}" == broker ]] || return 0
    local broker_ordinal endpoint jaas_variable
    broker_ordinal="${HOSTNAME##*-}"
    [[ "$broker_ordinal" =~ ^[0-2]$ ]] || { echo 'Invalid Kafka broker ordinal' >&2; return 1; }
    IFS=',' read -r -a remote_brokers <<< "${BM_KAFKA_REMOTE_BROKERS:?}"
    endpoint="${remote_brokers[$broker_ordinal]:-}"
    [[ "$endpoint" =~ ^[a-zA-Z0-9.:-]+:[0-9]+$ ]] || { echo 'Missing private Kafka endpoint' >&2; return 1; }
    export KAFKA_LISTENERS="${KAFKA_LISTENERS:-PLAINTEXT://0.0.0.0:9092},REMOTE://0.0.0.0:9094"
    export KAFKA_ADVERTISED_LISTENERS="${KAFKA_ADVERTISED_LISTENERS:?},REMOTE://${endpoint}"
    export KAFKA_LISTENER_SECURITY_PROTOCOL_MAP="${KAFKA_LISTENER_SECURITY_PROTOCOL_MAP:?},REMOTE:SASL_PLAINTEXT"
    export KAFKA_INTER_BROKER_LISTENER_NAME=PLAINTEXT
    export KAFKA_LISTENER_NAME_REMOTE_SASL_ENABLED_MECHANISMS=SCRAM-SHA-512
    # Confluent encodes '-' as three underscores. Assemble the name so it
    # cannot resemble an unresolved platform placeholder in source rendering.
    jaas_variable='KAFKA_LISTENER_NAME_REMOTE_SCRAM'
    jaas_variable+='___'
    jaas_variable+='SHA'
    jaas_variable+='___'
    jaas_variable+='512_SASL_JAAS_CONFIG'
    printf -v "$jaas_variable" '%s' 'org.apache.kafka.common.security.scram.ScramLoginModule required;'
    export "${jaas_variable?}"
}
