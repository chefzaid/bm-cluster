#!/usr/bin/env bash
set -euo pipefail

# Admission also protects future replacements. Touch existing controllers once
# so newly installed/updated policies take effect without waiting for a restart.
for target in \
  kube-system/local-path-provisioner \
  kube-system/metrics-server \
  kube-system/coredns \
  longhorn-system/csi-attacher \
  longhorn-system/csi-provisioner \
  longhorn-system/csi-resizer \
  longhorn-system/csi-snapshotter \
  longhorn-system/longhorn-driver-deployer \
  longhorn-system/longhorn-ui; do
  namespace="${target%%/*}"
  deployment="${target#*/}"
  existing="$(kubectl get deployment "$deployment" -n "$namespace" --ignore-not-found -o name)"
  [[ -n "$existing" ]] || continue
  image_policy="$(kubectl get mutatingadmissionpolicy "bm-$deployment-security-image" --ignore-not-found \
    -o 'jsonpath={.spec.mutations[0].applyConfiguration.expression}')"
  expected_image="$(sed -n "s/.*image: '\([^']*\)'.*/\1/p" <<< "$image_policy")"
  patch='{"metadata":{"annotations":{"security.bm-cluster.io/template-hardening":"v1"}}}'
  # Policy informer caches update asynchronously after kubectl apply.
  ready=false
  for (( attempt=0; attempt<30; attempt++ )); do
    preview="$(kubectl patch deployment "$deployment" -n "$namespace" --type=merge \
      -p "$patch" --dry-run=server \
      -o 'jsonpath={.spec.template.spec.securityContext.seccompProfile.type}/{.spec.template.spec.containers[0].securityContext.capabilities.drop}')"
    if [[ "$preview" == 'RuntimeDefault/["ALL"]' ]]; then
      if [[ -n "$expected_image" ]]; then
        preview_image="$(kubectl patch deployment "$deployment" -n "$namespace" --type=merge \
          -p "$patch" --dry-run=server -o "jsonpath={.spec.template.spec.containers[?(@.name==\"$deployment\")].image}")"
        if [[ "$preview_image" != "$expected_image" ]]; then
          sleep 1
          continue
        fi
      fi
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    echo "Hardening admission did not mutate $target; refusing an unverified rollout" >&2
    exit 1
  fi
  if [[ "$expected_image" == *"/security/$deployment:"* ]]; then
    kubectl wait --for=condition=Ready externalsecret/platform-registry-auth \
      -n "$namespace" --timeout=120s
  fi
  kubectl patch deployment "$deployment" -n "$namespace" --type=merge -p "$patch"
  kubectl rollout status "deployment/$deployment" -n "$namespace" --timeout=180s
done
