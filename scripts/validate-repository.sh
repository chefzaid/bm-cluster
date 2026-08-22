#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_CONFIG="$REPOSITORY_ROOT/config/platform.env"
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
    if shellcheck --rcfile "$REPOSITORY_ROOT/.shellcheckrc" -x "${shell_scripts[@]}"; then
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
    [[ -z "$line" || "$line" == \#* || "$line" =~ ^[A-Z][A-Z0-9_]*=[^[:space:]]+$ ]] || {
        printf 'Invalid contract line: %s\n' "$line" >&2
        contract_failed=true
    }
done < "$PLATFORM_CONFIG"
if [[ "$contract_failed" == "true" ]]; then
    fail "platform contract uses source-safe properties"
else
    pass "platform contract uses source-safe properties"
fi

manifest_inventory_failed=false
for manifest_csv in "$DATASTORE_MANIFESTS" "$PLATFORM_MANIFESTS" "$POST_DEPLOY_CREATE_MANIFESTS"; do
    IFS=',' read -r -a manifests <<< "$manifest_csv"
    for manifest in "${manifests[@]}"; do
        if [[ ! -f "$REPOSITORY_ROOT/deployments/$manifest" ]]; then
            printf 'Contract references missing manifest: %s\n' "$manifest" >&2
            manifest_inventory_failed=true
        fi
    done
done
for inventory in DATASTORE_MANIFESTS PLATFORM_MANIFESTS POST_DEPLOY_CREATE_MANIFESTS EXTERNAL_SECRET_NAMES DATASTORE_WAIT_APPS PLATFORM_WAIT_APPS PLATFORM_WAIT_DAEMONSETS DEFAULT_CLOUDFLARE_HOST_LABELS DEFAULT_CLOUDFLARE_ACCESS_HOST_LABELS; do
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
   grep -Fq 'hybrid cloud or non-OVHcloud providers' "$REPOSITORY_ROOT/install-control-plane.sh"; then
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
csv_to_file "$EXTERNALLY_MANAGED_HOST_LABELS" "$TEMP_DIR/external-hosts"

if [[ -s "$TEMP_DIR/access-hosts" ]] && [[ -n "$(comm -23 "$TEMP_DIR/access-hosts" "$TEMP_DIR/public-hosts")" ]]; then
    fail "Cloudflare Access hosts are a subset of published hosts"
else
    pass "Cloudflare Access hosts are a subset of published hosts"
fi

sed -nE 's#.*href:[[:space:]]+https://([^/[:space:]]+).*#\1#p' "$REPOSITORY_ROOT/deployments/homepage.yaml" |
    awk -v zone="$DEFAULT_CLOUDFLARE_ZONE" 'index($0, "." zone) == length($0) - length(zone) {sub("\\." zone "$", ""); print}' |
    LC_ALL=C sort -u > "$TEMP_DIR/homepage-hosts"
compare_sets "$TEMP_DIR/public-hosts" "$TEMP_DIR/homepage-hosts" "Homepage contains every published cluster hostname"

comm -23 "$TEMP_DIR/public-hosts" "$TEMP_DIR/external-hosts" > "$TEMP_DIR/local-public-hosts"
sed -nE 's/^[[:space:]]*-[[:space:]]*host:[[:space:]]*([^[:space:]]+).*/\1/p' "$REPOSITORY_ROOT"/deployments/*.yaml |
    awk -v zone="$DEFAULT_CLOUDFLARE_ZONE" '$0 != zone && index($0, "." zone) == length($0) - length(zone) {sub("\\." zone "$", ""); print}' |
    LC_ALL=C sort -u > "$TEMP_DIR/ingress-hosts"
compare_sets "$TEMP_DIR/local-public-hosts" "$TEMP_DIR/ingress-hosts" "repository-owned public hosts have matching Ingress resources"

info "Checking Kubernetes workload policy"
image_failed=false
while read -r location image; do
    if [[ ! "$image" =~ @sha256:[0-9a-f]{64}$ ]]; then
        printf 'Unpinned workload image at %s: %s\n' "$location" "$image" >&2
        image_failed=true
    fi
done < <(awk '$1 == "image:" {print FILENAME ":" FNR, $2}' "$REPOSITORY_ROOT"/deployments/*.yaml)
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
            \( -name '*.yaml' -o -name '*.yml' \) -print | LC_ALL=C sort
    )
    if [[ "$yaml_failed" == "true" ]]; then
        fail "all repository YAML documents parse"
    else
        pass "all repository YAML documents parse"
    fi

    if python3 - "$REPOSITORY_ROOT/deployments" > "$TEMP_DIR/workload-policy" <<'PY'
from pathlib import Path
import sys

import yaml

deployments = Path(sys.argv[1])
workload_kinds = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}
failures = []

for manifest in sorted(deployments.glob("*.yaml")):
    for document_index, resource in enumerate(yaml.safe_load_all(manifest.read_text(encoding="utf-8")), 1):
        if not isinstance(resource, dict) or resource.get("kind") not in workload_kinds:
            continue

        kind = resource["kind"]
        metadata = resource.get("metadata") or {}
        name = metadata.get("name", f"document-{document_index}")
        identity = f"{manifest.name}:{kind}/{name}"
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
        while IFS= read -r manifest; do
            if grep -Eq '^[[:space:]]+generateName:' "$manifest"; then
                kubectl create --dry-run=server -f "$manifest" >/dev/null || live_failed=true
            else
                kubectl apply --dry-run=server -f "$manifest" >/dev/null || live_failed=true
            fi
        done < <(find "$REPOSITORY_ROOT/deployments" -maxdepth 1 -type f -name '*.yaml' -print | LC_ALL=C sort)
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
