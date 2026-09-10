#!/usr/bin/env bash
set -euo pipefail

# Admission protects future replacements. Reconcile existing controllers too;
# validate the entire selected image set before changing a stored template.
for target in \
  deployment/kube-system/local-path-provisioner \
  deployment/kube-system/metrics-server \
  deployment/kube-system/coredns \
  deployment/longhorn-system/csi-attacher \
  deployment/longhorn-system/csi-provisioner \
  deployment/longhorn-system/csi-resizer \
  deployment/longhorn-system/csi-snapshotter \
  deployment/longhorn-system/longhorn-driver-deployer \
  deployment/longhorn-system/longhorn-ui \
  daemonset/longhorn-system/longhorn-csi-plugin \
  deployment/infra/ingress-nginx-controller \
  daemonset/infra/ingress-nginx-controller; do
  IFS=/ read -r kind namespace name <<< "$target"
  existing="$(kubectl get "$kind" "$name" -n "$namespace" --ignore-not-found -o name)"
  [[ -n "$existing" ]] || continue
  policy="$(kubectl get mutatingadmissionpolicy "bm-$name-security-image" --ignore-not-found -o json)"
  ha_dns=false
  if [[ "$name" == coredns ]] && [[ -n "$(kubectl get mutatingadmissionpolicy bm-coredns-availability --ignore-not-found -o name)" ]]; then
    ha_dns=true
  fi
  expected='{}'
  if [[ -n "$policy" ]]; then
    expected="$(jq -c '[.spec.mutations[] | .applyConfiguration.expression // empty |
      scan("name: '\''([^'\'']+)'\'',\\s*image: '\''([^'\'']+)'\''") |
      {key: .[0], value: .[1]}] | from_entries' <<< "$policy")"
    if [[ "$expected" == '{}' ]]; then
      echo "Cannot read images from bm-$name-security-image; refusing an unverified rollout" >&2
      exit 1
    fi
  fi
  patch='{"metadata":{"annotations":{"security.bm-cluster.io/template-hardening":"v2"}}}'
  ready=false
  # Policy informer caches update asynchronously after kubectl apply.
  for (( attempt=0; attempt<30; attempt++ )); do
    preview="$(kubectl patch "$kind" "$name" -n "$namespace" --type=merge \
      -p "$patch" --dry-run=server -o json)"
    if jq -e --argjson expected "$expected" --arg kind "$kind" --arg name "$name" --argjson haDns "$ha_dns" '
      .spec.template.spec as $pod |
      ([$pod.containers[] | {key: .name, value: .image}] | from_entries) as $actual |
      all($expected | to_entries[]; $actual[.key] == .value) and
      (if $haDns then .spec.replicas == 3 and any($pod.topologySpreadConstraints[]?;
        .minDomains == 3 and .topologyKey == "kubernetes.io/hostname" and
        .whenUnsatisfiable == "DoNotSchedule") else true end) and
      all($pod.containers[] | select($kind != "daemonset" or $name != "longhorn-csi-plugin" or
        .name == "node-driver-registrar" or .name == "longhorn-liveness-probe");
        ((.securityContext.seccompProfile.type // $pod.securityContext.seccompProfile.type) == "RuntimeDefault") and
        ((.securityContext.capabilities.drop // []) | index("ALL") != null) and
        (.securityContext.allowPrivilegeEscalation == false))
      ' <<< "$preview" >/dev/null; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    echo "Admission did not apply the expected images and hardening to $target" >&2
    exit 1
  fi
  if jq -e 'any(.[]; contains("/swirlit/bm-cluster/security/"))' <<< "$expected" >/dev/null; then
    kubectl wait --for=condition=Ready externalsecret/platform-registry-auth \
      -n "$namespace" --timeout=120s
  fi
  kubectl patch "$kind" "$name" -n "$namespace" --type=merge -p "$patch"
  kubectl rollout status "$kind/$name" -n "$namespace" --timeout=180s
done
