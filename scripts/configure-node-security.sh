#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_LIBRARY="$SCRIPT_DIR/lib/network.sh"
if [[ ! -r "$NETWORK_LIBRARY" ]]; then
  echo "[ERROR] Shared network library not found: $NETWORK_LIBRARY" >&2
  exit 1
fi
# shellcheck source=lib/network.sh
source "$NETWORK_LIBRARY"

APPLY=false
SERVER_EXPOSURE="${SERVER_EXPOSURE:-internet}"
NODE_ROLE="${NODE_ROLE:-control-plane}"
K3S_NODE_NETWORK_CIDR="${K3S_NODE_NETWORK_CIDR:-}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
HARDENED_SSH_PORT="${HARDENED_SSH_PORT:-}"
CLOUDFLARE_PROXY_ONLY="${CLOUDFLARE_PROXY_ONLY:-}"
SSH_ALLOWED_USERS="${SSH_ALLOWED_USERS:-${SUDO_USER:-$USER}}"
APT_UPDATED=false

usage() {
  echo "Usage: $0 [--apply] [--server-exposure internet|local] [--node-role control-plane|worker] [--control-plane-ip PRIVATE_IP] [--ssh-port PORT]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --server-exposure)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --server-exposure"; usage; exit 1; }
      SERVER_EXPOSURE="$1"
      ;;
    --server-exposure=*)
      SERVER_EXPOSURE="${1#*=}"
      ;;
    --node-role)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --node-role"; usage; exit 1; }
      NODE_ROLE="$1"
      ;;
    --node-role=*)
      NODE_ROLE="${1#*=}"
      ;;
    --control-plane-ip)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --control-plane-ip"; usage; exit 1; }
      CONTROL_PLANE_IP="$1"
      ;;
    --control-plane-ip=*)
      CONTROL_PLANE_IP="${1#*=}"
      ;;
    --ssh-port)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --ssh-port"; usage; exit 1; }
      HARDENED_SSH_PORT="$1"
      ;;
    --ssh-port=*)
      HARDENED_SSH_PORT="${1#*=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

if [[ -z "$HARDENED_SSH_PORT" && -n "${SSH_CONNECTION:-}" ]]; then
  read -r _ _ _ HARDENED_SSH_PORT <<< "$SSH_CONNECTION"
fi
if [[ -z "$HARDENED_SSH_PORT" ]] && command -v sshd >/dev/null 2>&1; then
  HARDENED_SSH_PORT="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
fi
HARDENED_SSH_PORT="${HARDENED_SSH_PORT:-22}"

info() { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }

normalize_node_role() {
  case "${1,,}" in
    control-plane|controlplane|server|master) echo "control-plane" ;;
    worker|agent) echo "worker" ;;
    *) return 1 ;;
  esac
}

detect_control_plane_cluster_interface() {
  local interface address default_route default_source

  if [[ -n "${K3S_PRIVATE_ADDRESS:-}" ]] && \
      cidr_contains_ip "$K3S_NODE_NETWORK_CIDR" "$K3S_PRIVATE_ADDRESS"; then
    interface_owning_ip "$K3S_PRIVATE_ADDRESS"
    return
  fi

  default_route="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
  default_source="$(awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$default_route")"
  if [[ -n "$default_source" ]] && cidr_contains_ip "$K3S_NODE_NETWORK_CIDR" "$default_source"; then
    awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$default_route"
    return
  fi

  while read -r interface address; do
    [[ "$interface" =~ ^(lo|docker|br-|cni|flannel|veth|tailscale) ]] && continue
    address="${address%/*}"
    if cidr_contains_ip "$K3S_NODE_NETWORK_CIDR" "$address"; then
      printf '%s\n' "$interface"
      return
    fi
  done < <(ip -4 -o address show scope global | awk '{print $2, $4}')

  if ip -4 address show dev tailscale0 >/dev/null 2>&1; then
    address="$(ip -4 -o address show dev tailscale0 scope global | awk 'NR == 1 {sub(/\/.*/, "", $4); print $4}')"
    if tailscale_ipv4 "$address" && cidr_contains_ip "$K3S_NODE_NETWORK_CIDR" "$address"; then
      printf 'tailscale0\n'
      return
    fi
  fi

  return 1
}

tailscale_transport_selected() {
  local cidr_address=""

  if [[ -n "$K3S_NODE_NETWORK_CIDR" ]]; then
    cidr_address="${K3S_NODE_NETWORK_CIDR%/*}"
  fi
  if tailscale_ipv4 "${CONTROL_PLANE_IP:-}" || \
      tailscale_ipv4 "${K3S_PRIVATE_ADDRESS:-}" || \
      tailscale_ipv4 "$cidr_address"; then
    return 0
  fi
  return 1
}

