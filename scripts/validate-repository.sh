#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_CONFIG="$REPOSITORY_ROOT/config/platform.env"
K8S_ROOT="$REPOSITORY_ROOT/k8s"
LIVE_VALIDATION=false
FAILURES=0
CHECKS=0
TEMP_DIR="$(mktemp -d /tmp/bm-cluster-validation.XXXXXX)"

cleanup() {
    if [[ "$TEMP_DIR" == /tmp/bm-cluster-validation.* && -d "$TEMP_DIR" ]]; then
        rm -r -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT

info() { printf '[CHECK] %s\n' "$*"; }
pass() { CHECKS=$((CHECKS + 1)); printf '[PASS]  %s\n' "$*"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '[FAIL]  %s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
Validate repository contracts, shell code, Ansible, Kubernetes YAML, images,
and service inventories.

Usage: scripts/validate-repository.sh [--live]

  --live  Also submit every manifest to the active cluster using server-side
          dry-run. This never changes cluster resources.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --live) LIVE_VALIDATION=true ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ -r "$PLATFORM_CONFIG" ]] || { printf 'Missing platform contract: %s\n' "$PLATFORM_CONFIG" >&2; exit 1; }
# shellcheck source=../config/platform.env
source "$PLATFORM_CONFIG"

mapfile -d '' -t kubernetes_manifests < <(
    find "$K8S_ROOT/base" "$K8S_ROOT/datastores" "$K8S_ROOT/platform" \
        "$K8S_ROOT/apps" "$K8S_ROOT/addons" -type f -name '*.yaml' -print0 | LC_ALL=C sort -z
)

csv_to_file() {
    local value="$1" destination="$2"
    tr ',' '\n' <<< "$value" | sed '/^$/d' | LC_ALL=C sort -u > "$destination"
}

compare_sets() {
    local expected="$1" actual="$2" description="$3"
    if cmp -s "$expected" "$actual"; then
        pass "$description"
    else
        fail "$description"
        diff -u "$expected" "$actual" >&2 || true
    fi
}

info "Checking shell syntax"
shell_failed=false
mapfile -d '' -t shell_scripts < <(
    find "$REPOSITORY_ROOT" -path "$REPOSITORY_ROOT/.git" -prune -o -type f -name '*.sh' -print0 |
        LC_ALL=C sort -z
)
for script in "${shell_scripts[@]}"; do
    if ! bash -n "$script"; then
        shell_failed=true
    fi
done
if [[ "$shell_failed" == "true" ]]; then
    fail "all shell scripts parse"
else
    pass "all shell scripts parse"
fi

if command -v shellcheck >/dev/null 2>&1; then
    if (cd "$REPOSITORY_ROOT" && shellcheck -x "${shell_scripts[@]}"); then
        pass "all shell scripts pass ShellCheck"
    else
        fail "all shell scripts pass ShellCheck"
    fi
else
    info "ShellCheck is unavailable; skipping shell static analysis"
fi

# shellcheck source=lib/network.sh
source "$REPOSITORY_ROOT/scripts/lib/network.sh"
if valid_ipv4 10.20.30.40 &&
   ! valid_ipv4 10.20.30.999 &&
   trusted_private_ipv4 192.168.10.5 &&
   trusted_private_ipv4 100.100.10.5 &&
   ! trusted_private_ipv4 203.0.113.10 &&
   trusted_private_cidr 10.50.0.0/24 &&
   cidr_contains_ip 10.50.0.0/24 10.50.0.254 &&
   ! cidr_contains_ip 10.50.0.0/24 10.50.1.1 &&
   [[ "$(server_url_ipv4 https://100.100.10.5:6443)" == 100.100.10.5 ]] &&
   [[ "$(normalize_server_exposure private)" == local ]] &&
   [[ "$(normalize_node_transport v-rack)" == vrack ]] &&
   [[ "$(normalize_node_transport ts)" == tailscale ]]; then
    pass "shared network validation behavior"
else
    fail "shared network validation behavior"
fi

prompt_library="$REPOSITORY_ROOT/scripts/lib/installer-prompts.sh"
prompt_test_output="$(
    printf 'custom-value\nshared-secret\nshared-secret\n2\n' |
        bash -c '
            source "$1"
            installer_prompt_value test_value "Value"
            installer_prompt_confirmed_secret test_secret "Secret" "Confirm"
            installer_prompt_yes_no "Continue?" Y true
            installer_select_node_transport test_transport "" vrack false
            printf "%s:%s:%s\n" "$test_value" "$test_secret" "$test_transport"
        ' _ "$prompt_library" 2>/dev/null
)" || true
prompt_consumers_ok=true
for prompt_consumer in \
    install-control-plane.sh \
    install-worker.sh \
    scripts/add-k3s-workers.sh \
    scripts/install-k3s-worker.sh; do
    grep -Fq 'source "$PROMPT_LIBRARY"' "$REPOSITORY_ROOT/$prompt_consumer" || \
        prompt_consumers_ok=false
