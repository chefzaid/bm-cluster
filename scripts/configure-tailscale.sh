#!/bin/bash
# Reconcile one named K3s mesh in a tailnet and provision a tagged node.
set -euo pipefail
# Never inherit tracing into credential handling.
set +x
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--fleet" ]]; then
    shift
    exec "$SCRIPT_DIR/configure-tailscale-fleet.sh" "$@"
fi
PLATFORM_CONFIG="$SCRIPT_DIR/../config/platform.env"
if [[ -r "$PLATFORM_CONFIG" ]]; then
    # shellcheck source=../config/platform.env
    source "$PLATFORM_CONFIG"
fi

TAILNET="${TAILSCALE_TAILNET:-${DEFAULT_TAILSCALE_TAILNET:--}}"
MESH_NAME="${TAILSCALE_MESH_NAME:-${DEFAULT_TAILSCALE_MESH_NAME:-bm-cluster}}"
CONTROL_PLANE_TAG="${TAILSCALE_CONTROL_PLANE_TAG:-}"
WORKER_TAG="${TAILSCALE_WORKER_TAG:-}"
AUTH_KEY_EXPIRY_SECONDS="${TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-${DEFAULT_TAILSCALE_AUTH_KEY_EXPIRY_SECONDS:-3600}}"
ROLE=""
MODE="ensure-node"
TAG_IP=""
NODE_HOSTNAME=""
API_TOKEN="${TAILSCALE_API_TOKEN:-}"
AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
API_TOKEN_STDIN=false
AUTH_KEY_STDIN=false
NON_INTERACTIVE=false
API_BASE="https://api.tailscale.com/api/v2"
TEMP_DIR=""
CURL_CONFIG=""
SUDO=()

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
    API_TOKEN=""
    AUTH_KEY=""
    unset API_TOKEN AUTH_KEY TAILSCALE_API_TOKEN TAILSCALE_AUTH_KEY 2>/dev/null || true
    if [[ -n "$TEMP_DIR" && "$TEMP_DIR" == /tmp/bm-cluster-tailscale.* && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT HUP INT TERM

usage() {
    cat <<'EOF'
Configure Tailscale for a named, provider-neutral K3s private network.

Interactive node setup:
  scripts/configure-tailscale.sh --role control-plane
  scripts/configure-tailscale.sh --role worker

Interactive cross-provider fleet setup (asks for every server endpoint):
  scripts/configure-tailscale.sh --fleet

The prompt requires a personal Tailscale API access token beginning with
"tskey-api-". Generate it in Tailscale Admin Console -> Settings -> Keys ->
Generate access token. Use an Owner, Admin, or Network admin because the script
manages policy and device tags. Input is hidden and the token is never persisted.

Options:
  --fleet                  Provision an inventory of SSH-reachable servers
  --role ROLE              control-plane or worker
  --tailnet NAME           Tailnet name; "-" uses the API token's tailnet
  --mesh-name NAME         Unique lower-case name used to isolate role tags
  --hostname NAME          Tailscale hostname (default: short system hostname)
  --auth-key-expiry SEC    One-use node-key validity (60 seconds to 90 days)
  --api-token-stdin        Read the Tailscale API access token from stdin
  --auth-key-stdin         Node-only setup using a one-use tskey-auth key on stdin
  --create-auth-key        Reconcile policy and print one tagged auth key to stdout
  --tag-ip IP              Reconcile policy and apply the role tag to this device IP
  --non-interactive        Fail instead of prompting for a missing API token
  -h, --help               Show this help

TAILSCALE_API_TOKEN may be used for non-interactive automation. Do not save it
in a file, shell profile, command argument, repository, or CI log.
EOF
}

normalize_role() {
    case "${1,,}" in
        control-plane|controlplane|server|master) printf 'control-plane\n' ;;
        worker|agent) printf 'worker\n' ;;
        *) return 1 ;;
    esac
}

