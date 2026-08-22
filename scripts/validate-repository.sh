#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_CONFIG="$REPOSITORY_ROOT/config/platform.env"
LIVE_VALIDATION=false
FAILURES=0
CHECKS=0
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

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
while IFS= read -r script; do
    if ! bash -n "$script"; then
        shell_failed=true
    fi
done < <(find "$REPOSITORY_ROOT" -path "$REPOSITORY_ROOT/.git" -prune -o -type f -name '*.sh' -print | LC_ALL=C sort)
if [[ "$shell_failed" == "true" ]]; then
    fail "all shell scripts parse"
else
    pass "all shell scripts parse"
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
    while IFS= read -r manifest; do
        python3 -c 'import sys, yaml; list(yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")))' "$manifest" || yaml_failed=true
    done < <(find "$REPOSITORY_ROOT/deployments" -maxdepth 1 -type f -name '*.yaml' -print | LC_ALL=C sort)
    if [[ "$yaml_failed" == "true" ]]; then
        fail "all Kubernetes manifests are valid YAML"
    else
        pass "all Kubernetes manifests are valid YAML"
    fi
else
    info "PyYAML is unavailable; YAML parsing is covered by Ansible and optional live validation"
fi

if command -v ansible-playbook >/dev/null 2>&1; then
    if ansible-playbook --syntax-check "$REPOSITORY_ROOT/ansible/deploy.yml" >/dev/null; then
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