done
if [[ "$prompt_test_output" == "custom-value:shared-secret:tailscale" ]] &&
   [[ "$prompt_consumers_ok" == "true" ]] &&
   grep -Fq 'Use the recommended platform component bundle?' \
       "$REPOSITORY_ROOT/install-control-plane.sh"; then
    pass "installers share prompt primitives and group platform component selection"
else
    fail "installers share prompt primitives and group platform component selection"
fi

topology_script="$REPOSITORY_ROOT/scripts/reconcile-cluster-topology.sh"
topology_mapping=""
if [[ -x "$topology_script" ]]; then
    for worker_count in 0 1 2 3 4; do
        replicas="$("$topology_script" --replicas-for-worker-count "$worker_count")" || \
            replicas=invalid
        topology_mapping+="${topology_mapping:+,}$worker_count:$replicas"
    done
fi
if [[ "$topology_mapping" == "0:1,1:1,2:2,3:3,4:4" ]] &&
   grep -Fq 'Total number of cluster nodes, including the control plane' \
       "$REPOSITORY_ROOT/install-control-plane.sh" &&
   grep -Fq 'Allow the control plane to run workloads as a controller-worker?' \
       "$REPOSITORY_ROOT/install-control-plane.sh" &&
   grep -Fq -- '--worker-count "$WORKERS_TO_ADD"' \
       "$REPOSITORY_ROOT/install-control-plane.sh" &&
   grep -Fq 'Switch the control plane to controller-only (NoSchedule) and keep Longhorn storage on workers?' \
       "$REPOSITORY_ROOT/scripts/add-k3s-workers.sh" &&
   grep -Fq 'The control plane is already controller-only; preserving NoSchedule without another question.' \
       "$REPOSITORY_ROOT/scripts/add-k3s-workers.sh" &&
   grep -Fq 'Set --control-plane-schedulable true|false|preserve for non-interactive enrollment.' \
       "$REPOSITORY_ROOT/scripts/add-k3s-workers.sh" &&
   grep -Fq -- '--control-plane-schedulable "$CONTROL_PLANE_SCHEDULABLE"' \
       "$REPOSITORY_ROOT/scripts/add-k3s-workers.sh" &&
   grep -Fq "!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/master" \
       "$REPOSITORY_ROOT/ansible/deploy.yml"; then
    pass "install and worker enrollment share control-plane and Longhorn topology policy"
else
    fail "install and worker enrollment share control-plane and Longhorn topology policy"
fi