valid_mesh_name() {
    [[ ${#1} -le 32 && "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

prompt_value() {
    local variable_name="$1" prompt_text="$2" default_value="${3:-}" answer=""
    read -rp "$prompt_text${default_value:+ [$default_value]}: " answer
    printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

tailscale_ipv4() {
    local ip="$1" a b c d
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<< "$ip"
    (( 10#$a == 100 && 10#$b >= 64 && 10#$b <= 127 && 10#$c <= 255 && 10#$d <= 255 ))
}

role_tag() {
    if [[ "$ROLE" == "control-plane" ]]; then
        printf '%s' "$CONTROL_PLANE_TAG"
    else
        printf '%s' "$WORKER_TAG"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) shift; [[ $# -gt 0 ]] || error "Missing value for --role"; ROLE="$1" ;;
        --role=*) ROLE="${1#*=}" ;;
        --tailnet) shift; [[ $# -gt 0 ]] || error "Missing value for --tailnet"; TAILNET="$1" ;;
        --tailnet=*) TAILNET="${1#*=}" ;;
        --mesh-name) shift; [[ $# -gt 0 ]] || error "Missing value for --mesh-name"; MESH_NAME="$1" ;;
        --mesh-name=*) MESH_NAME="${1#*=}" ;;
        --hostname) shift; [[ $# -gt 0 ]] || error "Missing value for --hostname"; NODE_HOSTNAME="$1" ;;
        --hostname=*) NODE_HOSTNAME="${1#*=}" ;;
        --auth-key-expiry) shift; [[ $# -gt 0 ]] || error "Missing value for --auth-key-expiry"; AUTH_KEY_EXPIRY_SECONDS="$1" ;;
        --auth-key-expiry=*) AUTH_KEY_EXPIRY_SECONDS="${1#*=}" ;;
        --api-token-stdin) API_TOKEN_STDIN=true ;;
        --auth-key-stdin) AUTH_KEY_STDIN=true ;;
        --create-auth-key) MODE="create-auth-key" ;;
        --tag-ip) shift; [[ $# -gt 0 ]] || error "Missing value for --tag-ip"; TAG_IP="$1"; MODE="tag-ip" ;;
        --tag-ip=*) TAG_IP="${1#*=}"; MODE="tag-ip" ;;
        --non-interactive) NON_INTERACTIVE=true ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1 (use --help)" ;;
    esac
    shift
done

if [[ -z "$ROLE" && "$NON_INTERACTIVE" != "true" ]]; then
    prompt_value ROLE "Node role (control-plane or worker)" "worker"
fi
[[ -n "$ROLE" ]] || error "--role is required."
ROLE="$(normalize_role "$ROLE")" || error "Role must be control-plane or worker."

# A direct interactive run gathers the complete mesh identity. Parent
# installers pass these values explicitly so piped credentials are never mixed
# with prompts.
if [[ -z "$API_TOKEN" && -z "$AUTH_KEY" && "$API_TOKEN_STDIN" != "true" && "$AUTH_KEY_STDIN" != "true" && "$NON_INTERACTIVE" != "true" ]]; then
    prompt_value TAILNET "Tailnet name or login domain ('-' means this token's tailnet)" "$TAILNET"
    prompt_value MESH_NAME "Unique mesh/cluster name (isolates this cluster's policy tags)" "$MESH_NAME"
    if [[ "$MODE" == "ensure-node" ]]; then
        prompt_value NODE_HOSTNAME "Tailscale hostname for this server" "${NODE_HOSTNAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
    fi
    [[ "$AUTH_KEY_EXPIRY_SECONDS" =~ ^[0-9]+$ ]] || error "Auth-key expiry must be a number of seconds."
    expiry_minutes="$((AUTH_KEY_EXPIRY_SECONDS / 60))"
    prompt_value expiry_minutes "One-use node auth-key lifetime in minutes" "$expiry_minutes"
    [[ "$expiry_minutes" =~ ^[1-9][0-9]*$ ]] || error "Auth-key lifetime must be a positive whole number of minutes."
    AUTH_KEY_EXPIRY_SECONDS="$((expiry_minutes * 60))"
fi
[[ "$TAILNET" =~ ^[-A-Za-z0-9@._]+$ ]] || error "Invalid tailnet name: $TAILNET"
valid_mesh_name "$MESH_NAME" || error "Mesh name must be 1-32 lower-case letters, numbers, or hyphens."
CONTROL_PLANE_TAG="${CONTROL_PLANE_TAG:-tag:${MESH_NAME}-control-plane}"
WORKER_TAG="${WORKER_TAG:-tag:${MESH_NAME}-worker}"
[[ "$CONTROL_PLANE_TAG" =~ ^tag:[a-z0-9][a-z0-9-]*$ ]] || error "Invalid control-plane tag: $CONTROL_PLANE_TAG"
[[ "$WORKER_TAG" =~ ^tag:[a-z0-9][a-z0-9-]*$ ]] || error "Invalid worker tag: $WORKER_TAG"
[[ "$CONTROL_PLANE_TAG" != "$WORKER_TAG" ]] || error "Control-plane and worker tags must differ."
[[ "$AUTH_KEY_EXPIRY_SECONDS" =~ ^[0-9]+$ ]] || error "Auth-key expiry must be a positive number of seconds."
(( AUTH_KEY_EXPIRY_SECONDS >= 60 && AUTH_KEY_EXPIRY_SECONDS <= 7776000 )) || \
    error "Auth-key expiry must be between 60 seconds and 90 days."

if [[ "$API_TOKEN_STDIN" == "true" && "$AUTH_KEY_STDIN" == "true" ]]; then
    error "API and node auth keys cannot both be read from the same stdin stream."
fi
if [[ "$API_TOKEN_STDIN" == "true" ]]; then
    IFS= read -r API_TOKEN || error "Could not read the Tailscale API access token from stdin."
fi
if [[ "$AUTH_KEY_STDIN" == "true" ]]; then
    [[ "$MODE" == "ensure-node" ]] || error "--auth-key-stdin is valid only for node setup."
    IFS= read -r AUTH_KEY || error "Could not read the Tailscale node auth key from stdin."
fi

if [[ -z "$API_TOKEN" && -z "$AUTH_KEY" ]]; then
    [[ "$NON_INTERACTIVE" != "true" ]] || error "Set TAILSCALE_API_TOKEN or use --api-token-stdin."
    read -rsp "Tailscale personal API access token (tskey-api-..., Admin Console -> Settings -> Keys): " API_TOKEN
    printf '\n' >&2
fi
if [[ -n "$API_TOKEN" && ! "$API_TOKEN" =~ ^tskey-api-[A-Za-z0-9_-]+$ ]]; then
    error "Expected a Tailscale API access token beginning with tskey-api-. An auth key (tskey-auth-...) is a different credential type."
fi
if [[ -n "$AUTH_KEY" && ! "$AUTH_KEY" =~ ^tskey-auth-[A-Za-z0-9_-]+$ ]]; then
    error "Expected a Tailscale node auth key beginning with tskey-auth-."
fi
if [[ "$MODE" != "ensure-node" && -z "$API_TOKEN" ]]; then
    error "$MODE requires a Tailscale API access token, not a node auth key."
fi

if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || error "sudo is required when not running as root."
    SUDO=(sudo)
fi

ensure_api_tools() {
    local missing=() package
    for package in ca-certificates curl jq; do
        dpkg -s "$package" >/dev/null 2>&1 || missing+=("$package")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        command -v apt-get >/dev/null 2>&1 || error "Debian/Ubuntu is required for automatic dependency installation."
        info "Installing Tailscale automation prerequisites: ${missing[*]}"
        "${SUDO[@]}" apt-get update -qq
        "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
    fi
}

ensure_api_tools
TEMP_DIR="$(mktemp -d /tmp/bm-cluster-tailscale.XXXXXX)"
chmod 700 "$TEMP_DIR"

prepare_api_client() {
    [[ -n "$API_TOKEN" ]] || error "A Tailscale API token is required for this operation."
    CURL_CONFIG="$TEMP_DIR/curl.conf"
    {
        printf 'silent\n'
        printf 'show-error\n'
        printf 'connect-timeout = 15\n'
        printf 'max-time = 60\n'
        printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN"
    } > "$CURL_CONFIG"
    chmod 600 "$CURL_CONFIG"
}

api_request() {
    local method="$1" path="$2" output_file="$3" headers_file="$4" request_file="${5:-}"
    local status
    local -a args=(--config "$CURL_CONFIG" --request "$method" --url "$API_BASE/$path" \
        --output "$output_file" --dump-header "$headers_file" --write-out '%{http_code}' \
        --header 'Accept: application/json')
    if [[ -n "$request_file" ]]; then
        args+=(--header 'Content-Type: application/json' --data-binary "@$request_file")
    fi
    status="$(curl "${args[@]}")" || error "Tailscale API request failed: $method $path"
    if [[ ! "$status" =~ ^2 ]]; then
        api_message="$(jq -r '.message // .error // empty' "$output_file" 2>/dev/null || true)"
        error "Tailscale API returned HTTP $status for $method $path${api_message:+: $api_message}"
    fi
}

validate_api_token() {
    local body="$TEMP_DIR/devices.json" headers="$TEMP_DIR/devices.headers"
    api_request GET "tailnet/$TAILNET/devices?fields=all" "$body" "$headers"
    jq -e '.devices | type == "array"' "$body" >/dev/null || error "Tailscale returned an invalid device list."
}

reconcile_policy() {
    local current="$TEMP_DIR/policy-current.json" merged="$TEMP_DIR/policy-merged.json"
    local headers="$TEMP_DIR/policy.headers" response="$TEMP_DIR/policy-response.json"
    local validate_headers="$TEMP_DIR/policy-validate.headers" etag etag_match fresh_default=false status api_message
    local managed_ports='["udp:8472","tcp:10250","tcp:2049","tcp:3260","tcp:8000","tcp:8002","tcp:8500-8504","tcp:9500-9503","tcp:10000-31000"]'

    api_request GET "tailnet/$TAILNET/acl" "$current" "$headers"
    jq -e 'type == "object"' "$current" >/dev/null || error "Tailscale returned a non-JSON policy file."
    etag="$(awk 'tolower($1) == "etag:" {gsub(/\r/, "", $2); print $2; exit}' "$headers")"
    [[ -n "$etag" ]] || error "The Tailscale policy response did not include an ETag."
    etag_match="$etag"
    [[ "$etag_match" == \"*\" ]] || etag_match="\"$etag_match\""
    [[ "${etag//\"/}" == "ts-default" ]] && fresh_default=true

    jq \
        --arg cp "$CONTROL_PLANE_TAG" \
        --arg worker "$WORKER_TAG" \
        --argjson peer "$managed_ports" \
        --argjson fresh "$fresh_default" '
        def managed_grant:
            ((.src // []) == ["autogroup:admin"] and (.dst // []) == [$cp, $worker]) or
            ((.src // []) == [$cp] and (.dst // []) == [$worker]) or
            ((.src // []) == [$worker] and (.dst // []) == [$cp]) or
            ((.src // []) == [$worker] and (.dst // []) == [$worker]);
        .tagOwners = (.tagOwners // {}) |
        .tagOwners[$cp] = [] |
        .tagOwners[$worker] = [] |
        .grants = ([((.grants // [])[]) | select(managed_grant | not)] + [
            {src:["autogroup:admin"], dst:[$cp,$worker], ip:["*"]},
            {src:[$cp], dst:[$worker], ip:($peer + ["tcp:22"] | unique)},
            {src:[$worker], dst:[$cp], ip:($peer + ["tcp:6443"] | unique)},
            {src:[$worker], dst:[$worker], ip:$peer}
        ]) |
        if $fresh then
            .acls = [((.acls // [])[]) | select(
                (((.src // .users // []) == ["*"]) and
                 ((.dst // .ports // []) == ["*:*"] or (.dst // .ports // []) == ["*"])) | not
            )]
        else . end
    ' "$current" > "$merged"

    if cmp -s <(jq -S . "$current") <(jq -S . "$merged"); then
        info "Tailscale policy and $MESH_NAME role tags are already current."
        return 0
    fi

    api_request POST "tailnet/$TAILNET/acl/validate" "$response" "$validate_headers" "$merged"
    status="$(curl --config "$CURL_CONFIG" --request POST --url "$API_BASE/tailnet/$TAILNET/acl" \
        --output "$response" --dump-header "$headers" --write-out '%{http_code}' \
        --header 'Accept: application/json' --header 'Content-Type: application/json' \
        --header "If-Match: $etag_match" --data-binary "@$merged")" || error "Failed to update the Tailscale policy."
    if [[ ! "$status" =~ ^2 ]]; then
        api_message="$(jq -r '.message // .error // empty' "$response" 2>/dev/null || true)"
        if [[ "$status" == "412" ]]; then
            error "The Tailscale policy changed concurrently. Run the script again to merge against the new version."
        fi
        error "Tailscale rejected the policy update with HTTP $status${api_message:+: $api_message}"
    fi
    info "Validated and updated the Tailscale policy without replacing unrelated rules."
}

create_auth_key() {
    local tag payload="$TEMP_DIR/auth-key-request.json" body="$TEMP_DIR/auth-key-response.json" headers="$TEMP_DIR/auth-key.headers" key
    tag="$(role_tag)"
    jq -n --arg tag "$tag" --arg description "$MESH_NAME $ROLE" --argjson expiry "$AUTH_KEY_EXPIRY_SECONDS" '{
        capabilities:{devices:{create:{reusable:false,ephemeral:false,preauthorized:true,tags:[$tag]}}},
        expirySeconds:$expiry,
        description:$description
    }' > "$payload"
    api_request POST "tailnet/$TAILNET/keys" "$body" "$headers" "$payload"
    key="$(jq -r '.key // empty' "$body")"
    [[ "$key" =~ ^tskey-auth-[A-Za-z0-9_-]+$ ]] || error "Tailscale did not return a usable node auth key."
    printf '%s\n' "$key"
}

tag_device_ip() {
    local ip="$1" tag devices="$TEMP_DIR/tag-devices.json" headers="$TEMP_DIR/tag-devices.headers"
    local device_id existing_tags payload="$TEMP_DIR/tags-request.json" response="$TEMP_DIR/tags-response.json"
    local key_payload="$TEMP_DIR/key-expiry-request.json"
    tag="$(role_tag)"
    api_request GET "tailnet/$TAILNET/devices?fields=all" "$devices" "$headers"
    device_id="$(jq -r --arg ip "$ip" '.devices[] | select(any(.addresses[]?; . == $ip)) | (.nodeId // .id) ' "$devices" | head -n 1)"
    [[ -n "$device_id" && "$device_id" != "null" ]] || error "No device with Tailscale IP $ip exists in this tailnet."
    existing_tags="$(jq -c --arg ip "$ip" '[.devices[] | select(any(.addresses[]?; . == $ip)) | (.tags // [])[]]' "$devices")"
    jq -n --argjson tags "$existing_tags" --arg tag "$tag" --arg cp "$CONTROL_PLANE_TAG" --arg worker "$WORKER_TAG" \
        '{tags:([$tags[] | select(. != $cp and . != $worker)] + [$tag] | unique)}' > "$payload"
    api_request POST "device/$device_id/tags" "$response" "$headers" "$payload"
    printf '%s\n' '{"keyExpiryDisabled":true}' > "$key_payload"
    api_request POST "device/$device_id/key" "$response" "$headers" "$key_payload"
    info "Applied $tag to Tailscale device $ip and disabled node-key expiry for this tagged server."
}

ensure_tailscale_installed() {
    local installer
    command -v tailscale >/dev/null 2>&1 && return 0
    command -v apt-get >/dev/null 2>&1 || error "Automatic Tailscale installation currently supports Debian/Ubuntu."
    installer="$TEMP_DIR/install-tailscale.sh"
    info "Installing Tailscale from its official Linux installer."
    curl -fsSL --proto '=https' --tlsv1.2 https://tailscale.com/install.sh -o "$installer"
    chmod 700 "$installer"
    "${SUDO[@]}" sh "$installer"
}

ensure_local_node() {
    local state local_ip auth_key_file
    ensure_tailscale_installed
    "${SUDO[@]}" systemctl enable --now tailscaled >/dev/null
    state="$("${SUDO[@]}" tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true)"
    if [[ "$state" != "Running" ]]; then
        if [[ -z "$AUTH_KEY" ]]; then
            AUTH_KEY="$(create_auth_key)"
        fi
        auth_key_file="$TEMP_DIR/node-auth-key"
        printf '%s\n' "$AUTH_KEY" > "$auth_key_file"
        chmod 600 "$auth_key_file"
        NODE_HOSTNAME="${NODE_HOSTNAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
        info "Connecting this $ROLE node to Tailscale with a one-use tagged key."
        "${SUDO[@]}" tailscale up \
            --auth-key="file:$auth_key_file" \
            --hostname="$NODE_HOSTNAME" \
            --ssh=false \
            --netfilter-mode=nodivert \
            --accept-dns=true \
            --accept-routes=false \
            --timeout=60s >/dev/null
        AUTH_KEY=""
    else
        set_args=(--ssh=false --netfilter-mode=nodivert)
        [[ -z "$NODE_HOSTNAME" ]] || set_args+=(--hostname="$NODE_HOSTNAME")
        "${SUDO[@]}" tailscale set "${set_args[@]}" >/dev/null
    fi
    local_ip="$("${SUDO[@]}" tailscale ip -4 | head -n 1)"
    tailscale_ipv4 "$local_ip" || error "Tailscale did not assign an IPv4 address."
    if [[ -n "$API_TOKEN" ]]; then
        tag_device_ip "$local_ip"
    fi
    info "Tailscale $ROLE node is ready at $local_ip; Tailscale SSH is disabled and UFW remains authoritative."
    printf '%s\n' "$local_ip"
}

if [[ -n "$API_TOKEN" ]]; then
    prepare_api_client
    validate_api_token
    reconcile_policy
fi

case "$MODE" in
    create-auth-key)
        create_auth_key
        ;;
    tag-ip)
        tailscale_ipv4 "$TAG_IP" || error "--tag-ip must be a Tailscale IPv4 address."
        tag_device_ip "$TAG_IP"
        ;;
    ensure-node)
        ensure_local_node
        ;;
esac
