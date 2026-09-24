#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. /opt/bm-cluster/kafka-remote-env.sh
configure_remote_kafka
exec /etc/confluent/docker/run