tailscale_firewall_line="$(grep -n '^configure_tailscale_firewall_integration$' "$REPOSITORY_ROOT/scripts/configure-node-security.sh" | cut -d: -f1 || true)"
private_ssh_line="$(grep -n '^validate_worker_private_ssh_before_firewall$' "$REPOSITORY_ROOT/scripts/configure-node-security.sh" | cut -d: -f1 || true)"
ufw_apply_line="$(grep -n '^configure_ufw$' "$REPOSITORY_ROOT/scripts/configure-node-security.sh" | cut -d: -f1 || true)"
tailscale_handoff_line="$(grep -n '^make_ufw_authoritative_for_tailscale$' "$REPOSITORY_ROOT/scripts/configure-node-security.sh" | cut -d: -f1 || true)"
tailscale_worker_setup_line="$(grep -n '^if \[\[ "$NODE_TRANSPORT" == "tailscale" \]\]; then$' "$REPOSITORY_ROOT/scripts/install-k3s-worker.sh" | head -n 1 | cut -d: -f1 || true)"
vrack_worker_setup_line="$(grep -n 'Configuring OVHcloud vRack before any UFW changes' "$REPOSITORY_ROOT/scripts/install-k3s-worker.sh" | cut -d: -f1 || true)"
worker_firewall_line="$(grep -n '"\$SECURITY_HARDENER" --apply' "$REPOSITORY_ROOT/scripts/install-k3s-worker.sh" | head -n 1 | cut -d: -f1 || true)"
control_tailscale_setup_line="$(grep -n 'Reconciling the tailnet policy and control-plane role' "$REPOSITORY_ROOT/install-control-plane.sh" | cut -d: -f1 || true)"
control_vrack_attach_line="$(grep -n 'Attaching the control-plane private interface to OVHcloud vRack' "$REPOSITORY_ROOT/install-control-plane.sh" | cut -d: -f1 || true)"
control_vrack_setup_line="$(grep -n 'Configuring and validating the control-plane OVHcloud vRack interface before any firewall changes' "$REPOSITORY_ROOT/install-control-plane.sh" | cut -d: -f1 || true)"
control_firewall_line="$(grep -n 'Applying the .* control-plane host security policy' "$REPOSITORY_ROOT/install-control-plane.sh" | cut -d: -f1 || true)"
worker_vrack_attach_line="$(grep -n '"\$OVH_VRACK_CONFIGURATOR" --attach-server' "$REPOSITORY_ROOT/scripts/add-k3s-workers.sh" | cut -d: -f1 || true)"
worker_vrack_network_line="$(grep -n 'Configuring \$worker_ip on the OVHcloud private NIC before UFW changes' "$REPOSITORY_ROOT/scripts/add-k3s-workers.sh" | cut -d: -f1 || true)"
ansible_tailscale_line="$(grep -n 'Reconcile Tailscale before host firewall changes' "$REPOSITORY_ROOT/ansible/deploy.yml" | cut -d: -f1 || true)"
ansible_vrack_line="$(grep -n 'Reconcile the OVHcloud vRack host interface before firewall changes' "$REPOSITORY_ROOT/ansible/deploy.yml" | cut -d: -f1 || true)"
ansible_k3s_network_line="$(grep -n 'Reconcile K3s private networking before host firewall changes' "$REPOSITORY_ROOT/ansible/deploy.yml" | cut -d: -f1 || true)"
ansible_firewall_line="$(grep -n 'Apply role-aware control-plane host security policy' "$REPOSITORY_ROOT/ansible/deploy.yml" | cut -d: -f1 || true)"
if [[ -n "$tailscale_firewall_line" && -n "$private_ssh_line" && -n "$ufw_apply_line" && -n "$tailscale_handoff_line" &&
      -n "$tailscale_worker_setup_line" && -n "$vrack_worker_setup_line" && -n "$worker_firewall_line" &&
      -n "$control_tailscale_setup_line" && -n "$control_vrack_attach_line" && -n "$control_vrack_setup_line" &&
      -n "$control_firewall_line" && -n "$worker_vrack_attach_line" && -n "$worker_vrack_network_line" &&
      -n "$ansible_tailscale_line" && -n "$ansible_vrack_line" && -n "$ansible_k3s_network_line" && -n "$ansible_firewall_line" ]] &&
   (( tailscale_firewall_line < private_ssh_line && private_ssh_line < ufw_apply_line && ufw_apply_line < tailscale_handoff_line &&
      tailscale_worker_setup_line < worker_firewall_line && vrack_worker_setup_line < worker_firewall_line &&
      control_tailscale_setup_line < control_firewall_line &&
      control_vrack_attach_line < control_vrack_setup_line && control_vrack_setup_line < control_firewall_line &&
      worker_vrack_attach_line < worker_vrack_network_line &&
      ansible_tailscale_line < ansible_k3s_network_line && ansible_vrack_line < ansible_k3s_network_line &&
      ansible_k3s_network_line < ansible_firewall_line )); then
    pass "private transport setup and SSH preflight precede worker UFW enforcement"
else
    fail "private transport setup and SSH preflight precede worker UFW enforcement"
fi

info "Checking shared platform contract"
contract_failed=false
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* || "$line" =~ ^[A-Z][A-Z0-9_]*=[^[:space:]]*$ ]] || {
        printf 'Invalid contract line: %s\n' "$line" >&2
        contract_failed=true
    }
done < "$PLATFORM_CONFIG"
if [[ "$contract_failed" == "true" ]]; then
    fail "platform contract uses source-safe properties"
else
    pass "platform contract uses source-safe properties"
fi

if grep -Fq 'DELETE FROM kine' "$REPOSITORY_ROOT/scripts/backup-k3s.sh" &&
   grep -Fq "SET prev_revision = 0, old_value = X''" "$REPOSITORY_ROOT/scripts/backup-k3s.sh" &&
   grep -Fq 'Never run these statements against the live K3s database' "$REPOSITORY_ROOT/scripts/backup-k3s.sh"; then
    pass "K3s recovery archives exclude deleted SQLite free-page data"
else
    fail "K3s recovery archives exclude deleted SQLite free-page data"
fi

