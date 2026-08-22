#!/bin/bash
# Provider-neutral interactive provisioning of a named Tailscale server mesh.
set -euo pipefail
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_CONFIGURATOR="$SCRIPT_DIR/configure-tailscale.sh"
PLATFORM_CONFIG="$SCRIPT_DIR/../config/platform.env"
if [[ -r "$PLATFORM_CONFIG" ]]; then
    # shellcheck source=../config/platform.env
    source "$PLATFORM_CONFIG"
fi

TAILNET="${TAILSCALE_TAILNET:-${DEFAULT_TAILSCALE_TAILNET:--}}"
MESH_NAME="${TAILSCALE_MESH_NAME:-${DEFAULT_TAILSCALE_MESH_NAME:-bm-cluster}}"
AUTH_KEY_EXPIRY_SECONDS="${TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-${DEFAULT_TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-3600}}"
API_TOKEN="${TAILSCALE_API_TOKEN:-}"
DEFAULT_SSH_USER="${USER:-root}"
DEFAULT_SSH_PORT=22
DEFAULT_IDENTITY_FILE=""

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    API_TOKEN=""
    unset API_TOKEN TAILSCALE_API_TOKEN 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

usage() {
    cat <<'EOF'
Provision a named Tailscale K3s mesh across any providers.

Usage:
  scripts/configure-tailscale.sh --fleet

The assistant asks for the tailnet, a unique mesh name, short-lived auth-key
lifetime, personal API access token, and the complete server inventory. For
every server it asks for the existing SSH address, user, port, identity file,
role, and desired Tailscale hostname. Existing addresses are bootstrap paths;
Tailscale assigns the persistent private addresses shown at the end.

SSH key authentication and root or passwordless sudo are required. The API
credential must be a personal access token beginning with tskey-api- from
Admin Console -> Settings -> Keys, with Owner/Admin/Network-admin capability.
EOF
}

prompt() {
    local variable_name="$1" prompt_text="$2" default_value="${3:-}" answer=""
    read -rp "$prompt_text${default_value:+ [$default_value]}: " answer
    printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

normalize_role() {
    case "${1,,}" in
        control-plane|controlplane|server|master) printf 'control-plane\n' ;;
        worker|agent) printf 'worker\n' ;;
        *) return 1 ;;
    esac
}

