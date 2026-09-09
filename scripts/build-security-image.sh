#!/usr/bin/env bash
set -euo pipefail
umask 077
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
component="${1:?Usage: build-security-image.sh COMPONENT IMAGE_REFERENCE [OUTPUT_DIRECTORY]}"
image="${2:?An immutable build tag is required}"
output="${3:-$root/.cache/security-images/$component}"
[[ "$component" =~ ^[a-z][a-z0-9-]*$ && -f "$root/images/security/$component.Dockerfile" ]] || exit 2
mkdir -p "$output"
output="$(cd "$output" && pwd)"
if [[ -n "${KANIKO_EXECUTOR:-}" ]]; then
  : "${CI_REGISTRY_USER:?}" "${CI_REGISTRY_PASSWORD:?}" "${REGISTRY_PUSH_HOST:?}"
  mkdir -p /kaniko/.docker
  jq -n --arg registry "$REGISTRY_PUSH_HOST" --arg username "$CI_REGISTRY_USER" \
    --arg password "$CI_REGISTRY_PASSWORD" \
    '{auths:{($registry):{username:$username,password:$password}}}' > /kaniko/.docker/config.json
  export DOCKER_CONFIG=/kaniko/.docker
  # One image per job. Kaniko mutates its own filesystem, so it must never be
  # reused for a second build. Disable layer caching to fetch package updates.
  "$KANIKO_EXECUTOR" --context "dir://$root/images/security" \
    --dockerfile "$root/images/security/$component.Dockerfile" \
    --destination "$image" --cache=false --cleanup \
    --insecure-registry "$REGISTRY_PUSH_HOST" --digest-file "$output/digest.txt"
else
  # Omnibus includes Prometheus's large provider SDKs; its serialized Go build
  # needs 3 GiB. Keep other image builds at their existing limit.
  build_memory=2g
  [[ "$component" != gitlab ]] || build_memory=3g
  DOCKER_BUILDKIT=0 docker build --pull --no-cache --memory="$build_memory" --memory-swap="$build_memory" --cpu-quota=100000 \
    -f "$root/images/security/$component.Dockerfile" -t "$image" "$root/images/security"
fi
if [[ -n "${TRIVY_EXECUTABLE:-}" ]]; then
  : "${TRIVY_SERVER:?Use the same database as the production operator}"
  "$TRIVY_EXECUTABLE" image --server "$TRIVY_SERVER" --scanners vuln,secret \
    --format json --output "$output/scan.json" "$image"
fi
printf 'Built %s; review scan output and runtime smoke checks before updating deployment digests.\n' "$image"
