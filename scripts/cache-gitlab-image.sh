#!/usr/bin/env bash
# Share the same registry-restart protection between imperative install paths.
set -euo pipefail
k8s_dir="${1:?Usage: cache-gitlab-image.sh RENDERED_K8S_DIRECTORY [TIMEOUT]}"
timeout="${2:-10m}"
kubectl apply -f "$k8s_dir/platform/gitlab-image-cache.yaml"
kubectl rollout status daemonset/gitlab-image-cache -n infra --timeout="$timeout"