if [[ -z "${DEFAULT_PLATFORM_DOMAIN:-}" ]] &&
   [[ -z "${DEFAULT_INTERNAL_DNS_ZONE:-}" ]] &&
   [[ -z "${DEFAULT_K3S_REGISTRY_HOST:-}" ]] &&
   [[ "${DEFAULT_K3S_REGISTRY_ENDPOINT:-}" == "http://10.43.255.251:5050" ]] &&
   grep -Fq 'name suffix .__INTERNAL_DNS_ZONE__. .infra.svc.cluster.local. answer auto' \
       "$K8S_ROOT/base/coredns-custom.yaml" &&
   grep -Fq 'clusterIP: 10.43.255.251' "$K8S_ROOT/platform/gitlab.yaml" &&
   grep -Fq 'clusterIP: 10.43.255.252' "$K8S_ROOT/platform/gitlab.yaml" &&
   grep -Fq 'PLATFORM_DOMAIN:+gitlab.$PLATFORM_DOMAIN' \
       "$REPOSITORY_ROOT/scripts/configure-k3s-registry-mirror.sh" &&
   grep -Fq 'prompt_cluster_identity' "$REPOSITORY_ROOT/install-control-plane.sh" &&
   grep -Fq '__PUBLIC_DOMAIN__' "$K8S_ROOT/platform/ingress.yaml" &&
   grep -Fq '__INTERNAL_DNS_ZONE__' "$K8S_ROOT/base/coredns-custom.yaml" &&
   [[ -x "$REPOSITORY_ROOT/scripts/configure-k3s-registry-mirror.sh" ]]; then
    pass "cluster identity, private DNS, and Registry hosts are installer-defined"
else
    fail "cluster identity, private DNS, and Registry hosts are installer-defined"
fi

legacy_internal_references="$({
    grep -RIl --exclude='coredns-custom.yaml' --exclude='configure-k3s-registry-mirror.sh' \
        --exclude='validate-repository.sh' --exclude='.gitlab-ci.yml' --exclude-dir=.git \
        --exclude-dir=node_modules --exclude-dir=target \
        'infra\.svc\.cluster\.local' "$REPOSITORY_ROOT" || true
} | LC_ALL=C sort -u)"
if [[ -z "$legacy_internal_references" ]]; then
    pass "runtime references use the selected private alias zone or Kubernetes service DNS"
else
    printf 'Canonical Infra service references remain outside CoreDNS:\n%s\n' \
        "$legacy_internal_references" >&2
    fail "runtime references use the selected private alias zone or Kubernetes service DNS"
fi

legacy_private_dns_label=local
legacy_private_zone="swirlit.${legacy_private_dns_label}"
legacy_private_zone_references="$({
    grep -RIl -F --exclude='validate-repository.sh' --exclude-dir=.git \
        --exclude-dir=node_modules --exclude-dir=target \
        "$legacy_private_zone" "$REPOSITORY_ROOT" || true
} | LC_ALL=C sort -u)"
if [[ -z "$legacy_private_zone_references" ]]; then
    pass "legacy private DNS zone references are absent"
else
    printf 'Legacy private DNS zone references remain:\n%s\n' \
        "$legacy_private_zone_references" >&2
    fail "legacy private DNS zone references are absent"
fi

manifest_inventory_failed=false
for manifest_csv in "$FOUNDATION_MANIFESTS" "$DATASTORE_MANIFESTS" "$PLATFORM_MANIFESTS" "$POST_DEPLOY_CREATE_MANIFESTS" "$POST_ARGOCD_MANIFESTS"; do
    IFS=',' read -r -a manifests <<< "$manifest_csv"
    for manifest in "${manifests[@]}"; do
        if [[ ! -f "$K8S_ROOT/$manifest" ]]; then
            printf 'Contract references missing manifest: %s\n' "$manifest" >&2
            manifest_inventory_failed=true
        fi
    done
done
for inventory in FOUNDATION_MANIFESTS DATASTORE_MANIFESTS PLATFORM_MANIFESTS POST_DEPLOY_CREATE_MANIFESTS POST_ARGOCD_MANIFESTS EXTERNAL_SECRET_NAMES DATASTORE_WAIT_APPS PLATFORM_WAIT_APPS PLATFORM_WAIT_DAEMONSETS DEFAULT_CLOUDFLARE_HOST_LABELS DEFAULT_CLOUDFLARE_ACCESS_HOST_LABELS DEFAULT_CLOUDFLARE_NON_BROWSER_HOST_LABELS DEFAULT_CLOUDFLARE_EXTERNAL_INGRESS_HOST_LABELS; do
    value="${!inventory}"
    if [[ "$(tr ',' '\n' <<< "$value" | sed '/^$/d' | wc -l)" -ne "$(tr ',' '\n' <<< "$value" | sed '/^$/d' | sort -u | wc -l)" ]]; then
        printf 'Contract list contains duplicates: %s\n' "$inventory" >&2
        manifest_inventory_failed=true
    fi
done
if [[ "$manifest_inventory_failed" == "true" ]]; then
    fail "contract inventories are complete and unique"
