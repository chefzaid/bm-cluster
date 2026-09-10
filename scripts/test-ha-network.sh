#!/usr/bin/env bash
# Exercise HA network behavior with mocked host commands and Tailscale API calls.
# Functions and fixture variables are consumed by the dynamically loaded code.
# ShellCheck 0.10 reports indirect mock calls as SC2317; 0.11 uses SC2329.
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d /tmp/bm-cluster-ha-network-test.XXXXXX)"
trap 'rm -r -- "$TEST_DIR"' EXIT
# shellcheck source=lib/network.sh
source "$SCRIPT_DIR/lib/network.sh"

load_function() {
    local source_file="$1" function_name="$2"
    # Load only the named function, never the scripts' host-mutating entrypoints.
    eval "$(awk -v name="$function_name" '$0 == name "() {" {active=1} active {print} active && /^}$/ {exit}' "$source_file")"
    declare -F "$function_name" >/dev/null
}

info() { :; }
warn() { :; }
error() { printf '%s\n' "$*" >&2; exit 1; }
err() { error "$@"; }

# Verify policy migration, role isolation, unrelated grants, and idempotency.
(
    TEMP_DIR="$TEST_DIR"
    CONTROL_PLANE_TAG=tag:test-control-plane
    WORKER_TAG=tag:test-worker
    TAILNET='test'
    MESH_NAME='test'
    CURL_CONFIG=mock
    API_BASE=https://unused.invalid
    printf '%s\n' '{"grants":[{"src":["tag:unrelated"],"dst":["tag:other"],"ip":["tcp:443"]}]}' > "$TEST_DIR/current.json"
    api_request() {
        if [[ "$1" == GET ]]; then
            cp "$TEST_DIR/current.json" "$3"
            printf 'ETag: "test"\r\n' > "$4"
        fi
    }
    curl() {
        local payload=""
        while [[ $# -gt 0 ]]; do
            if [[ "$1" == --data-binary ]]; then shift; payload="${1#@}"; fi
            shift
        done
        [[ -n "$payload" ]] || return 1
        cp "$payload" "$TEST_DIR/current.json"
        printf 'POST\n' >> "$TEST_DIR/requests"
        printf '200'
    }
    load_function "$SCRIPT_DIR/configure-tailscale.sh" reconcile_policy
    reconcile_policy
    jq -e '
      [.grants[] | select(.src == ["tag:test-control-plane"] and .dst == ["tag:test-control-plane"])] as $cp |
      ($cp | length) == 1 and
      (["tcp:22","tcp:6443","tcp:2379-2380","udp:8472","tcp:10250"] - $cp[0].ip | length) == 0 and
      ([.grants[] | select(.src == ["tag:test-worker"]) | .ip[] | select(test("2379|2380"))] | length) == 0 and
      any(.grants[]; .src == ["tag:unrelated"] and .ip == ["tcp:443"])
    ' "$TEST_DIR/current.json" >/dev/null
    reconcile_policy
    [[ "$(wc -l < "$TEST_DIR/requests")" -eq 1 ]]
)

# Verify API/etcd isolation, secondary CP private ingress, and SSH proof.
(
    for function_name in private_node_policy configure_ufw validate_worker_private_ssh_before_firewall allow_control_plane_ssh; do
        load_function "$SCRIPT_DIR/configure-node-security.sh" "$function_name"
    done
    ensure_packages() { :; }
    configure_worker_forwarding_guard() { :; }
    detect_control_plane_cluster_interface() { printf 'eno2\n'; }
    tailscale_transport_selected() { return 1; }
    interface_owning_ip() { printf 'eno2\n'; }
    ip() {
        case "$*" in
            '-4 route get 10.40.0.1') printf '10.40.0.1 dev eno2 src 10.40.0.2\n' ;;
            '-4 route show default') printf 'default via 203.0.113.1 dev eno1\n' ;;
            '-4 -o address show scope global') printf '2: eno1 inet 203.0.113.2/24\n3: eno2 inet 10.40.0.2/24\n' ;;
            '-6 -o address show scope global') : ;;
            *) return 1 ;;
        esac
    }
    sudo() { printf '%s\n' "$*" >> "$TEST_DIR/ufw"; }
    NODE_ROLE=control-plane
    PRIVATE_CONTROL_PLANE=false
    SERVER_EXPOSURE=local
    CONTROL_PLANE_IP=10.40.0.1
    CONTROL_PLANE_SSH_IPS=10.40.0.1
    K3S_NODE_NETWORK_CIDR=10.40.0.0/24
    HARDENED_SSH_PORT=22
    CLOUDFLARE_PROXY_ONLY=false
    configure_ufw
    grep -Fxq 'ufw allow in on eno2 from 10.40.0.0/24 to any port 2379:2380 proto tcp comment K3s embedded etcd peers' "$TEST_DIR/ufw"
    : > "$TEST_DIR/ufw"
    PRIVATE_CONTROL_PLANE=true
    configure_ufw
    grep -Fxq 'ufw allow in on eno2 from 10.40.0.0/24 to any port 6443 proto tcp' "$TEST_DIR/ufw"
    grep -Fxq 'ufw allow in on eno2 from 10.40.0.1 to any port 22 proto tcp comment BM control-plane SSH' "$TEST_DIR/ufw"
    if grep -Eq '^ufw allow (22|80|443)/tcp$' "$TEST_DIR/ufw"; then
        error 'Private control plane opened public ingress'
    fi
    grep -Fq 'ufw route deny in on eno1' "$TEST_DIR/ufw"
    SSH_CONNECTION='10.40.0.1 50000 10.40.0.2 22'
    validate_worker_private_ssh_before_firewall
    if (SSH_CONNECTION='203.0.113.1 50000 203.0.113.2 22'; validate_worker_private_ssh_before_firewall) 2>/dev/null; then
        error 'Private control plane accepted public-bootstrap SSH'
    fi
    : > "$TEST_DIR/ufw"
    NODE_ROLE=worker
    PRIVATE_CONTROL_PLANE=false
    configure_ufw
    if grep -Eq 'port (2379|6443)' "$TEST_DIR/ufw"; then
        error 'Worker opened server API/etcd ports'
    fi
    : > "$TEST_DIR/ufw"
    if (K3S_NODE_NETWORK_CIDR=0.0.0.0/0; configure_ufw) 2>/dev/null; then
        error 'Public CIDR accepted by the firewall'
    fi
    if grep -Fq 'ufw --force reset' "$TEST_DIR/ufw"; then
        error 'Firewall reset before rejecting public CIDR'
    fi
)

