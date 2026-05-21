#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT="$SCRIPT_DIR/../configs/security"
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

install_config() {
  local source_path="$1"
  local destination_path="$2"

  [[ -f "$source_path" ]] || err "Missing config file: $source_path"
  sudo install -D -m 0644 "$source_path" "$destination_path"
}

ensure_service() {
  local service_name="$1"
  sudo systemctl enable --now "$service_name" >/dev/null 2>&1
  sudo systemctl restart "$service_name" >/dev/null 2>&1
}

ensure_crowdsec_repo() {
  local candidate

  candidate="$(apt-cache policy crowdsec 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
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

  if sudo cscli collections list 2>/dev/null | grep -q "^${collection}[[:space:]]"; then
    return 0
  fi

  info "Installing CrowdSec collection ${collection}..."
  sudo cscli collections install "$collection" >/dev/null
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
  install_config "$CONFIG_ROOT/fail2ban/jail.local" /etc/fail2ban/jail.local
  ensure_service fail2ban
}

configure_crowdsec() {
  ensure_crowdsec_repo
  ensure_packages crowdsec crowdsec-firewall-bouncer-iptables

  install_config "$CONFIG_ROOT/crowdsec/acquis.yaml" /etc/crowdsec/acquis.yaml
  sudo cscli hub update >/dev/null
  ensure_crowdsec_collection crowdsecurity/linux
  ensure_crowdsec_collection crowdsecurity/sshd
  ensure_service crowdsec
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
