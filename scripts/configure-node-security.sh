#!/bin/bash
set -euo pipefail

APPLY=false
SERVER_EXPOSURE="${SERVER_EXPOSURE:-internet}"
APT_UPDATED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true ;;
    --server-exposure)
      shift
      [[ $# -gt 0 ]] || { echo "Missing value for --server-exposure"; echo "Usage: $0 [--apply] [--server-exposure internet|local]"; exit 1; }
      SERVER_EXPOSURE="$1"
      ;;
    --server-exposure=*)
      SERVER_EXPOSURE="${1#*=}"
      ;;
    *) echo "Unknown option: $1"; echo "Usage: $0 [--apply] [--server-exposure internet|local]"; exit 1 ;;
  esac
  shift
done

info() { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }

normalize_server_exposure() {
  case "${1,,}" in
    internet|internet-exposed|public|external) echo "internet" ;;
    local|local-only|private|internal|lan) echo "local" ;;
    *) return 1 ;;
  esac
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
  local backup_path="${path}.bak-ds-cluster"

  if sudo test -f "$path" && ! sudo test -f "$backup_path"; then
    sudo cp "$path" "$backup_path"
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
  write_root_file /etc/fail2ban/jail.local <<'EOF'
# Managed by scripts/configure-node-security.sh
[DEFAULT]
bantime = 1h
bantime.increment = true
bantime.rndtime = 5m
bantime.maxtime = 24h
findtime = 10m
maxretry = 5
backend = systemd
usedns = warn
banaction = ufw

[sshd]
enabled = true
port = ssh
filter = sshd
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
EOF
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

configure_ufw() {
  ensure_packages ufw

  info "Configuring UFW baseline..."
  sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  sudo ufw --force reset >/dev/null
  sudo ufw default deny incoming >/dev/null
  sudo ufw default allow outgoing >/dev/null
  sudo ufw logging medium >/dev/null

  info "Allowing required inbound ports..."
  sudo ufw allow OpenSSH >/dev/null
  sudo ufw allow 80/tcp >/dev/null
  sudo ufw allow 443/tcp >/dev/null
  sudo ufw allow 6443/tcp >/dev/null
  sudo ufw allow 8472/udp >/dev/null
  sudo ufw allow 10250/tcp >/dev/null

  if ip link show cni0 >/dev/null 2>&1; then
    sudo ufw allow in on cni0 >/dev/null
  fi
  if ip link show flannel.1 >/dev/null 2>&1; then
    sudo ufw allow in on flannel.1 >/dev/null
  fi

  sudo ufw --force enable >/dev/null
}

configure_fail2ban() {
  ensure_packages fail2ban
  write_fail2ban_config
  ensure_service fail2ban
}

configure_crowdsec() {
  ensure_crowdsec_repo
  ensure_packages crowdsec crowdsec-firewall-bouncer-nftables

  write_crowdsec_acquisitions
  sudo cscli hub update >/dev/null
  ensure_crowdsec_collection crowdsecurity/linux
  ensure_crowdsec_collection crowdsecurity/sshd
  ensure_service crowdsec
  write_crowdsec_bouncer_config "$(get_crowdsec_bouncer_api_key)"
  ensure_service crowdsec-firewall-bouncer
}

run_lynis_audit() {
  ensure_packages lynis
  info "Running Lynis baseline audit..."
  sudo lynis audit system --quick >/dev/null
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

if [[ "$APPLY" != "true" ]]; then
  info "Audit mode (no changes). Run with --apply to enforce rules."
  show_status
  exit 0
fi

if [[ "$SERVER_EXPOSURE" == "local" ]]; then
  info "Server marked local-only. Skipping internet-facing host security tooling."
  exit 0
fi

configure_ufw
configure_fail2ban
configure_crowdsec
run_lynis_audit

info "Host security tooling applied for internet-exposed server."
show_status