# A later local reconciliation inherits the enrolled private-server policy,
# including when the caller supplies the installer's default internet mode.
(
    for function_name in inherit_private_control_plane_policy private_node_policy prepare_control_plane_ssh_policy configure_ufw validate_worker_private_ssh_before_firewall allow_control_plane_ssh persist_control_plane_ssh_policy; do
        load_function "$SCRIPT_DIR/configure-node-security.sh" "$function_name"
    done
    PRIVATE_NETWORK_CONFIG="$TEST_DIR/private-network.yaml"
    PRIVATE_NETWORK_CIDR_STATE="$TEST_DIR/private-network-cidr"
    CONTROL_PLANE_SSH_STATE="$TEST_DIR/private-sources"
    cat > "$PRIVATE_NETWORK_CONFIG" <<'EOF'
# Managed by scripts/configure-k3s-control-plane-network.sh
# exposure: private-only
node-ip: "10.40.0.2"
flannel-iface: "eno2"
EOF
    printf '%s\n' 10.40.0.1 10.40.0.2 10.40.0.3 > "$CONTROL_PLANE_SSH_STATE"
    printf '%s\n' 10.40.0.0/24 > "$PRIVATE_NETWORK_CIDR_STATE"
    ensure_packages() { :; }
    configure_worker_forwarding_guard() { :; }
    tailscale_transport_selected() { return 1; }
    interface_owning_ip() { [[ "$1" == 10.40.0.2 ]] && printf 'eno2\n'; }
    ip() {
        case "$*" in
            '-4 route get 10.40.0.1') printf '10.40.0.1 dev eno2 src 10.40.0.2\n' ;;
            '-4 route show default') printf 'default via 203.0.113.1 dev eno1\n' ;;
            '-4 -o address show scope global') printf '2: eno1 inet 203.0.113.2/24\n3: eno2 inet 10.40.0.2/24\n' ;;
            '-6 -o address show scope global') : ;;
            *) return 1 ;;
        esac
    }
    sudo() {
        case "$1" in
            test) [[ "$3" == "$TEST_DIR/"* && -f "$3" ]] ;;
            cat) cat "$2" ;;
            install) cp "${@: -2:1}" "${@: -1}" ;;
            *) printf '%s\n' "$*" >> "$TEST_DIR/inherited-ufw" ;;
        esac
    }
    NODE_ROLE=control-plane
    PRIVATE_CONTROL_PLANE=false
    INHERITED_PRIVATE_CONTROL_PLANE=false
    SERVER_EXPOSURE=internet
    CONTROL_PLANE_IP=''
    CONTROL_PLANE_SSH_IPS=''
    K3S_NODE_NETWORK_CIDR=''
    K3S_PRIVATE_ADDRESS=''
    HARDENED_SSH_PORT=22
    CLOUDFLARE_PROXY_ONLY=false
    SSH_CONNECTION='10.40.0.1 50000 10.40.0.2 22'
    inherit_private_control_plane_policy
    [[ "$PRIVATE_CONTROL_PLANE" == true && "$SERVER_EXPOSURE" == local ]]
    [[ "$K3S_NODE_NETWORK_CIDR" == 10.40.0.0/24 && "$CONTROL_PLANE_IP" == 10.40.0.1 ]]
    prepare_control_plane_ssh_policy
    validate_worker_private_ssh_before_firewall
    configure_ufw
    persist_control_plane_ssh_policy
    grep -Fxq 'ufw allow in on eno2 from 10.40.0.1 to any port 22 proto tcp comment BM control-plane SSH' "$TEST_DIR/inherited-ufw"
    grep -Fq 'ufw route deny in on eno1' "$TEST_DIR/inherited-ufw"
    if grep -Eq '^ufw allow (22|80|443)/tcp$' "$TEST_DIR/inherited-ufw"; then
        error 'Inherited private policy opened public ingress'
    fi
    # Existing policy permits a local console run without weakening new joins.
    SSH_CONNECTION=''
    CONTROL_PLANE_IP=''
    inherit_private_control_plane_policy
    validate_worker_private_ssh_before_firewall
    [[ "$CONTROL_PLANE_IP" == 10.40.0.1 ]]
    : > "$TEST_DIR/inherited-ufw"
    if (SSH_CONNECTION='203.0.113.1 50000 203.0.113.2 22'; inherit_private_control_plane_policy) 2>/dev/null; then
        error 'Inherited policy accepted an untrusted SSH source'
    fi
    if (K3S_PRIVATE_ADDRESS=10.40.0.99; inherit_private_control_plane_policy) 2>/dev/null; then
        error 'Inherited policy accepted a conflicting private address'
    fi
    if (K3S_NODE_NETWORK_CIDR=10.99.0.0/24; inherit_private_control_plane_policy) 2>/dev/null; then
        error 'Inherited policy silently changed its private network'
    fi
    rm "$PRIVATE_NETWORK_CIDR_STATE"
    if (K3S_NODE_NETWORK_CIDR=''; inherit_private_control_plane_policy) 2>/dev/null; then
        error 'Inherited policy accepted an unknown private CIDR'
    fi
    # Hosts enrolled before CIDR persistence retain the explicit validated input.
    K3S_NODE_NETWORK_CIDR=10.40.0.0/24
    inherit_private_control_plane_policy
    persist_control_plane_ssh_policy
    [[ "$(cat "$PRIVATE_NETWORK_CIDR_STATE")" == 10.40.0.0/24 ]]
    rm "$PRIVATE_NETWORK_CONFIG"
    if (PRIVATE_CONTROL_PLANE=false; inherit_private_control_plane_policy) 2>/dev/null; then
        error 'Existing private policy fell back to public mode without its marker'
    fi
    [[ ! -s "$TEST_DIR/inherited-ufw" ]]
)