tailscale_ipv4() {
    local ip="$1" a b c d
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<< "$ip"
    (( 10#$a == 100 && 10#$b >= 64 && 10#$b <= 127 && 10#$c <= 255 && 10#$d <= 255 ))
}

build_target() {
    local user="$1" host="$2"
    if [[ "$host" == *@* || -z "$user" ]]; then
        printf '%s' "$host"
    else
        printf '%s@%s' "$user" "$host"
    fi
}

configure_ssh_options() {
    local port="$1" identity_file="$2"
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || error "Invalid SSH port: $port"
    [[ -z "$identity_file" || -f "$identity_file" ]] || error "SSH identity file does not exist: $identity_file"
    ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$port")
    scp_options=(-q -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -P "$port")
    if [[ -n "$identity_file" ]]; then
        ssh_options+=(-i "$identity_file")
        scp_options+=(-i "$identity_file")
    fi
}

provision_server() {
    local target="$1" role="$2" node_hostname="$3"
    local remote_dir remote_script quoted_dir quoted_script auth_key node_output node_ip

    info "Checking SSH and passwordless sudo on $target..."
    ssh "${ssh_options[@]}" "$target" \
        'test "$(id -u)" -eq 0 || (command -v sudo >/dev/null 2>&1 && sudo -n true)' >/dev/null || \
        error "Cannot use root or passwordless sudo on $target."
    remote_dir="$(ssh "${ssh_options[@]}" "$target" 'mktemp -d /tmp/tailscale-mesh.XXXXXX')"
    [[ "$remote_dir" == /tmp/tailscale-mesh.* ]] || error "Could not create a safe temporary directory on $target."
    printf -v quoted_dir '%q' "$remote_dir"
    ssh "${ssh_options[@]}" "$target" "chmod 700 $quoted_dir"
    scp "${scp_options[@]}" "$NODE_CONFIGURATOR" "$target:$remote_dir/"
    remote_script="$remote_dir/configure-tailscale.sh"
    printf -v quoted_script '%q' "$remote_script"

    auth_key="$(printf '%s\n' "$API_TOKEN" | "$NODE_CONFIGURATOR" \
        --role "$role" --tailnet "$TAILNET" --mesh-name "$MESH_NAME" \
        --auth-key-expiry "$AUTH_KEY_EXPIRY_SECONDS" --create-auth-key --api-token-stdin)"
    [[ "$auth_key" =~ ^tskey-auth-[A-Za-z0-9_-]+$ ]] || error "Tailscale did not return a node auth key for $target."

    info "Installing Tailscale and joining $target as $role."
    if ! node_output="$(printf '%s\n' "$auth_key" | ssh "${ssh_options[@]}" "$target" \
        "chmod 700 $quoted_script && $quoted_script --role $(printf '%q' "$role") --tailnet $(printf '%q' "$TAILNET") --mesh-name $(printf '%q' "$MESH_NAME") --hostname $(printf '%q' "$node_hostname") --auth-key-stdin")"; then
        auth_key=""
        ssh "${ssh_options[@]}" "$target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true
        error "Tailscale provisioning failed on $target."
    fi
    auth_key=""
    node_ip="$(awk 'NF {value=$0} END {print value}' <<< "$node_output")"
    tailscale_ipv4 "$node_ip" || \
        error "$target did not return a valid Tailscale IPv4 address."
    printf '%s\n' "$API_TOKEN" | "$NODE_CONFIGURATOR" \
        --role "$role" --tailnet "$TAILNET" --mesh-name "$MESH_NAME" \
        --tag-ip "$node_ip" --api-token-stdin >/dev/null
    ssh "${ssh_options[@]}" "$target" "rm -r -- $quoted_dir" >/dev/null 2>&1 || true
    printf '%s' "$node_ip"
}

[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -eq 0 ]] || error "This fleet assistant is interactive and accepts no options (use --help)."
[[ -x "$NODE_CONFIGURATOR" ]] || error "Node configurator is missing or not executable: $NODE_CONFIGURATOR"
command -v ssh >/dev/null 2>&1 || error "ssh is required."
command -v scp >/dev/null 2>&1 || error "scp is required."

printf '%s\n' \
    "Tailscale cross-provider server mesh" \
    "Each existing IP/DNS name below is used only to bootstrap over SSH." \
    "The servers communicate through their assigned Tailscale addresses afterward."
prompt TAILNET "Tailnet name/login domain ('-' uses the token's tailnet)" "$TAILNET"
prompt MESH_NAME "Unique mesh/cluster name" "$MESH_NAME"
[[ "$AUTH_KEY_EXPIRY_SECONDS" =~ ^[0-9]+$ ]] || error "Auth-key expiry must be a number of seconds."
expiry_minutes="$((AUTH_KEY_EXPIRY_SECONDS / 60))"
prompt expiry_minutes "One-use node auth-key lifetime in minutes" "$expiry_minutes"
[[ "$expiry_minutes" =~ ^[1-9][0-9]*$ ]] || error "Auth-key lifetime must be a positive whole number of minutes."
AUTH_KEY_EXPIRY_SECONDS="$((expiry_minutes * 60))"
prompt DEFAULT_SSH_USER "Default SSH user" "$DEFAULT_SSH_USER"
prompt DEFAULT_SSH_PORT "Default SSH port" "$DEFAULT_SSH_PORT"
prompt DEFAULT_IDENTITY_FILE "Default SSH private key ('-' for agent/config)" "$DEFAULT_IDENTITY_FILE"
[[ "$DEFAULT_IDENTITY_FILE" != "-" ]] || DEFAULT_IDENTITY_FILE=""
if [[ -z "$API_TOKEN" ]]; then
    read -rsp "Tailscale personal API access token (tskey-api-..., Admin Console -> Settings -> Keys): " API_TOKEN
    printf '\n'
fi
[[ "$API_TOKEN" =~ ^tskey-api-[A-Za-z0-9_-]+$ ]] || error "Expected a personal Tailscale API access token beginning with tskey-api-."

server_count=""
while [[ ! "$server_count" =~ ^[1-9][0-9]*$ ]]; do
    prompt server_count "Number of servers to configure"
    [[ "$server_count" =~ ^[1-9][0-9]*$ ]] || warn "Enter a positive whole number."
done

declare -a result_hosts=() result_names=() result_roles=() result_ips=()
for ((index=1; index<=server_count; index++)); do
    printf '\nServer %d of %d\n' "$index" "$server_count"
    bootstrap_host=""
    ssh_user="$DEFAULT_SSH_USER"
    ssh_port="$DEFAULT_SSH_PORT"
    identity_file="$DEFAULT_IDENTITY_FILE"
    role=worker
    prompt bootstrap_host "Existing server IP or DNS name reachable over SSH"
    [[ -n "$bootstrap_host" ]] || error "A bootstrap IP or DNS name is required."
    [[ "$bootstrap_host" =~ ^[A-Za-z0-9._:-]+$ || "$bootstrap_host" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]] || \
        error "Invalid SSH bootstrap endpoint: $bootstrap_host"
    prompt ssh_user "SSH user for this server" "$ssh_user"
    prompt ssh_port "SSH port for this server" "$ssh_port"
    prompt identity_file "SSH private key for this server ('-' for agent/config)" "$identity_file"
    [[ "$identity_file" != "-" ]] || identity_file=""
    prompt role "Server role (control-plane or worker)" "$role"
    role="$(normalize_role "$role")" || error "Role must be control-plane or worker."
    configure_ssh_options "$ssh_port" "$identity_file"
    target="$(build_target "$ssh_user" "$bootstrap_host")"
    detected_hostname="$(ssh "${ssh_options[@]}" "$target" "hostname -s | tr '[:upper:]' '[:lower:]'")" || \
        error "Cannot connect to $target to detect its hostname."
    node_hostname="$detected_hostname"
    prompt node_hostname "Tailscale hostname for this server" "$node_hostname"
    [[ "$node_hostname" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
        error "Tailscale hostnames must use lower-case letters, numbers, and hyphens."
    node_ip="$(provision_server "$target" "$role" "$node_hostname")"
    result_hosts+=("$bootstrap_host")
    result_names+=("$node_hostname")
    result_roles+=("$role")
    result_ips+=("$node_ip")
done

printf '\n%-28s %-24s %-15s %s\n' "BOOTSTRAP ENDPOINT" "TAILSCALE HOSTNAME" "ROLE" "TAILSCALE IP"
for ((index=0; index<${#result_ips[@]}; index++)); do
    printf '%-28s %-24s %-15s %s\n' \
        "${result_hosts[$index]}" "${result_names[$index]}" "${result_roles[$index]}" "${result_ips[$index]}"
done
info "Mesh '$MESH_NAME' is configured. Use the Tailscale IPs for private server-to-server traffic."