configure_tailscale_firewall_integration() {
  local local_tailscale_ip route route_interface route_source

  tailscale_transport_selected || return 0

  command -v tailscale >/dev/null 2>&1 || \
    err "Refusing to configure UFW: install Tailscale before selecting a Tailscale node network"
  sudo tailscale status >/dev/null 2>&1 || \
    err "Refusing to configure UFW: connect this node to Tailscale first"
  local_tailscale_ip="$(sudo tailscale ip -4 2>/dev/null | head -n 1)"
  tailscale_ipv4 "$local_tailscale_ip" || \
    err "Refusing to configure UFW: Tailscale has not assigned this node an IPv4 address"

  if [[ "$NODE_ROLE" == "worker" ]]; then
    tailscale_ipv4 "$CONTROL_PLANE_IP" || \
      err "Refusing to configure worker UFW: the control-plane address must be a Tailscale IPv4"
    route="$(ip -4 route get "$CONTROL_PLANE_IP" 2>/dev/null)" || \
      err "Refusing to configure worker UFW: the Tailscale control plane is not routable"
    route_interface="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$route")"
    route_source="$(awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$route")"
    [[ "$route_interface" == "tailscale0" ]] || \
      err "Refusing to configure worker UFW: route to $CONTROL_PLANE_IP uses ${route_interface:-no interface}, not tailscale0"
    [[ "$route_source" == "$local_tailscale_ip" ]] || \
      err "Refusing to configure worker UFW: route source ${route_source:-none} does not match Tailscale IP $local_tailscale_ip"
    info "Tailscale preflight passed on $local_tailscale_ip; worker UFW can now close public ingress."
  fi

}

make_ufw_authoritative_for_tailscale() {
  tailscale_transport_selected || return 0

  # Keep Tailscale's existing admission path active while UFW is rebuilt. Only
  # hand authority to UFW after its exact tailscale0 rules are enabled, avoiding
  # a window where neither layer admits the current private SSH connection.
  sudo tailscale set --ssh=false --netfilter-mode=nodivert >/dev/null || \
    err "Unable to make UFW authoritative for Tailscale traffic"
}

validate_worker_private_ssh_before_firewall() {
  local route route_interface route_source default_interface
  local ssh_client_ip ssh_server_ip ssh_server_port ssh_interface

  [[ "$NODE_ROLE" == "worker" ]] || return 0
  route="$(ip -4 route get "$CONTROL_PLANE_IP" 2>/dev/null)" || \
    err "Refusing to configure worker UFW: the private control-plane address is not routable"
  route_interface="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$route")"
  route_source="$(awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$route")"
  trusted_private_ipv4 "$route_source" || \
    err "Refusing to configure worker UFW: route to the control plane uses non-private source ${route_source:-none}"
  cidr_contains_ip "$K3S_NODE_NETWORK_CIDR" "$route_source" || \
    err "Refusing to configure worker UFW: route source $route_source is outside $K3S_NODE_NETWORK_CIDR"
  [[ -n "$route_interface" ]] || err "Refusing to configure worker UFW: private route has no interface"

  if ! tailscale_transport_selected; then
    default_interface="$(ip -4 route show default | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
    [[ "$route_interface" != "$default_interface" ]] || \
      err "Refusing to configure worker UFW: OVHcloud vRack traffic uses public default interface $route_interface"
  fi
  [[ -n "${SSH_CONNECTION:-}" ]] || \
    err "Refusing to configure worker UFW without a proven private SSH session. Run install-worker.sh from the control plane over the selected private transport."
  read -r ssh_client_ip _ ssh_server_ip ssh_server_port <<< "$SSH_CONNECTION"
  [[ "$ssh_client_ip" == "$CONTROL_PLANE_IP" ]] || \
    err "Refusing to configure worker UFW: current SSH client $ssh_client_ip is not control plane $CONTROL_PLANE_IP"
  [[ "$ssh_server_ip" == "$route_source" ]] || \
    err "Refusing to configure worker UFW: current SSH endpoint $ssh_server_ip is not private worker address $route_source"
  ssh_interface="$(interface_owning_ip "$ssh_server_ip")"
  [[ "$ssh_interface" == "$route_interface" ]] || \
    err "Refusing to configure worker UFW: current SSH endpoint is not on private interface $route_interface"
  [[ "$ssh_server_port" == "$HARDENED_SSH_PORT" ]] || \
    err "Refusing to configure worker UFW: current SSH port $ssh_server_port differs from configured port $HARDENED_SSH_PORT"
  info "Private SSH preflight passed from $CONTROL_PLANE_IP to $route_source on $route_interface; UFW may now close public ingress."
}

apt_update() {
  if [[ "$APT_UPDATED" != "true" ]]; then
    sudo apt-get update -qq
    APT_UPDATED=true
  fi
}

ensure_packages() {
  local missing=()
  local package

  for package in "$@"; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
      missing+=("$package")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    info "Installing packages: ${missing[*]}"
    apt_update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  fi
}

backup_file_if_exists() {
  local path="$1"
  local backup_path="/var/backups/bm-cluster/config${path}.bak"

  if sudo test -f "$path" && ! sudo test -f "$backup_path"; then
    sudo install -d -o root -g root -m 0700 "$(dirname "$backup_path")"
    sudo cp "$path" "$backup_path"
    sudo chmod 0600 "$backup_path"
  fi
}