# Execute the real network configurator, intercepting all privileged writes.
(
    export TEST_CONFIG_FILE="$TEST_DIR/network.yaml"
    ip() {
        case "$*" in
            '-4 route get 1.1.1.1') printf '1.1.1.1 via 203.0.113.1 dev eno1 src 203.0.113.2\n' ;;
            '-4 -o address show dev eno2') printf '3: eno2 inet 10.40.0.2/24 scope global eno2\n' ;;
            *) return 1 ;;
        esac
    }
    sudo() {
        case "$1" in
            test) [[ -f "$TEST_CONFIG_FILE" ]] ;;
            grep) grep -Fxq '# exposure: private-only' "$TEST_CONFIG_FILE" ;;
            cmp) cmp -s "$3" "$TEST_CONFIG_FILE" ;;
            install) cp "${@: -2:1}" "$TEST_CONFIG_FILE" ;;
            *) return 1 ;;
        esac
    }
    export -f ip sudo
    bash "$SCRIPT_DIR/configure-k3s-control-plane-network.sh" --private-ip 10.40.0.2 --private-interface eno2 >/dev/null
    grep -Fxq 'advertise-address: "10.40.0.2"' "$TEST_CONFIG_FILE"
    grep -Fxq 'node-external-ip: "203.0.113.2"' "$TEST_CONFIG_FILE"
    bash "$SCRIPT_DIR/configure-k3s-control-plane-network.sh" --private-ip 10.40.0.2 --private-interface eno2 --private-only >/dev/null
    grep -Fxq '# exposure: private-only' "$TEST_CONFIG_FILE"
    if grep -Fq 'node-external-ip:' "$TEST_CONFIG_FILE"; then
        error 'Private-only control plane advertised a public ExternalIP'
    fi
    bash "$SCRIPT_DIR/configure-k3s-control-plane-network.sh" --private-ip 10.40.0.2 --private-interface eno2 >/dev/null
    if grep -Fq 'node-external-ip:' "$TEST_CONFIG_FILE"; then
        error 'Private-only exposure was lost during later reconciliation'
    fi
    if bash "$SCRIPT_DIR/configure-k3s-control-plane-network.sh" --private-ip 10.40.0.2 --private-interface eno2 \
        --private-only --public-ip 203.0.113.2 >/dev/null 2>&1; then
        error 'Conflicting public and private-only exposure was accepted'
    fi
    if bash "$SCRIPT_DIR/configure-k3s-control-plane-network.sh" --private-ip 10.40.0.3 --private-interface eno2 >/dev/null 2>&1; then
        error 'An IP absent from the selected interface was accepted'
    fi
)

printf '[PASS] HA policy, private API/etcd, secondary control-plane firewall, and address advertisement\n'
