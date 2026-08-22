#!/bin/bash
# Attach OVHcloud Dedicated Servers to vRack and configure a safe private NIC.
set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_LIBRARY="$SCRIPT_DIR/lib/network.sh"
if [[ ! -r "$NETWORK_LIBRARY" ]]; then
    echo "[ERROR] Shared network library not found: $NETWORK_LIBRARY" >&2
    exit 1
fi
# shellcheck source=lib/network.sh
source "$NETWORK_LIBRARY"

MODE=""
OVH_ENDPOINT="${OVH_API_ENDPOINT:-ovh-eu}"
APPLICATION_KEY="${OVH_APPLICATION_KEY:-}"
APPLICATION_SECRET="${OVH_APPLICATION_SECRET:-}"
CONSUMER_KEY="${OVH_CONSUMER_KEY:-}"
VRACK_SERVICE="${OVH_VRACK_SERVICE_NAME:-}"
DEDICATED_SERVER=""
PRIVATE_IP=""
NETWORK_CIDR=""
PRIVATE_INTERFACE=""
PRIVATE_INTERFACE_MAC=""
VLAN_ID=""
NON_INTERACTIVE=false
API_BASE=""
API_RESPONSE=""
TEMP_DIR=""
SUDO=()

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    APPLICATION_KEY=""
    APPLICATION_SECRET=""
    CONSUMER_KEY=""
    unset OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY \
        APPLICATION_KEY APPLICATION_SECRET CONSUMER_KEY 2>/dev/null || true
    if [[ -n "$TEMP_DIR" && "$TEMP_DIR" == /tmp/bm-cluster-vrack.* && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT HUP INT TERM

usage() {
    cat <<'EOF'
Automate OVHcloud-only vRack attachment and host private networking.

Account attachment:
  scripts/configure-ovh-vrack.sh --attach-server SERVER --vrack pn-XXXXXX

Host networking (run on the target server):
  scripts/configure-ovh-vrack.sh --configure-node \
    --private-ip 10.50.0.12 --network-cidr 10.50.0.0/24 \
    --interface eno2 [--interface-mac aa:bb:cc:dd:ee:ff] [--vlan-id 42]

Account options:
  --attach-server NAME     OVHcloud Dedicated Server service name
  --vrack NAME             Existing vRack service name (pn-...)
  --ovh-endpoint NAME      ovh-eu, ovh-ca, or ovh-us

Node options:
  --configure-node         Configure an untagged or VLAN vRack interface
  --private-ip IP          Unique RFC1918 address for this server
  --network-cidr CIDR      Shared RFC1918 vRack network
  --interface NAME         Physical private NIC reported by OVHcloud
  --interface-mac MAC      Expected private NIC MAC (recommended)
  --vlan-id ID             Optional 802.1Q VLAN ID (1-4094)
  --non-interactive        Fail instead of prompting
  -h, --help               Show this help

API attachment requires an OVHcloud application key, application secret, and
consumer key. Create them for your account region in the OVHcloud API console.
The script reads OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, and
OVH_CONSUMER_KEY or asks in hidden prompts; credentials are never persisted.
EOF
}

prompt() {
    local variable_name="$1" prompt_text="$2" default_value="${3:-}" answer=""
    read -rp "$prompt_text${default_value:+ [$default_value]}: " answer
    printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

prefix_to_netmask() {
    local prefix="$1" mask

    [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix >= 1 && prefix <= 32 )) || \
        error "Invalid IPv4 prefix: $prefix"
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    printf '%u.%u.%u.%u\n' \
        "$(( (mask >> 24) & 255 ))" \
        "$(( (mask >> 16) & 255 ))" \
        "$(( (mask >> 8) & 255 ))" \
        "$(( mask & 255 ))"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --attach-server) shift; [[ $# -gt 0 ]] || error "Missing value for --attach-server"; DEDICATED_SERVER="$1"; MODE=attach ;;
        --attach-server=*) DEDICATED_SERVER="${1#*=}"; MODE=attach ;;
        --vrack) shift; [[ $# -gt 0 ]] || error "Missing value for --vrack"; VRACK_SERVICE="$1" ;;
        --vrack=*) VRACK_SERVICE="${1#*=}" ;;
        --ovh-endpoint) shift; [[ $# -gt 0 ]] || error "Missing value for --ovh-endpoint"; OVH_ENDPOINT="$1" ;;
        --ovh-endpoint=*) OVH_ENDPOINT="${1#*=}" ;;
        --configure-node) MODE=node ;;
        --private-ip) shift; [[ $# -gt 0 ]] || error "Missing value for --private-ip"; PRIVATE_IP="$1" ;;
        --private-ip=*) PRIVATE_IP="${1#*=}" ;;
        --network-cidr) shift; [[ $# -gt 0 ]] || error "Missing value for --network-cidr"; NETWORK_CIDR="$1" ;;
        --network-cidr=*) NETWORK_CIDR="${1#*=}" ;;
        --interface) shift; [[ $# -gt 0 ]] || error "Missing value for --interface"; PRIVATE_INTERFACE="$1" ;;
        --interface=*) PRIVATE_INTERFACE="${1#*=}" ;;
        --interface-mac) shift; [[ $# -gt 0 ]] || error "Missing value for --interface-mac"; PRIVATE_INTERFACE_MAC="$1" ;;
        --interface-mac=*) PRIVATE_INTERFACE_MAC="${1#*=}" ;;
        --vlan-id) shift; [[ $# -gt 0 ]] || error "Missing value for --vlan-id"; VLAN_ID="$1" ;;
        --vlan-id=*) VLAN_ID="${1#*=}" ;;
        --non-interactive) NON_INTERACTIVE=true ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1 (use --help)" ;;
    esac
    shift
done

[[ -n "$MODE" ]] || error "Select --attach-server or --configure-node."
TEMP_DIR="$(mktemp -d /tmp/bm-cluster-vrack.XXXXXX)"
chmod 700 "$TEMP_DIR"

configure_api_endpoint() {
    case "$OVH_ENDPOINT" in
        ovh-eu) API_BASE="https://eu.api.ovh.com/1.0" ;;
        ovh-ca) API_BASE="https://ca.api.ovh.com/1.0" ;;
        ovh-us) API_BASE="https://api.us.ovhcloud.com/1.0" ;;
        *) error "OVH API endpoint must be ovh-eu, ovh-ca, or ovh-us." ;;
    esac
}