else
    pass "contract inventories are complete and unique"
fi

if [[ "${DEFAULT_TAILSCALE_MESH_NAME:-}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] &&
   [[ ${#DEFAULT_TAILSCALE_MESH_NAME} -le 32 ]] &&
   [[ "${DEFAULT_TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-}" =~ ^[0-9]+$ ]] &&
   (( DEFAULT_TAILSCALE_AUTH_KEY_EXPIRY_SECONDS >= 60 && DEFAULT_TAILSCALE_AUTH_KEY_EXPIRY_SECONDS <= 7776000 )) &&
   [[ -x "$REPOSITORY_ROOT/scripts/configure-tailscale-fleet.sh" ]] &&
   ! grep -Eq '^DEFAULT_TAILSCALE_(CONTROL_PLANE|WORKER)_TAG=' "$PLATFORM_CONFIG"; then
    pass "Tailscale contract is mesh-scoped and provider-neutral"
else
    fail "Tailscale contract is mesh-scoped and provider-neutral"
fi

if [[ -x "$REPOSITORY_ROOT/scripts/configure-ovh-vrack.sh" ]] &&
   grep -Fq 'OVHcloud-only' "$REPOSITORY_ROOT/scripts/configure-ovh-vrack.sh" &&
   grep -Fq 'hybrid cloud or non-OVHcloud providers' \
       "$REPOSITORY_ROOT/scripts/lib/installer-prompts.sh"; then
    pass "private transport choices are explicitly provider-scoped"
else
    fail "private transport choices are explicitly provider-scoped"
fi

if [[ -r "$REPOSITORY_ROOT/scripts/lib/transport-guide.sh" ]] &&
   grep -Fq 'transport_guide_tailscale_account' "$REPOSITORY_ROOT/install-control-plane.sh" &&
   grep -Fq 'transport_guide_vrack_account' "$REPOSITORY_ROOT/install-control-plane.sh" &&
   grep -Fq 'transport_guide_tailscale_account' "$REPOSITORY_ROOT/scripts/add-k3s-workers.sh" &&
   grep -Fq 'transport_guide_vrack_account' "$REPOSITORY_ROOT/scripts/add-k3s-workers.sh" &&
   grep -Fq 'transport_guide_tailscale_account' "$REPOSITORY_ROOT/scripts/install-k3s-worker.sh" &&
   grep -Fq 'transport_guide_vrack_account' "$REPOSITORY_ROOT/scripts/install-k3s-worker.sh" &&
   grep -Fq '"$NETWORK_LIBRARY" "$TRANSPORT_GUIDE_LIBRARY"' "$REPOSITORY_ROOT/scripts/add-k3s-workers.sh" &&
   grep -Fq -- '--verify-account' "$REPOSITORY_ROOT/scripts/configure-tailscale.sh" &&
   grep -Fq -- '--verify-account' "$REPOSITORY_ROOT/scripts/configure-ovh-vrack.sh"; then
    pass "installers share guided, read-only transport prerequisite verification"
else
    fail "installers share guided, read-only transport prerequisite verification"
fi

if grep -Eq 'CHART_VERSION="\$\{[^}]+:-[0-9]|K3S_INSTALL_VERSION="\$\{[^}]+:-v[0-9]' "$REPOSITORY_ROOT/install-control-plane.sh" ||
   grep -Eq '^\s+[a-z_]+_(chart_version|image_tag):\s+"?[v0-9]' "$REPOSITORY_ROOT/ansible/deploy.yml"; then
    fail "installers do not embed release defaults outside the contract"
else
    pass "installers do not embed release defaults outside the contract"
fi

info "Checking public service inventories"
csv_to_file "$DEFAULT_CLOUDFLARE_HOST_LABELS" "$TEMP_DIR/public-hosts"
csv_to_file "$DEFAULT_CLOUDFLARE_ACCESS_HOST_LABELS" "$TEMP_DIR/access-hosts"
csv_to_file "$DEFAULT_CLOUDFLARE_NON_BROWSER_HOST_LABELS" "$TEMP_DIR/non-browser-hosts"
csv_to_file "$DEFAULT_CLOUDFLARE_EXTERNAL_INGRESS_HOST_LABELS" "$TEMP_DIR/external-ingress-hosts"

if [[ -s "$TEMP_DIR/access-hosts" ]] && [[ -n "$(comm -23 "$TEMP_DIR/access-hosts" "$TEMP_DIR/public-hosts")" ]]; then
    fail "Cloudflare Access hosts are a subset of published hosts"
else
    pass "Cloudflare Access hosts are a subset of published hosts"
fi

if [[ -s "$TEMP_DIR/non-browser-hosts" ]] && [[ -n "$(comm -23 "$TEMP_DIR/non-browser-hosts" "$TEMP_DIR/public-hosts")" ]]; then
    fail "non-browser hosts are a subset of published hosts"
else
    pass "non-browser hosts are a subset of published hosts"
fi

if [[ -s "$TEMP_DIR/external-ingress-hosts" ]] && [[ -n "$(comm -23 "$TEMP_DIR/external-ingress-hosts" "$TEMP_DIR/public-hosts")" ]]; then
    fail "application-owned Ingress hosts are a subset of published hosts"
else
    pass "application-owned Ingress hosts are a subset of published hosts"
fi

if grep -Fq 'configure_registry_bot_compatibility' "$REPOSITORY_ROOT/scripts/configure-cloudflare.sh" &&
   grep -Fq 'Zone    -> Bot Management           -> Read' "$REPOSITORY_ROOT/scripts/configure-cloudflare.sh" &&
   grep -Fq 'action_parameters:{phases:["http_request_sbfm"]}' "$REPOSITORY_ROOT/scripts/configure-cloudflare.sh"; then
    pass "Cloudflare reconciliation preserves non-browser Registry API access"
else
    fail "Cloudflare reconciliation preserves non-browser Registry API access"
fi

if grep -Fq 'older_than:"1095d"' "$REPOSITORY_ROOT/scripts/configure-gitlab-ci.sh" &&
   grep -Fq 'value: "1095"' "$K8S_ROOT/platform/gitlab-registry-retention.yaml" &&
   grep -Fq 'property: retention_api_token' "$K8S_ROOT/platform/gitlab-registry-retention.yaml" &&
   grep -Fq 'platform/gitlab-registry-retention.yaml' "$REPOSITORY_ROOT/config/platform.env"; then
    pass "GitLab package and container registries declare three-year retention"
else
    fail "GitLab package and container registries declare three-year retention"
fi

if grep -Fq 'OnCalendar=*-*-15 03:00:00' "$REPOSITORY_ROOT/scripts/configure-lynis-schedule.sh" &&
   grep -Fq -- '-mtime +365 -delete' "$REPOSITORY_ROOT/scripts/configure-lynis-schedule.sh" &&
   grep -Fq 'paths:' "$K8S_ROOT/platform/logging-agent.yaml" &&
   grep -Fq '/hostfs/var/log/lynis-report.dat' "$K8S_ROOT/platform/logging-agent.yaml" &&
   grep -Fq 'index => "lynis-audits-%{+yyyy.MM}"' "$K8S_ROOT/platform/elk.yaml" &&
   grep -Fq '"min_age": "365d"' "$K8S_ROOT/platform/elk.yaml" &&
   grep -Fq 'id":"lynis-security-audits"' "$K8S_ROOT/platform/observability-discovery.yaml"; then
    pass "monthly Lynis audits are indexed, retained for twelve months, and shown in Kibana"
else
    fail "monthly Lynis audits are indexed, retained for twelve months, and shown in Kibana"
fi

if grep -Fq 'GITLAB_CANONICAL_ADMIN_USERNAME' "$K8S_ROOT/platform/gitlab.yaml" &&
   grep -Fq 'identity.user = canonical_user' "$K8S_ROOT/platform/gitlab.yaml" &&
   grep -Fq 'Users::DestroyService.new(canonical_user)' "$K8S_ROOT/platform/gitlab.yaml" &&
   grep -Fq 'value: root' "$K8S_ROOT/platform/gitlab.yaml"; then
    pass "GitLab Keycloak sign-in reconciles to the canonical root administrator"
else
    fail "GitLab Keycloak sign-in reconciles to the canonical root administrator"
fi

if grep -Fq 'name: portainer-cluster-admin' "$K8S_ROOT/platform/portainer.yaml" &&
   grep -Fq 'name: cluster-admin' "$K8S_ROOT/platform/portainer.yaml" &&
   ! grep -Fq 'portainer-read-only' "$K8S_ROOT/platform/portainer.yaml"; then
    pass "Portainer administrators receive unrestricted Kubernetes cluster access"
else
    fail "Portainer administrators receive unrestricted Kubernetes cluster access"
fi

if grep -Fq 'roles/realm-admin' "$K8S_ROOT/platform/keycloak-sso.yaml" &&
   grep -Fq "'GrafanaAdmin'" "$K8S_ROOT/platform/monitoring.yaml" &&
   grep -Fq 'g, platform-admins, role:admin' "$REPOSITORY_ROOT/config/argocd-values.yaml" &&
   grep -Fq 'capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]' "$REPOSITORY_ROOT/scripts/configure-vault.sh" &&
   grep -Fq 'permission=admin' "$K8S_ROOT/platform/sonarqube.yaml" &&
   grep -Fq "put_user admin \"\$ADMIN_PASSWORD\" '[\"superuser\"]'" "$K8S_ROOT/platform/elk.yaml" &&
   grep -Fq '"Role": 1' "$K8S_ROOT/platform/portainer-bootstrap-job.yaml" &&
   grep -Fq 'value: "false"' "$K8S_ROOT/platform/kafka-ui.yaml" &&
   grep -Fq "self.env.ref('base.user_admin')" "$K8S_ROOT/apps/odoo.yaml"; then
    pass "the shared Keycloak administrator maps to every product's maximum supported role"
else
    fail "the shared Keycloak administrator maps to every product's maximum supported role"
fi

sed -nE 's#.*href:[[:space:]]+https://([^/[:space:]]+).*#\1#p' "$K8S_ROOT/platform/homepage.yaml" |
    awk 'index($0, ".__PUBLIC_DOMAIN__") == length($0) - length(".__PUBLIC_DOMAIN__") + 1 {sub("\\.__PUBLIC_DOMAIN__$", ""); print}' |
    LC_ALL=C sort -u > "$TEMP_DIR/homepage-hosts"
comm -23 "$TEMP_DIR/public-hosts" "$TEMP_DIR/non-browser-hosts" > "$TEMP_DIR/dashboard-hosts"
comm -23 "$TEMP_DIR/dashboard-hosts" "$TEMP_DIR/external-ingress-hosts" > "$TEMP_DIR/central-dashboard-hosts"
compare_sets "$TEMP_DIR/central-dashboard-hosts" "$TEMP_DIR/homepage-hosts" "Homepage contains every centrally owned browser-facing cluster hostname"

sed -nE 's/^[[:space:]]*-[[:space:]]*host:[[:space:]]*([^[:space:]]+).*/\1/p' "${kubernetes_manifests[@]}" |
    awk '$0 != "__PUBLIC_DOMAIN__" && index($0, ".__PUBLIC_DOMAIN__") == length($0) - length(".__PUBLIC_DOMAIN__") + 1 {sub("\\.__PUBLIC_DOMAIN__$", ""); print}' |
    LC_ALL=C sort -u > "$TEMP_DIR/ingress-hosts"
comm -23 "$TEMP_DIR/public-hosts" "$TEMP_DIR/external-ingress-hosts" > "$TEMP_DIR/central-ingress-hosts"
compare_sets "$TEMP_DIR/central-ingress-hosts" "$TEMP_DIR/ingress-hosts" "centrally owned public hosts have matching Ingress resources"

info "Checking Kubernetes workload policy"
image_failed=false
while read -r location image; do
    if [[ ! "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
        printf 'Unpinned workload image at %s: %s\n' "$location" "$image" >&2
        image_failed=true
    fi
done < <(awk '$1 == "image:" {print FILENAME ":" FNR, $2}' "${kubernetes_manifests[@]}")
if [[ "$image_failed" == "true" ]]; then
    fail "every manifest image is immutable by digest"
else
    pass "every manifest image is immutable by digest"
fi

if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    yaml_failed=false
    while IFS= read -r yaml_file; do
        python3 -c 'import sys, yaml; list(yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")))' "$yaml_file" || yaml_failed=true
    done < <(
        find "$REPOSITORY_ROOT" -path "$REPOSITORY_ROOT/.git" -prune -o -type f \
            \( -name '*.yaml' -o -name '*.yml' \) ! -path "$K8S_ROOT/templates/*" -print | LC_ALL=C sort
    )
    if [[ "$yaml_failed" == "true" ]]; then
        fail "all repository YAML documents parse"
    else
        pass "all repository YAML documents parse"
    fi

    if python3 - "$K8S_ROOT" > "$TEMP_DIR/workload-policy" <<'PY'
from pathlib import Path
import sys

import yaml

k8s_root = Path(sys.argv[1])
workload_kinds = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}
failures = []

for manifest in sorted(k8s_root.rglob("*.yaml")):
    if "templates" in manifest.relative_to(k8s_root).parts:
        continue
    for document_index, resource in enumerate(yaml.safe_load_all(manifest.read_text(encoding="utf-8")), 1):
        if not isinstance(resource, dict) or resource.get("kind") not in workload_kinds:
            continue

        kind = resource["kind"]
        metadata = resource.get("metadata") or {}
        name = metadata.get("name", f"document-{document_index}")
        identity = f"{manifest.relative_to(k8s_root)}:{kind}/{name}"
        spec = resource.get("spec") or {}
        if kind == "CronJob":
            pod_spec = (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
        else:
            pod_spec = ((spec.get("template") or {}).get("spec") or {})

        automount = pod_spec.get("automountServiceAccountToken")
        if not isinstance(automount, bool):
            failures.append(f"{identity}: automountServiceAccountToken must be an explicit boolean")

        for container_type in ("initContainers", "containers"):
            for container in pod_spec.get(container_type) or []:
                container_name = container.get("name", "<unnamed>")
                resources = container.get("resources") or {}
                for budget_type in ("requests", "limits"):
                    budget = resources.get(budget_type) or {}
                    missing = [resource_name for resource_name in ("cpu", "memory") if not budget.get(resource_name)]
                    if missing:
                        failures.append(
                            f"{identity}:{container_type}/{container_name}: "
                            f"missing {budget_type} for {', '.join(missing)}"
                        )

if failures:
    print("\n".join(failures))
    raise SystemExit(1)
PY
    then
        pass "workloads declare service-account token intent and resource budgets"
    else
        cat "$TEMP_DIR/workload-policy" >&2
        fail "workloads declare service-account token intent and resource budgets"
    fi
else
    info "PyYAML is unavailable; YAML parsing is covered by Ansible and optional live validation"
fi

workflow_action_failed=false
while IFS= read -r action; do
    if [[ "$action" == ./* || "$action" =~ ^docker://.+@sha256:[0-9a-f]{64}$ || "$action" =~ @[0-9a-f]{40}$ ]]; then
        continue
    fi
    printf 'Unpinned GitHub Action reference: %s\n' "$action" >&2
    workflow_action_failed=true
done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^[:space:]#]+).*/\1/p' "$REPOSITORY_ROOT"/.github/workflows/*.{yaml,yml} 2>/dev/null || true)
if [[ "$workflow_action_failed" == "true" ]]; then
    fail "third-party GitHub Actions are pinned immutably"
else
    pass "third-party GitHub Actions are pinned immutably"
fi

if command -v ansible-playbook >/dev/null 2>&1; then
    if ansible-playbook -i "$REPOSITORY_ROOT/ansible/inventory" \
        --syntax-check "$REPOSITORY_ROOT/ansible/deploy.yml" >/dev/null; then
        pass "Ansible playbook syntax"
    else
        fail "Ansible playbook syntax"
    fi
else
    info "ansible-playbook is unavailable; skipping Ansible syntax validation"
fi

if [[ "$LIVE_VALIDATION" == "true" ]]; then
    info "Checking manifests with Kubernetes server-side dry-run"
    if ! command -v kubectl >/dev/null 2>&1 || ! kubectl cluster-info >/dev/null 2>&1; then
        fail "active Kubernetes API is reachable for --live"
    else
        live_failed=false
        live_render_root="$TEMP_DIR/rendered"
        PLATFORM_DOMAIN=example.com \
        INTERNAL_DNS_ZONE=internal.example.com \
        GITOPS_REPOSITORY_URL=https://github.com/example/bm-cluster.git \
            "$REPOSITORY_ROOT/scripts/render-cluster-config.sh" \
                --output "$live_render_root" \
                --domain example.com \
                --internal-domain internal.example.com \
                --gitops-repository https://github.com/example/bm-cluster.git \
                --gitlab-group example \
                --gitlab-project bm-cluster \
                --cloudflare-access-team example-team \
                --apps-enabled true \
                --descheduler-enabled true >/dev/null
        while IFS= read -r source_manifest; do
            manifest="$live_render_root/k8s/${source_manifest#"$K8S_ROOT/"}"
            if grep -Eq '^[[:space:]]+generateName:' "$manifest"; then
                kubectl create --dry-run=server -f "$manifest" >/dev/null || live_failed=true
            else
                kubectl apply --dry-run=server -f "$manifest" >/dev/null || live_failed=true
            fi
        done < <(printf '%s\n' "${kubernetes_manifests[@]}")
        if [[ "$live_failed" == "true" ]]; then
            fail "all manifests pass Kubernetes server-side dry-run"
        else
            pass "all manifests pass Kubernetes server-side dry-run"
        fi
    fi
fi

if git -C "$REPOSITORY_ROOT" diff --check >/dev/null; then
    pass "Git patch whitespace"
else
    fail "Git patch whitespace"
fi

if grep -RIE '((cfat|cfut)_[[:alnum:]]{20,}|tskey-(api|auth)-[[:alnum:]_-]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)' \
    --exclude-dir=.git "$REPOSITORY_ROOT" >/dev/null; then
    fail "repository contains no recognizable tokens or private keys"
else
    pass "repository contains no recognizable tokens or private keys"
fi

printf '\nValidated %d checks with %d failure(s).\n' "$CHECKS" "$FAILURES"
(( FAILURES == 0 ))
