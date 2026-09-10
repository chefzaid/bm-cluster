#!/usr/bin/env bash
# Run the patched upstream regressions without using the live Kubernetes cluster.
set -euo pipefail
umask 077
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${1:?Usage: test-external-secrets-source.sh SOURCE LOG_DIRECTORY [unit|controllers|all]}"
logs="${2:?A private log directory is required}"
mode="${3:-all}"
case "$mode" in
  unit) targets=(security-unit) ;;
  controllers) targets=(security-controllers) ;;
  all) targets=(security-unit security-controllers) ;;
  *) printf 'Unknown test mode: %s\n' "$mode" >&2; exit 2 ;;
esac
source_dir="$(cd "$source_dir" && pwd)"
go_binary="${EXTERNAL_SECRETS_GO:-go}"
make_binary="${EXTERNAL_SECRETS_MAKE:-make}"
[[ "$("$go_binary" version)" == 'go version go1.26.7 '* ]]
[[ "$(git -C "$source_dir" rev-parse HEAD)" == 279f56c84d5d4058c3bfdeeaf5b1c2febb8851c0 ]]
git -C "$source_dir" apply --reverse --check "$root/images/security/external-secrets.patch"
git -C "$source_dir" apply --reverse --check "$root/images/security/external-secrets-version.patch"
[[ "$(git -C "$source_dir" rev-parse 'v2.10.0^{commit}')" == 279f56c84d5d4058c3bfdeeaf5b1c2febb8851c0 ]]
if [[ "$mode" != unit ]]; then
  : "${KUBEBUILDER_ASSETS:?Set this to verified Kubernetes 1.36 envtest binaries}"
  [[ -x "$KUBEBUILDER_ASSETS/kube-apiserver" && -x "$KUBEBUILDER_ASSETS/etcd" ]]
  [[ "$("$KUBEBUILDER_ASSETS/kube-apiserver" --version)" == 'Kubernetes v1.36.'* ]]
fi
mkdir -p "$logs"
logs="$(cd "$logs" && pwd)"
# Envtest creates a disposable API server and etcd. Never inherit an instruction
# to run its reconciliation tests against a real cluster or use local credentials.
unset KUBECONFIG KUBERNETES_SERVICE_HOST KUBERNETES_SERVICE_PORT
export USE_EXISTING_CLUSTER=false GOTOOLCHAIN=local GOWORK=off GOFLAGS=-mod=readonly
export GOMAXPROCS="${GOMAXPROCS:-1}" GOMEMLIMIT="${GOMEMLIMIT:-1800MiB}" GOGC="${GOGC:-20}"
for target in "${targets[@]}"; do
  "$make_binary" -C "$source_dir" -f "$root/images/security/external-secrets/Makefile" \
    GO="$go_binary" "$target" > "$logs/$target.log" 2>&1
  printf '%s passed\n' "$target"
done