ovh_api_request() {
    local method="$1" path="$2" body="${3:-}" allow_failure="${4:-false}"
    local timestamp signature request_config status api_message
    local url="$API_BASE$path" response="$TEMP_DIR/response.json"
    local -a request_args=()

    timestamp="$(curl -fsS --connect-timeout 10 --max-time 20 "$API_BASE/auth/time")" || \
        error "Unable to obtain OVHcloud API time from $OVH_ENDPOINT."
    [[ "$timestamp" =~ ^[0-9]+$ ]] || error "OVHcloud returned an invalid API timestamp."
    signature="\$1\$$(printf '%s' "$APPLICATION_SECRET$CONSUMER_KEY$method$url$body$timestamp" | sha1sum | awk '{print $1}')"
    request_config="$TEMP_DIR/request.conf"
    {
        printf 'silent\nshow-error\nconnect-timeout = 15\nmax-time = 60\n'
        printf 'header = "Accept: application/json"\n'
        printf 'header = "X-Ovh-Application: %s"\n' "$APPLICATION_KEY"
        printf 'header = "X-Ovh-Consumer: %s"\n' "$CONSUMER_KEY"
        printf 'header = "X-Ovh-Signature: %s"\n' "$signature"
        printf 'header = "X-Ovh-Timestamp: %s"\n' "$timestamp"
    } > "$request_config"
    chmod 600 "$request_config"
    request_args=(--config "$request_config" --request "$method" --url "$url" --output "$response" --write-out '%{http_code}')
    if [[ -n "$body" ]]; then
        request_args+=(--header 'Content-Type: application/json' --data-binary "$body")
    fi
    if ! status="$(curl "${request_args[@]}")"; then
        [[ "$allow_failure" == "true" ]] && return 1
        error "OVHcloud API request failed: $method $path"
    fi
    if [[ ! "$status" =~ ^2 ]]; then
        api_message="$(jq -r '.message // .class // empty' "$response" 2>/dev/null || true)"
        [[ "$allow_failure" == "true" ]] && return 1
        error "OVHcloud API returned HTTP $status for $method $path${api_message:+: $api_message}"
    fi
    if ! jq -e . "$response" >/dev/null 2>&1; then
        [[ "$allow_failure" == "true" ]] && return 1
        error "OVHcloud API returned invalid JSON for $method $path."
    fi
    API_RESPONSE="$response"
}

