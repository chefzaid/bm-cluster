#!/bin/bash
set -euo pipefail

PRIVATE_IP="${K3S_PRIVATE_ADDRESS:-}"
PRIVATE_INTERFACE="${K3S_PRIVATE_INTERFACE:-}"
PUBLIC_IP="${K3S_PUBLIC_ADDRESS:-}"
RESTART=false
CONFIG_PATH="/etc/rancher/k3s/config.yaml.d/20-bm-private-node-network.yaml"

info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Configure the K3s control plane to advertise its private cluster address while
retaining its public address for ingress.

Usage:
  configure-k3s-control-plane-network.sh [options]

Options:
  --private-ip IP          RFC1918 or Tailscale IPv4 used by cluster nodes
  --private-interface DEV  Interface that owns the private IP
  --public-ip IP           Public IPv4 advertised as the node ExternalIP
  --restart                Restart K3s after writing the drop-in
  -h, --help               Show this help

Values are automatically detected when omitted. Tailscale is preferred, then a
private address on the default-route interface. The managed K3s drop-in sets
node-ip, node-external-ip (when public), tls-san, and flannel-iface.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --private-ip) shift; [[ $# -gt 0 ]] || error "Missing value for --private-ip"; PRIVATE_IP="$1" ;;
        --private-ip=*) PRIVATE_IP="${1#*=}" ;;
        --private-interface) shift; [[ $# -gt 0 ]] || error "Missing value for --private-interface"; PRIVATE_INTERFACE="$1" ;;
        --private-interface=*) PRIVATE_INTERFACE="${1#*=}" ;;
        --public-ip) shift; [[ $# -gt 0 ]] || error "Missing value for --public-ip"; PUBLIC_IP="$1" ;;
        --public-ip=*) PUBLIC_IP="${1#*=}" ;;
        --restart) RESTART=true ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1" ;;
    esac
    shift
done

valid_ipv4() {
    local ip="$1" octet
    local -a octets
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

trusted_private_ipv4() {
    local ip="$1" a b _
    valid_ipv4 "$ip" || return 1
    IFS='.' read -r a b _ <<< "$ip"
    a=$((10#$a)); b=$((10#$b))
    (( a == 10 )) ||
        (( a == 172 && b >= 16 && b <= 31 )) ||
        (( a == 192 && b == 168 )) ||
        (( a == 100 && b >= 64 && b <= 127 ))
}

detect_default_route_value() {
    local key="$1"
    ip -4 route get 1.1.1.1 2>/dev/null | awk -v key="$key" \
        '{for (i=1; i<=NF; i++) if ($i == key) {print $(i+1); exit}}'
}

if [[ -z "$PRIVATE_IP" ]] && ip -4 address show dev tailscale0 >/dev/null 2>&1; then
    PRIVATE_IP="$(ip -4 -o address show dev tailscale0 scope global | awk 'NR==1 {sub(/\/.*/, "", $4); print $4}')"
    PRIVATE_INTERFACE=tailscale0
fi

default_source="$(detect_default_route_value src || true)"
default_interface="$(detect_default_route_value dev || true)"
if [[ -z "$PRIVATE_IP" ]] && trusted_private_ipv4 "$default_source"; then
    PRIVATE_IP="$default_source"
    PRIVATE_INTERFACE="$default_interface"
fi

if [[ -z "$PRIVATE_IP" ]]; then
    while read -r interface address; do
        [[ "$interface" =~ ^(lo|docker|br-|cni|flannel|veth) ]] && continue
        address="${address%/*}"
        if trusted_private_ipv4 "$address"; then
            PRIVATE_IP="$address"
            PRIVATE_INTERFACE="$interface"
            break
        fi
    done < <(ip -4 -o address show scope global | awk '{print $2, $4}')
fi

trusted_private_ipv4 "$PRIVATE_IP" || \
    error "No RFC1918 or Tailscale control-plane address was found. Install/connect the private network or provide --private-ip."

if [[ -z "$PRIVATE_INTERFACE" ]]; then
    PRIVATE_INTERFACE="$(ip -4 -o address show | awk -v ip="$PRIVATE_IP" \
        '{split($4, parts, "/")} parts[1] == ip {print $2; exit}')"
fi
[[ -n "$PRIVATE_INTERFACE" ]] || error "Could not determine the interface for $PRIVATE_IP"
ip -4 -o address show dev "$PRIVATE_INTERFACE" | awk '{print $4}' | grep -Fq "$PRIVATE_IP/" || \
    error "$PRIVATE_IP is not assigned to interface $PRIVATE_INTERFACE"

if [[ -z "$PUBLIC_IP" && -n "$default_source" ]] && ! trusted_private_ipv4 "$default_source"; then
    PUBLIC_IP="$default_source"
fi
if [[ -n "$PUBLIC_IP" ]]; then
    valid_ipv4 "$PUBLIC_IP" || error "Invalid public IPv4 address: $PUBLIC_IP"
    trusted_private_ipv4 "$PUBLIC_IP" && error "Public and private K3s addresses must be different"
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT
{
    printf '# Managed by scripts/configure-k3s-control-plane-network.sh\n'
    printf 'node-ip: "%s"\n' "$PRIVATE_IP"
    [[ -z "$PUBLIC_IP" ]] || printf 'node-external-ip: "%s"\n' "$PUBLIC_IP"
    printf 'tls-san+:\n  - "%s"\n' "$PRIVATE_IP"
    printf 'flannel-iface: "%s"\n' "$PRIVATE_INTERFACE"
} > "$tmp_file"

config_changed=true
if sudo test -f "$CONFIG_PATH" && sudo cmp -s "$tmp_file" "$CONFIG_PATH"; then
    config_changed=false
else
    sudo install -D -o root -g root -m 0644 "$tmp_file" "$CONFIG_PATH"
fi
info "K3s private node network: $PRIVATE_IP via $PRIVATE_INTERFACE${PUBLIC_IP:+; external IP: $PUBLIC_IP}"

if [[ "$RESTART" == "true" && "$config_changed" == "true" ]] && systemctl cat k3s.service >/dev/null 2>&1; then
    info "Restarting K3s to apply the node network..."
    sudo systemctl restart k3s
    sudo systemctl is-active --quiet k3s || error "K3s did not restart successfully"
elif [[ "$RESTART" == "true" && "$config_changed" != "true" ]]; then
    info "K3s private-network configuration is already current; restart is not required."
fi
