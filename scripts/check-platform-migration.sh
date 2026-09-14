#!/usr/bin/env bash
# Read-only gate before reconciling installations that use retired components.
set -euo pipefail
approved="${PLATFORM_MIGRATION_APPROVED:-false}"
[[ "$approved" =~ ^(true|false)$ ]] || { echo 'PLATFORM_MIGRATION_APPROVED must be true or false.' >&2; exit 1; }
workloads="$(kubectl get deployments,statefulsets,daemonsets -n infra -o json)"
legacy="$(jq -er 'if type != "object" or (.items | type) != "array" then
    error("Expected a Kubernetes workload list") else
  any(.items[];
    .metadata.name == "ingress-nginx-controller" or
    any(.spec.template.spec.containers[]?, .spec.template.spec.initContainers[]?;
      (.image // "") | test("/security/"))) | tostring end' <<< "$workloads")"
if [[ "$legacy" == true ]]; then
    if [[ "$approved" != true ]]; then
        echo 'This installation requires the ingress/upstream-image migration in docs/platform-migration.md. Set PLATFORM_MIGRATION_APPROVED=true only for that prepared maintenance run.' >&2
        exit 1
    fi
    echo '[INFO] Explicit legacy-platform migration selected.'
fi