wait_for_vrack_task() {
    local task_id="$1" status
    for _ in {1..60}; do
        ovh_api_request GET "/vrack/$VRACK_SERVICE/task/$task_id"
        status="$(jq -r '.status // empty' "$API_RESPONSE")"
        case "$status" in
            done) return 0 ;;
            cancelled) error "OVHcloud cancelled vRack task $task_id." ;;
            init|todo|doing) sleep 2 ;;
            *) error "OVHcloud returned unknown status '$status' for vRack task $task_id." ;;
        esac
    done
    error "Timed out waiting for OVHcloud vRack task $task_id."
}

attach_server() {
    local attached_file="$TEMP_DIR/attached.json" details_file="$TEMP_DIR/details.json"
    local command_name interface_id interface_name task_id
    local private_macs=()

    [[ "$DEDICATED_SERVER" =~ ^[A-Za-z0-9._-]+$ ]] || error "Invalid OVHcloud Dedicated Server service name."
    [[ "$VRACK_SERVICE" =~ ^pn-[A-Za-z0-9-]+$ ]] || error "vRack service name must begin with pn-."
    configure_api_endpoint
    for command_name in curl jq sha1sum; do
        command -v "$command_name" >/dev/null 2>&1 || error "$command_name is required for OVHcloud API automation."
    done
    if [[ -z "$APPLICATION_KEY" || -z "$APPLICATION_SECRET" || -z "$CONSUMER_KEY" ]]; then
        [[ "$NON_INTERACTIVE" != "true" ]] || error "Set OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, and OVH_CONSUMER_KEY."
        [[ -n "$APPLICATION_KEY" ]] || prompt APPLICATION_KEY "OVHcloud API application key"
        if [[ -z "$APPLICATION_SECRET" ]]; then
            read -rsp "OVHcloud API application secret (input hidden): " APPLICATION_SECRET
            printf '\n' >&2
        fi
        if [[ -z "$CONSUMER_KEY" ]]; then
            read -rsp "OVHcloud API consumer key (input hidden): " CONSUMER_KEY
            printf '\n' >&2
        fi
    fi
    [[ "$APPLICATION_KEY" =~ ^[A-Za-z0-9]+$ && "$APPLICATION_SECRET" =~ ^[A-Za-z0-9]+$ && "$CONSUMER_KEY" =~ ^[A-Za-z0-9]+$ ]] || \
        error "OVHcloud API credentials contain unexpected characters."

    ovh_api_request GET /vrack
    jq -e --arg vrack "$VRACK_SERVICE" 'index($vrack) != null' "$API_RESPONSE" >/dev/null || \
        error "vRack $VRACK_SERVICE is not available to these OVHcloud credentials."
    ovh_api_request GET "/vrack/$VRACK_SERVICE/dedicatedServerInterface"
    cp "$API_RESPONSE" "$attached_file"
    ovh_api_request GET "/vrack/$VRACK_SERVICE/dedicatedServerInterfaceDetails"
    cp "$API_RESPONSE" "$details_file"
    interface_id="$(jq -r --arg server "$DEDICATED_SERVER" '.[] | select(.dedicatedServer == $server) | .dedicatedServerInterface' "$details_file" | head -n 1)"
    interface_name="$(jq -r --arg server "$DEDICATED_SERVER" '.[] | select(.dedicatedServer == $server) | .name // empty' "$details_file" | head -n 1)"

    if [[ -n "$interface_id" ]] && jq -e --arg id "$interface_id" 'index($id) != null' "$attached_file" >/dev/null; then
        info "$DEDICATED_SERVER interface is already attached to $VRACK_SERVICE."
    else
        if [[ -z "$interface_id" ]]; then
            ovh_api_request GET "/vrack/$VRACK_SERVICE/dedicatedServer"
            if jq -e --arg server "$DEDICATED_SERVER" 'index($server) != null' "$API_RESPONSE" >/dev/null; then
                info "$DEDICATED_SERVER is already attached through the OVHcloud legacy server-level association."
            else
                error "No eligible private interface for $DEDICATED_SERVER was returned. Confirm vRack compatibility and account activation in OVHcloud Control Panel."
            fi
        else
            info "Attaching $DEDICATED_SERVER interface to OVHcloud vRack $VRACK_SERVICE..."
            ovh_api_request POST "/vrack/$VRACK_SERVICE/dedicatedServerInterface" \
                "$(jq -cn --arg interface "$interface_id" '{dedicatedServerInterface:$interface}')"
            task_id="$(jq -r '.id // empty' "$API_RESPONSE")"
            [[ "$task_id" =~ ^[0-9]+$ ]] || error "OVHcloud did not return a vRack task ID."
            wait_for_vrack_task "$task_id"
            info "OVHcloud attached $DEDICATED_SERVER to $VRACK_SERVICE."
        fi
    fi

    if [[ ! "${interface_name,,}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
        if ovh_api_request GET "/dedicated/server/$DEDICATED_SERVER/networking" "" true; then
            mapfile -t private_macs < <(jq -r \
                '.interfaces[] | select(.type == "vrack") | .macs[]? // empty' \
                "$API_RESPONSE" | LC_ALL=C sort -u)
            if [[ ${#private_macs[@]} -eq 1 && "${private_macs[0],,}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
                interface_name="${private_macs[0],,}"
                info "Discovered the OVHcloud vRack NIC MAC: $interface_name"
            elif [[ ${#private_macs[@]} -gt 1 ]]; then
                warn "OVHcloud reports multiple vRack NIC MACs for $DEDICATED_SERVER; select the physical NIC or aggregation manually."
            fi
        else
            warn "Private NIC MAC discovery was unavailable. Grant GET /dedicated/server/*/networking or enter the Control Panel MAC manually."
        fi
    fi
    info "OVHcloud account attachment is complete; configure and activate a unique private IP on this server next."
    printf '%s\n' "$interface_name"
}

configure_node() {
    local prefix configured_interface default_interface ssh_server_ip ssh_interface actual_mac existing_addresses existing_cidr
    local candidate_interface
    local config_file backup_file="" config_content netmask

    if [[ -z "$PRIVATE_IP" || -z "$NETWORK_CIDR" ]]; then
        [[ "$NON_INTERACTIVE" != "true" ]] || error "--private-ip and --network-cidr are required."
        [[ -n "$NETWORK_CIDR" ]] || prompt NETWORK_CIDR "OVHcloud vRack RFC1918 network CIDR" "10.50.0.0/24"
        [[ -n "$PRIVATE_IP" ]] || prompt PRIVATE_IP "Unique private IPv4 for this server"
    fi
    trusted_private_ipv4 "$PRIVATE_IP" && ! tailscale_ipv4 "$PRIVATE_IP" || \
        error "vRack node IP must be an RFC1918 IPv4 address."
    trusted_private_cidr "$NETWORK_CIDR" || error "vRack network must be a valid RFC1918 CIDR."
    [[ "$NETWORK_CIDR" != "100.64.0.0/10" ]] || error "100.64.0.0/10 is reserved for Tailscale, not vRack."
    cidr_contains_ip "$NETWORK_CIDR" "$PRIVATE_IP" || error "$PRIVATE_IP is outside $NETWORK_CIDR."
    prefix="${NETWORK_CIDR#*/}"
    if [[ -n "$VLAN_ID" && "$VLAN_ID" != "0" ]]; then
        [[ "$VLAN_ID" =~ ^[0-9]+$ ]] && (( VLAN_ID >= 1 && VLAN_ID <= 4094 )) || \
            error "VLAN ID must be 1-4094."
    else
        VLAN_ID=""
    fi

    configured_interface="$(interface_owning_ip "$PRIVATE_IP")"
    if [[ -n "$configured_interface" ]]; then
        default_interface="$(ip -4 route show default | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
        [[ "$configured_interface" != "$default_interface" ]] || \
            error "Refusing existing vRack address $PRIVATE_IP on default-route interface $configured_interface."
        [[ ! "$configured_interface" =~ ^(lo|docker|br-|cni|flannel|veth) ]] || \
            error "Refusing existing vRack address $PRIVATE_IP on unsupported virtual interface $configured_interface."
        existing_cidr="$(ip -4 -o address show dev "$configured_interface" | \
            awk -v address="$PRIVATE_IP" '$4 ~ ("^" address "/") {print $4; exit}')"
        [[ "$existing_cidr" == "$PRIVATE_IP/$prefix" ]] || \
            error "Existing address $existing_cidr does not match requested vRack prefix $prefix."
        if [[ -n "$VLAN_ID" ]]; then
            [[ "$configured_interface" == "vrack$VLAN_ID" ]] || \
                error "vRack address $PRIVATE_IP is on $configured_interface, not requested VLAN interface vrack$VLAN_ID."
        elif [[ -n "$PRIVATE_INTERFACE" ]]; then
            [[ "$configured_interface" == "$PRIVATE_INTERFACE" ]] || \
                error "vRack address $PRIVATE_IP is on $configured_interface, not requested $PRIVATE_INTERFACE."
        fi
        if [[ -n "$PRIVATE_INTERFACE_MAC" ]]; then
            [[ "${PRIVATE_INTERFACE_MAC,,}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || \
                error "Invalid private interface MAC address."
            if [[ -n "$PRIVATE_INTERFACE" ]]; then
                ip link show dev "$PRIVATE_INTERFACE" >/dev/null 2>&1 || \
                    error "Interface $PRIVATE_INTERFACE does not exist."
                actual_mac="$(cat "/sys/class/net/$PRIVATE_INTERFACE/address")"
            else
                actual_mac="$(cat "/sys/class/net/$configured_interface/address")"
            fi
            [[ "${PRIVATE_INTERFACE_MAC,,}" == "${actual_mac,,}" ]] || \
                error "Existing vRack interface MAC $actual_mac does not match expected $PRIVATE_INTERFACE_MAC."
        fi
        info "vRack address $PRIVATE_IP is already configured on $configured_interface."
        printf '%s\n' "$configured_interface"
        return 0
    fi
    if [[ -z "$PRIVATE_INTERFACE" && -n "$PRIVATE_INTERFACE_MAC" ]]; then
        while IFS= read -r candidate_interface; do
            if [[ "$(cat "/sys/class/net/$candidate_interface/address")" == "${PRIVATE_INTERFACE_MAC,,}" ]]; then
                PRIVATE_INTERFACE="$candidate_interface"
                info "Matched OVHcloud private NIC MAC $PRIVATE_INTERFACE_MAC to $PRIVATE_INTERFACE."
                break
            fi
        done < <(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
    fi
    if [[ -z "$PRIVATE_INTERFACE" ]]; then
        [[ "$NON_INTERACTIVE" != "true" ]] || error "--interface is required when the vRack IP is not configured."
        ip -br link show >&2
        prompt PRIVATE_INTERFACE "Physical OVHcloud private/vRack interface name"
    fi
    [[ ${#PRIVATE_INTERFACE} -le 15 && "$PRIVATE_INTERFACE" =~ ^[A-Za-z0-9_.-]+$ ]] || \
        error "Invalid private interface name: $PRIVATE_INTERFACE"
    ip link show dev "$PRIVATE_INTERFACE" >/dev/null 2>&1 || error "Interface $PRIVATE_INTERFACE does not exist."
    default_interface="$(ip -4 route show default | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
    [[ "$PRIVATE_INTERFACE" != "$default_interface" ]] || \
        error "Refusing to configure default-route interface $PRIVATE_INTERFACE as vRack; select the OVHcloud private NIC."
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r _ _ ssh_server_ip _ <<< "$SSH_CONNECTION"
        ssh_interface="$(interface_owning_ip "$ssh_server_ip")"
        [[ "$PRIVATE_INTERFACE" != "$ssh_interface" ]] || \
            error "Refusing to change $PRIVATE_INTERFACE because it carries the current SSH bootstrap session."
    fi
    actual_mac="$(cat "/sys/class/net/$PRIVATE_INTERFACE/address")"
    if [[ -n "$PRIVATE_INTERFACE_MAC" ]]; then
        [[ "${PRIVATE_INTERFACE_MAC,,}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || error "Invalid private interface MAC address."
        [[ "${PRIVATE_INTERFACE_MAC,,}" == "${actual_mac,,}" ]] || \
            error "Interface $PRIVATE_INTERFACE has MAC $actual_mac, not expected $PRIVATE_INTERFACE_MAC."
    else
        warn "No expected MAC was supplied; verify $actual_mac matches the Private interface in OVHcloud Control Panel."
    fi
    existing_addresses="$(ip -4 -o address show dev "$PRIVATE_INTERFACE" scope global | awk '{print $4}')"
    [[ -z "$existing_addresses" ]] || error "$PRIVATE_INTERFACE already has address(es): $existing_addresses. Reconcile them manually before automation."

    if [[ -n "$VLAN_ID" ]]; then
        configured_interface="vrack$VLAN_ID"
    else
        configured_interface="$PRIVATE_INTERFACE"
    fi
    if [[ $EUID -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || error "sudo is required when not running as root."
        SUDO=(sudo)
        "${SUDO[@]}" -v
    fi

    if command -v netplan >/dev/null 2>&1; then
        config_file="/etc/netplan/90-bm-cluster-vrack.yaml"
        if [[ -n "$VLAN_ID" ]]; then
            config_content="network:
  version: 2
  ethernets:
    $PRIVATE_INTERFACE:
      dhcp4: false
      dhcp6: false
  vlans:
    $configured_interface:
      id: $VLAN_ID
      link: $PRIVATE_INTERFACE
      dhcp4: false
      dhcp6: false
      addresses:
        - $PRIVATE_IP/$prefix"
        else
            config_content="network:
  version: 2
  ethernets:
    $PRIVATE_INTERFACE:
      dhcp4: false
      dhcp6: false
      addresses:
        - $PRIVATE_IP/$prefix"
        fi
        if "${SUDO[@]}" test -f "$config_file"; then
            backup_file="$TEMP_DIR/netplan-backup.yaml"
            "${SUDO[@]}" cp "$config_file" "$backup_file"
        fi
        printf '%s\n' "$config_content" | "${SUDO[@]}" install -o root -g root -m 0600 /dev/stdin "$config_file"
        if ! "${SUDO[@]}" netplan generate || ! "${SUDO[@]}" netplan apply; then
            if [[ -n "$backup_file" ]]; then
                "${SUDO[@]}" cp "$backup_file" "$config_file"
            else
                "${SUDO[@]}" rm -f -- "$config_file"
            fi
            "${SUDO[@]}" netplan generate >/dev/null 2>&1 || true
            "${SUDO[@]}" netplan apply >/dev/null 2>&1 || true
            error "vRack netplan failed; the managed file was rolled back."
        fi
    elif [[ -d /etc/network/interfaces.d && -z "$VLAN_ID" ]]; then
        command -v ifup >/dev/null 2>&1 || error "ifupdown is required for this Debian network configuration."
        config_file="/etc/network/interfaces.d/90-bm-cluster-vrack"
        netmask="$(prefix_to_netmask "$prefix")"
        config_content="auto $PRIVATE_INTERFACE
iface $PRIVATE_INTERFACE inet static
    address $PRIVATE_IP
    netmask $netmask"
        if "${SUDO[@]}" test -f "$config_file"; then
            backup_file="$TEMP_DIR/ifupdown-backup"
            "${SUDO[@]}" cp "$config_file" "$backup_file"
        fi
        printf '%s\n' "$config_content" | "${SUDO[@]}" install -o root -g root -m 0600 /dev/stdin "$config_file"
        if ! "${SUDO[@]}" ifup "$PRIVATE_INTERFACE"; then
            if [[ -n "$backup_file" ]]; then
                "${SUDO[@]}" cp "$backup_file" "$config_file"
            else
                "${SUDO[@]}" rm -f -- "$config_file"
            fi
            error "Could not activate $PRIVATE_INTERFACE; the managed file was rolled back and public networking was not changed."
        fi
    else
        error "Automatic node networking supports Netplan, or untagged ifupdown. Configure this OS/VLAN manually, then rerun."
    fi

    for _ in {1..15}; do
        interface_owning_ip "$PRIVATE_IP" >/dev/null && break
        sleep 1
    done
    [[ "$(interface_owning_ip "$PRIVATE_IP")" == "$configured_interface" ]] || \
        error "vRack address $PRIVATE_IP did not become active on $configured_interface."
    [[ "$(ip -4 route show default | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')" != "$configured_interface" ]] || \
        error "Refusing vRack configuration that replaced the public default route."
    info "OVHcloud vRack node interface $configured_interface is ready at $PRIVATE_IP/$prefix; public routing is unchanged."
    printf '%s\n' "$configured_interface"
}

case "$MODE" in
    attach) attach_server ;;
    node) configure_node ;;
esac