write_root_file() {
  local destination_path="$1"
  local mode="${2:-0644}"
  local tmp_file

  tmp_file="$(mktemp)"
  cat > "$tmp_file"
  sudo install -D -m "$mode" "$tmp_file" "$destination_path"
  rm -f "$tmp_file"
}

ensure_service() {
  local service_name="$1"
  sudo systemctl enable --now "$service_name" >/dev/null 2>&1
  sudo systemctl restart "$service_name" >/dev/null 2>&1
}

remove_packages_if_installed() {
  local installed=()
  local package

  for package in "$@"; do
    if dpkg -s "$package" >/dev/null 2>&1; then
      installed+=("$package")
    fi
  done

  if [[ ${#installed[@]} -gt 0 ]]; then
    info "Removing packages excluded by this node's security policy: ${installed[*]}"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${installed[@]}" >/dev/null
  fi
}

ensure_crowdsec_repo() {
  local candidate

  candidate="$(apt-cache policy crowdsec 2>/dev/null | awk '/Candidate:/ {candidate=$2} END {print candidate}')"
  if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
    return 0
  fi

  info "Installing CrowdSec package repository..."
  ensure_packages ca-certificates curl gpg
  curl -fsSL https://install.crowdsec.net | sudo -E sh >/dev/null
  APT_UPDATED=false
}

ensure_crowdsec_collection() {
  local collection="$1"

  if sudo cscli collections list -o raw 2>/dev/null | awk -v target="$collection" '$1 == target {found=1} END {exit(found ? 0 : 1)}'; then
    return 0
  fi

  info "Installing CrowdSec collection ${collection}..."
  sudo cscli collections install "$collection" >/dev/null
}

write_fail2ban_config() {
  backup_file_if_exists /etc/fail2ban/jail.local
  write_root_file /etc/fail2ban/jail.local <<EOF
# Managed by scripts/configure-node-security.sh
[DEFAULT]
# Stricter SSH brute-force policy: fewer attempts, longer observation window,
# longer bans, and exponential repeat-offender escalation.
bantime = 24h
bantime.increment = true
bantime.factor = 2
bantime.rndtime = 10m
bantime.maxtime = 30d
findtime = 1h
maxretry = 3
backend = systemd
usedns = warn
banaction = ufw

[sshd]
enabled = true
port = $HARDENED_SSH_PORT
filter = sshd[mode=aggressive]
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
EOF
}

write_crowdsec_profiles() {
  backup_file_if_exists /etc/crowdsec/profiles.yaml
  write_root_file /etc/crowdsec/profiles.yaml <<'EOF'
name: default_ip_remediation
#debug: true
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
 - type: ban
   duration: 7d
# notifications:
#   - slack_default  # Set the webhook in /etc/crowdsec/notifications/slack.yaml before enabling this.
#   - splunk_default # Set the splunk url and token in /etc/crowdsec/notifications/splunk.yaml before enabling this.
#   - http_default   # Set the required http parameters in /etc/crowdsec/notifications/http.yaml before enabling this.
#   - email_default  # Set the required email parameters in /etc/crowdsec/notifications/email.yaml before enabling this.
on_success: break
---
name: default_range_remediation
#debug: true
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Range"
decisions:
 - type: ban
   duration: 7d
# notifications:
#   - slack_default  # Set the webhook in /etc/crowdsec/notifications/slack.yaml before enabling this.
#   - splunk_default # Set the splunk url and token in /etc/crowdsec/notifications/splunk.yaml before enabling this.
#   - http_default   # Set the required http parameters in /etc/crowdsec/notifications/http.yaml before enabling this.
#   - email_default  # Set the required email parameters in /etc/crowdsec/notifications/email.yaml before enabling this.
on_success: break
EOF
}

write_crowdsec_ssh_time_based_scenario() {
  backup_file_if_exists /etc/crowdsec/scenarios/ssh-time-based-bf.yaml
  write_root_file /etc/crowdsec/scenarios/ssh-time-based-bf.yaml <<'EOF'
# ssh time-based bruteforce with false positive reduction
type: conditional
name: crowdsecurity/ssh-time-based-bf
description: "Detect time-based ssh bruteforce attempts that evade rate limiting (with false positive reduction)"
filter: "evt.Meta.service == 'ssh' && evt.Meta.log_type in ['ssh_failed-auth', 'auth_success']"
groupby: evt.Meta.source_ip
capacity: -1
cancel_on: "evt.Meta.log_type == 'auth_success'"
condition: |
    let failedAuths = filter(queue.Queue, {#.Meta.log_type == 'ssh_failed-auth'});
    len(failedAuths) >= 4 &&
    MedianInterval(map(failedAuths[-4:], {#.Time})) > duration("10m")
leakspeed: 2h
blackhole: 5m
reprocess: true
labels:
  service: ssh
  behavior: "ssh:bruteforce"
  spoofable: 0
  confidence: 3
  classification:
    - attack.T1110
  label: "SSH Time-Based Bruteforce"
  remediation: true
---
# ssh user-enum time-based with false positive reduction
type: conditional
name: crowdsecurity/ssh-time-based-bf_user-enum
description: "Detect time-based ssh user enum bruteforce attempts (with false positive reduction)"
filter: "evt.Meta.service == 'ssh' && evt.Meta.log_type in ['ssh_failed-auth', 'auth_success']"
groupby: evt.Meta.source_ip
distinct: evt.Meta.target_user
capacity: -1
cancel_on: "evt.Meta.log_type == 'auth_success'"
condition: |
    let failedAuths = filter(queue.Queue, {#.Meta.log_type == 'ssh_failed-auth'});
    len(failedAuths) >= 4 &&
    MedianInterval(map(failedAuths[-4:], {#.Time})) > duration("10m")
leakspeed: 2h
blackhole: 5m
reprocess: true
labels:
  service: ssh
  behavior: "ssh:bruteforce"
  spoofable: 0
  confidence: 3
  classification:
    - attack.T1589
    - attack.T1110
  label: "SSH Time-Based User Enumeration"
  remediation: true
EOF
}

configure_crowdsec_inotify_limits() {
  write_root_file /etc/sysctl.d/99-crowdsec-inotify.conf <<'EOF'
# Managed by scripts/configure-node-security.sh
# Allow CrowdSec and container-heavy workloads to create enough filesystem watches.
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 1048576
EOF

  sudo sysctl -w fs.inotify.max_user_instances=1024 >/dev/null
  sudo sysctl -w fs.inotify.max_user_watches=1048576 >/dev/null
}

write_crowdsec_acquisitions() {
  backup_file_if_exists /etc/crowdsec/acquis.d/setup.linux.yaml
  backup_file_if_exists /etc/crowdsec/acquis.d/setup.sshd.yaml
  backup_file_if_exists /etc/crowdsec/acquis.yaml
  sudo rm -f /etc/crowdsec/acquis.yaml

  write_root_file /etc/crowdsec/acquis.d/setup.linux.yaml <<'EOF'
# Managed by scripts/configure-node-security.sh
filenames:
  - /var/log/messages
  - /var/log/syslog
  - /var/log/kern.log
labels:
  type: syslog
  source: file
EOF

  write_root_file /etc/crowdsec/acquis.d/setup.sshd.yaml <<'EOF'
# Managed by scripts/configure-node-security.sh
filenames:
  - /var/log/auth.log
  - /var/log/secure
labels:
  type: syslog
  source: file
EOF
}

get_crowdsec_bouncer_api_key() {
  local config_path="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
  local api_key=""
  local bouncer_name=""

  if sudo test -f "$config_path"; then
    api_key="$(sudo awk -F': ' '$1=="api_key"{gsub(/"/,"",$2); print $2; exit}' "$config_path")"
  fi

  if [[ -z "$api_key" ]]; then
    bouncer_name="ds-cluster-$(hostname -s)-firewall-bouncer-$(date +%s)"
    api_key="$(sudo cscli bouncers add "$bouncer_name" -o raw 2>/dev/null || true)"
  fi

  [[ -n "$api_key" ]] || err "Unable to determine CrowdSec bouncer API key"
  printf '%s\n' "$api_key"
}

write_crowdsec_bouncer_config() {
  local api_key="$1"

  backup_file_if_exists /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
  write_root_file /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml <<EOF
# Managed by scripts/configure-node-security.sh
mode: nftables
update_frequency: 10s
log_mode: file
log_dir: /var/log/
log_level: info
log_compression: true
log_max_size: 100
log_max_backups: 3
log_max_age: 30
api_url: http://127.0.0.1:8080/
api_key: ${api_key}
insecure_skip_verify: false
disable_ipv6: false
deny_action: DROP
deny_log: false
supported_decisions_types:
  - ban
blacklists_ipv4: crowdsec-blacklists
blacklists_ipv6: crowdsec6-blacklists
ipset_type: nethash
iptables_chains:
  - INPUT
iptables_add_rule_comments: true
nftables:
  ipv4:
    enabled: true
    set-only: false
    table: crowdsec
    chain: crowdsec-chain
    priority: -10
  ipv6:
    enabled: true
    set-only: false
    table: crowdsec6
    chain: crowdsec6-chain
    priority: -10
nftables_hooks:
  - input
  - forward
pf:
  anchor_name: ""
prometheus:
  enabled: false
  listen_addr: 127.0.0.1
  listen_port: 60601
EOF
}

configure_worker_forwarding_guard() {
  local interfaces=("$@")
  local interface

  if [[ "$NODE_ROLE" != "worker" || ${#interfaces[@]} -eq 0 ]]; then
    if sudo systemctl cat bm-cluster-worker-ingress-guard.service >/dev/null 2>&1; then
      sudo systemctl disable --now bm-cluster-worker-ingress-guard.service >/dev/null 2>&1 || true
    fi
    return 0
  fi
  for interface in "${interfaces[@]}"; do
    [[ ${#interface} -le 15 && "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]] || \
      err "Unsafe worker interface name: $interface"
  done
  ensure_packages nftables util-linux
  sudo install -d -o root -g root -m 0755 /etc/nftables.d
  {
    printf '%s\n' \
      '# Managed by scripts/configure-node-security.sh' \
      'table inet bm_cluster_worker_guard {' \
      '  chain input_guard {' \
      '    type filter hook input priority -150; policy accept;' \
      '    ct state established,related accept'
    for interface in "${interfaces[@]}"; do
      printf '    iifname "%s" udp sport 67 udp dport 68 accept\n' "$interface"
      printf '    iifname "%s" udp sport 547 udp dport 546 accept\n' "$interface"
      printf '    iifname "%s" meta l4proto ipv6-icmp accept\n' "$interface"
      printf '    iifname "%s" drop\n' "$interface"
    done
    printf '%s\n' \
      '  }' \
      '  chain forward_guard {' \
      '    type filter hook forward priority -150; policy accept;' \
      '    ct state established,related accept'
    for interface in "${interfaces[@]}"; do
      printf '    iifname "%s" drop\n' "$interface"
    done
    printf '%s\n' '  }' '}'
  } | write_root_file /etc/nftables.d/bm-cluster-worker-ingress.nft 0600

  write_root_file /usr/local/sbin/bm-cluster-worker-ingress-guard 0755 <<'EOF'
#!/bin/sh
set -eu
table_name=bm_cluster_worker_guard
if /usr/sbin/nft list table inet "$table_name" >/dev/null 2>&1; then
    /usr/sbin/nft delete table inet "$table_name"
fi
if [ "${1:-start}" = stop ]; then
    exit 0
fi
exec /usr/sbin/nft -f /etc/nftables.d/bm-cluster-worker-ingress.nft
EOF

  write_root_file /etc/systemd/system/bm-cluster-worker-ingress-guard.service <<'EOF'
[Unit]
Description=Block public input and forwarded ingress on bm-cluster workers
After=network-pre.target nftables.service ufw.service
Before=docker.service k3s-agent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bm-cluster-worker-ingress-guard start
ExecStop=/usr/local/sbin/bm-cluster-worker-ingress-guard stop

[Install]
WantedBy=multi-user.target
EOF
  sudo unshare --net /usr/sbin/nft -c -f /etc/nftables.d/bm-cluster-worker-ingress.nft || \
    err "Refusing to replace the worker ingress guard because its nftables policy is invalid"
  sudo systemctl daemon-reload
  sudo systemctl enable bm-cluster-worker-ingress-guard.service >/dev/null
  sudo systemctl restart bm-cluster-worker-ingress-guard.service
}

configure_ufw() {
  local cloudflare_response=""
  local cloudflare_cidrs=()
  local cluster_interface=""
  local cidr interface
  local untrusted_interfaces=()

  ensure_packages ufw

  if [[ "$NODE_ROLE" == "worker" ]]; then
    cluster_interface="$(ip -4 route get "$CONTROL_PLANE_IP" 2>/dev/null | \
      awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
    [[ -n "$cluster_interface" ]] || err "Unable to determine the private interface used to reach $CONTROL_PLANE_IP"
    [[ "$cluster_interface" == "tailscale0" ]] || [[ ! "$cluster_interface" =~ ^(lo|docker|br-|cni|flannel|veth) ]] || \
      err "Route to the control plane uses unsupported virtual interface $cluster_interface"
  elif [[ -n "$K3S_NODE_NETWORK_CIDR" ]]; then
    cluster_interface="$(detect_control_plane_cluster_interface || true)"
    [[ -n "$cluster_interface" ]] || \
      err "Unable to find a private control-plane interface within $K3S_NODE_NETWORK_CIDR"
  fi

  if [[ -n "$K3S_NODE_NETWORK_CIDR" ]] && ! trusted_private_cidr "$K3S_NODE_NETWORK_CIDR"; then
    err "K3S_NODE_NETWORK_CIDR must be RFC1918 or Tailscale 100.64.0.0/10: $K3S_NODE_NETWORK_CIDR"
  fi

  if [[ "$NODE_ROLE" == "control-plane" ]]; then
    if [[ "$SERVER_EXPOSURE" == "local" ]]; then
      CLOUDFLARE_PROXY_ONLY=false
    elif [[ -z "$CLOUDFLARE_PROXY_ONLY" ]]; then
      if sudo test -f /etc/bm-cluster/cloudflare-proxy-only; then
        CLOUDFLARE_PROXY_ONLY=true
      else
        CLOUDFLARE_PROXY_ONLY=false
      fi
    fi
    [[ "$CLOUDFLARE_PROXY_ONLY" =~ ^(true|false)$ ]] || err "CLOUDFLARE_PROXY_ONLY must be true or false"
  else
    # Worker nodes do not terminate public ingress in this topology.
    CLOUDFLARE_PROXY_ONLY=false
  fi

  # Fetch and validate the allowlist before resetting UFW so a network/API
  # failure can never leave the host firewall disabled.
  if [[ "$NODE_ROLE" == "control-plane" && "$CLOUDFLARE_PROXY_ONLY" == "true" ]]; then
    ensure_packages ca-certificates curl jq
    cloudflare_response="$(curl -fsS https://api.cloudflare.com/client/v4/ips)" || err "Unable to download Cloudflare proxy networks"
    jq -e '.success == true and ((.result.ipv4_cidrs | length) + (.result.ipv6_cidrs | length) > 0)' \
      <<< "$cloudflare_response" >/dev/null || err "Cloudflare returned an invalid proxy network list"
    mapfile -t cloudflare_cidrs < <(jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[]' <<< "$cloudflare_response")
  fi

  info "Configuring UFW baseline..."
  sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  if sudo grep -q '^IPV6=' /etc/default/ufw; then
    sudo sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  else
    printf 'IPV6=yes\n' | sudo tee -a /etc/default/ufw >/dev/null
  fi
  sudo ufw --force reset >/dev/null
  sudo ufw default deny incoming >/dev/null
  sudo ufw default allow outgoing >/dev/null
  sudo ufw logging medium >/dev/null

  info "Allowing required inbound ports..."
  if [[ "$NODE_ROLE" == "control-plane" ]]; then
    # Password SSH remains available on the internet-facing control plane by
    # operator request; CrowdSec and Fail2ban protect it in internet mode.
    sudo ufw allow "$HARDENED_SSH_PORT/tcp" >/dev/null
    if [[ "$CLOUDFLARE_PROXY_ONLY" == "true" ]]; then
      info "Restricting ports 80/443 to Cloudflare proxy networks..."
      for cidr in "${cloudflare_cidrs[@]}"; do
        sudo ufw allow from "$cidr" to any port 80 proto tcp comment 'Cloudflare proxy' >/dev/null
        sudo ufw allow from "$cidr" to any port 443 proto tcp comment 'Cloudflare proxy' >/dev/null
      done
    else
      sudo ufw allow 80/tcp >/dev/null
      sudo ufw allow 443/tcp >/dev/null
    fi
  else
    info "Restricting worker SSH to control plane $CONTROL_PLANE_IP on $cluster_interface..."
    sudo ufw allow in on "$cluster_interface" from "$CONTROL_PLANE_IP" to any port "$HARDENED_SSH_PORT" proto tcp comment 'SSH from control plane only' >/dev/null

    # Kubernetes NodePort and Docker-published traffic may traverse FORWARD
    # instead of INPUT. Deny both paths on every provider/non-cluster interface
    # while preserving stateful replies for worker-initiated outbound traffic.
    mapfile -t untrusted_interfaces < <(
      {
        ip -4 -o address show scope global
        ip -6 -o address show scope global
      } | awk '{print $2}' | LC_ALL=C sort -u
    )
    for interface in "${untrusted_interfaces[@]}"; do
      [[ "$interface" == "$cluster_interface" ]] && continue
      [[ "$interface" =~ ^(lo|docker|br-|cni|flannel|veth|tailscale|kube-ipvs) ]] && continue
      info "Blocking host and forwarded ingress on worker interface $interface..."
      sudo ufw deny in on "$interface" comment 'No worker provider ingress' >/dev/null
      sudo ufw route deny in on "$interface" comment 'No worker forwarded ingress' >/dev/null
    done
  fi
  if [[ -n "$K3S_NODE_NETWORK_CIDR" ]]; then
    if [[ "$NODE_ROLE" == "control-plane" ]]; then
      info "Restricting the K3s API, Flannel, and kubelet traffic to $K3S_NODE_NETWORK_CIDR..."
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 6443 proto tcp >/dev/null
    else
      info "Restricting worker Flannel and kubelet traffic to $K3S_NODE_NETWORK_CIDR on $cluster_interface..."
    fi
    if [[ "$NODE_ROLE" == "worker" ]]; then
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 8472 proto udp >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 10250 proto tcp >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 2049 proto tcp comment 'Longhorn RWX' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 3260 proto tcp comment 'Longhorn iSCSI' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 8000 proto tcp comment 'Longhorn backing image' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 8002 proto tcp comment 'Longhorn backing data' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 8500:8504 proto tcp comment 'Longhorn instance manager' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 9500:9503 proto tcp comment 'Longhorn manager' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 10000:31000 proto tcp comment 'Longhorn engines and replicas' >/dev/null
    else
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 8472 proto udp >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 10250 proto tcp >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 2049 proto tcp comment 'Longhorn RWX' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 3260 proto tcp comment 'Longhorn iSCSI' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 8000 proto tcp comment 'Longhorn backing image' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 8002 proto tcp comment 'Longhorn backing data' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 8500:8504 proto tcp comment 'Longhorn instance manager' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 9500:9503 proto tcp comment 'Longhorn manager' >/dev/null
      sudo ufw allow in on "$cluster_interface" from "$K3S_NODE_NETWORK_CIDR" to any port 10000:31000 proto tcp comment 'Longhorn engines and replicas' >/dev/null
    fi
  else
    # A single-node cluster does not need a public Kubernetes API. Worker
    # enrollment adds an explicit local-network rule through add-k3s-workers.sh.
    warn "K3S_NODE_NETWORK_CIDR is unset; the K3s API and peer ports are not exposed publicly."
  fi

  if ip link show cni0 >/dev/null 2>&1; then
    sudo ufw allow in on cni0 >/dev/null
  fi
  if ip link show flannel.1 >/dev/null 2>&1; then
    sudo ufw allow in on flannel.1 >/dev/null
  fi

  sudo ufw --force enable >/dev/null
  configure_worker_forwarding_guard "${untrusted_interfaces[@]}"
}

configure_sshd() {
  local config_path="/etc/ssh/sshd_config.d/40-bm-cluster-hardening.conf"
  local backup_path="/var/backups/bm-cluster/config${config_path}.bak"

  [[ "$SSH_ALLOWED_USERS" =~ ^[a-zA-Z0-9_.@-]+([[:space:]]+[a-zA-Z0-9_.@-]+)*$ ]] || \
    err "SSH_ALLOWED_USERS must be a space-separated list of local usernames"

  backup_file_if_exists "$config_path"
  write_root_file "$config_path" 0600 <<EOF
# Managed by scripts/configure-node-security.sh
# Password login is intentionally retained by operator request.
PasswordAuthentication yes
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers $SSH_ALLOWED_USERS
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
DisableForwarding yes
PermitUserRC no
MaxStartups 10:30:30
PerSourceMaxStartups 3
EOF

  if ! sudo sshd -t; then
    if sudo test -f "$backup_path"; then
      sudo cp "$backup_path" "$config_path"
    else
      sudo rm -f "$config_path"
    fi
    err "Refusing to reload SSH because the hardened configuration failed validation"
  fi
  sudo systemctl reload ssh
}

disable_unused_rpcbind() {
  # NFSv4 clients do not require rpcbind. Keep it only when this node is
  # actively using an older NFS mount; otherwise close the unused listener.
  if findmnt -rn -t nfs,nfs4 >/dev/null 2>&1; then
    warn "An NFS mount is active; leaving rpcbind unchanged."
    return 0
  fi

  if systemctl list-unit-files rpcbind.service rpcbind.socket --no-legend 2>/dev/null | grep -q rpcbind; then
    sudo systemctl disable --now rpcbind.socket rpcbind.service >/dev/null 2>&1 || true
  fi
}

configure_log_retention() {
  local cloud_init_config="/etc/logrotate.d/cloud-init"
  local duplicate_config="/etc/logrotate.d/cloud-init-base"
  local legacy_backup

  write_root_file /etc/systemd/journald.conf.d/99-bm-cluster-retention.conf <<'EOF'
# Managed by scripts/configure-node-security.sh
Storage=persistent
SystemMaxUse=4G
MaxRetentionSec=3month
Compress=yes
Seal=yes
EOF

  backup_file_if_exists /etc/logrotate.d/rsyslog
  write_root_file /etc/logrotate.d/rsyslog <<'EOF'
# Managed by scripts/configure-node-security.sh
# Keep authentication evidence for approximately three months while retaining
# the higher-volume general system logs for four weeks.
/var/log/auth.log
{
    rotate 13
    weekly
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}

/var/log/syslog
/var/log/mail.log
/var/log/kern.log
/var/log/user.log
/var/log/cron.log
{
    rotate 4
    weekly
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF

  # Ubuntu releases that temporarily ship both packages can define the same
  # cloud-init log twice, causing every logrotate run to fail. Preserve the
  # duplicate outside logrotate's accepted filename pattern.
  if sudo test -f "$cloud_init_config" && sudo test -f "$duplicate_config" && \
     sudo cmp -s "$cloud_init_config" "$duplicate_config"; then
    sudo install -d -o root -g root -m 0700 /var/backups/bm-cluster/config/etc/logrotate.d
    sudo mv "$duplicate_config" /var/backups/bm-cluster/config/etc/logrotate.d/cloud-init-base.disabled-bm-cluster
  fi

  # Older revisions left backup files inside logrotate.d, where logrotate
  # interpreted them as active policies. Move those backups out of the include
  # directory before validating the complete configuration.
  while IFS= read -r legacy_backup; do
    sudo install -d -o root -g root -m 0700 /var/backups/bm-cluster/config/etc/logrotate.d
    sudo mv "$legacy_backup" "/var/backups/bm-cluster/config/etc/logrotate.d/$(basename "$legacy_backup")"
  done < <(sudo find /etc/logrotate.d -maxdepth 1 -type f -name '*.bak-*' -print)

  if sudo logrotate --debug /etc/logrotate.conf 2>&1 | grep -q '^error:'; then
    err "The generated logrotate configuration failed validation"
  fi
  sudo systemctl restart systemd-journald
  sudo systemctl reset-failed logrotate.service
  sudo systemctl start logrotate.service
}

configure_fail2ban() {
  ensure_packages fail2ban
  write_fail2ban_config
  sudo fail2ban-client -t >/dev/null
  ensure_service fail2ban
}

configure_crowdsec() {
  ensure_crowdsec_repo
  ensure_packages crowdsec crowdsec-firewall-bouncer-nftables

  configure_crowdsec_inotify_limits
  write_crowdsec_acquisitions
  write_crowdsec_profiles
  sudo cscli hub update >/dev/null
  ensure_crowdsec_collection crowdsecurity/linux
  ensure_crowdsec_collection crowdsecurity/sshd
  write_crowdsec_ssh_time_based_scenario
  sudo crowdsec -t -c /etc/crowdsec/config.yaml >/dev/null
  ensure_service crowdsec
  write_crowdsec_bouncer_config "$(get_crowdsec_bouncer_api_key)"
  ensure_service crowdsec-firewall-bouncer
}

configure_lynis_control_plane() {
  ensure_packages lynis openssh-client
  if [[ -x "$SCRIPT_DIR/audit-cluster-nodes.sh" ]]; then
    sudo install -D -o root -g root -m 0755 \
      "$SCRIPT_DIR/audit-cluster-nodes.sh" /usr/local/sbin/bm-cluster-audit-nodes
  fi
  [[ -x "$SCRIPT_DIR/configure-lynis-schedule.sh" ]] || \
    err "The Lynis schedule reconciler is missing or not executable"
  sudo "$SCRIPT_DIR/configure-lynis-schedule.sh"
  if ! sudo test -s /var/log/lynis-report.dat; then
    info "Running the initial Lynis baseline audit..."
    sudo systemctl start bm-cluster-lynis.service
  fi
}

remove_internet_only_tools() {
  sudo fail2ban-client stop >/dev/null 2>&1 || true
  sudo systemctl disable --now fail2ban crowdsec crowdsec-firewall-bouncer \
    crowdsec-firewall-bouncer.service >/dev/null 2>&1 || true
  remove_packages_if_installed \
    fail2ban crowdsec crowdsec-firewall-bouncer-nftables crowdsec-firewall-bouncer-iptables
}

remove_worker_lynis() {
  remove_packages_if_installed lynis
}

show_status() {
  sudo ufw status verbose || true

  if command -v fail2ban-client >/dev/null 2>&1; then
    sudo fail2ban-client status sshd 2>/dev/null || sudo fail2ban-client status || true
  fi

  if command -v cscli >/dev/null 2>&1; then
    sudo cscli metrics 2>/dev/null || true
  fi

  if command -v lynis >/dev/null 2>&1; then
    sudo lynis show version 2>/dev/null || true
  fi
}

command -v sudo >/dev/null 2>&1 || err "sudo is required"
SERVER_EXPOSURE="$(normalize_server_exposure "$SERVER_EXPOSURE")" || err "server exposure must be 'internet' or 'local'"
NODE_ROLE="$(normalize_node_role "$NODE_ROLE")" || err "node role must be 'control-plane' or 'worker'"
[[ "$HARDENED_SSH_PORT" =~ ^[0-9]+$ && "$HARDENED_SSH_PORT" -ge 1 && "$HARDENED_SSH_PORT" -le 65535 ]] || \
  err "SSH port must be an integer from 1 to 65535"

if [[ "$APPLY" != "true" ]]; then
  info "Audit mode (no changes). Run with --apply to enforce rules."
  show_status
  exit 0
fi

if [[ "$NODE_ROLE" == "worker" ]]; then
  [[ "$SERVER_EXPOSURE" == "local" ]] || err "Internet-facing workers are forbidden; use a local/private worker"
  [[ -n "$K3S_NODE_NETWORK_CIDR" ]] || err "K3S_NODE_NETWORK_CIDR is required when configuring a worker firewall"
  trusted_private_cidr "$K3S_NODE_NETWORK_CIDR" || \
    err "K3S_NODE_NETWORK_CIDR must be RFC1918 or Tailscale 100.64.0.0/10"
  [[ -n "$CONTROL_PLANE_IP" ]] || err "CONTROL_PLANE_IP is required so worker SSH can be restricted to the control plane"
  trusted_private_ipv4 "$CONTROL_PLANE_IP" || \
    err "CONTROL_PLANE_IP must be an RFC1918 or Tailscale IPv4 address"
  if [[ "$K3S_NODE_NETWORK_CIDR" == "100.64.0.0/10" ]]; then
    # Cross-provider workers may need a provider address for initial bootstrap
    # and outbound updates. configure_tailscale_firewall_integration runs before
    # any UFW reset and refuses to continue until tailscale0 is ready.
    info "Tailscale worker transport selected; validating the overlay before closing public ingress."
  else
    # OVHcloud vRack is configured and private SSH is proven before UFW. A
    # provider NIC may remain for bootstrap/outbound traffic, but receives no
    # inbound allowance in configure_ufw.
    info "OVHcloud vRack worker selected; validating private SSH before closing public ingress."
  fi
fi

configure_tailscale_firewall_integration
validate_worker_private_ssh_before_firewall
configure_ufw
make_ufw_authoritative_for_tailscale
if [[ "$SERVER_EXPOSURE" == "internet" ]]; then
  configure_sshd
  disable_unused_rpcbind
  configure_fail2ban
  configure_crowdsec
  configure_log_retention
  info "Internet-facing SSH protection applied with Fail2ban and CrowdSec."
else
  remove_internet_only_tools
  info "Local-only node: UFW applied; Fail2ban and CrowdSec are not installed."
fi

if [[ "$NODE_ROLE" == "control-plane" ]]; then
  configure_lynis_control_plane
  info "Lynis is installed on the control plane for local and remote-node audits."
else
  remove_worker_lynis
  info "Worker node: Lynis is not installed persistently."
fi

info "Host security policy applied for $SERVER_EXPOSURE $NODE_ROLE node."
show_status
