#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_CONFIG="$SCRIPT_DIR/../config/platform.env"
if [[ ! -r "$PLATFORM_CONFIG" ]]; then
    echo "[ERROR] Shared platform contract not found: $PLATFORM_CONFIG" >&2
    exit 1
fi
# shellcheck source=../config/platform.env
source "$PLATFORM_CONFIG"
NETWORK_LIBRARY="$SCRIPT_DIR/lib/network.sh"
if [[ ! -r "$NETWORK_LIBRARY" ]]; then
    echo "[ERROR] Shared network library not found: $NETWORK_LIBRARY" >&2
    exit 1
fi
# shellcheck source=lib/network.sh
source "$NETWORK_LIBRARY"

API_BASE="${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"
ZONE_NAME="${CLOUDFLARE_ZONE:-$DEFAULT_CLOUDFLARE_ZONE}"
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
ORIGIN_IP="${CLOUDFLARE_ORIGIN_IP:-}"
API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-infra}"
INGRESS_SERVICE="${INGRESS_SERVICE:-ingress-nginx-controller}"
TLS_SECRET_NAME="${CLOUDFLARE_TLS_SECRET_NAME:-swirlit-dev-tls}"
MIN_TLS_VERSION="${CLOUDFLARE_MIN_TLS_VERSION:-1.2}"
ENABLE_HSTS="${CLOUDFLARE_ENABLE_HSTS:-true}"
HSTS_MAX_AGE="${CLOUDFLARE_HSTS_MAX_AGE:-31536000}"
ENABLE_DNSSEC="${CLOUDFLARE_ENABLE_DNSSEC:-true}"
LOCK_ORIGIN="${CLOUDFLARE_LOCK_ORIGIN:-true}"
ENABLE_WAF="${CLOUDFLARE_ENABLE_WAF:-true}"
ENABLE_RATE_LIMIT="${CLOUDFLARE_ENABLE_RATE_LIMIT:-true}"
ENABLE_CACHE_RULES="${CLOUDFLARE_ENABLE_CACHE_RULES:-true}"
ENABLE_REGISTRY_API_COMPATIBILITY="${CLOUDFLARE_ENABLE_REGISTRY_API_COMPATIBILITY:-true}"
ENABLE_ACCESS="${CLOUDFLARE_ENABLE_ACCESS:-true}"
PUBLISH_APEX="${CLOUDFLARE_PUBLISH_APEX:-true}"
ACCESS_ALLOWED_EMAILS="${CLOUDFLARE_ACCESS_ALLOWED_EMAILS:-}"
ACCESS_SESSION_DURATION="${CLOUDFLARE_ACCESS_SESSION_DURATION:-24h}"
ACCESS_TEAM_NAME="${CLOUDFLARE_ACCESS_TEAM_NAME:-}"
INGRESS_CONFIGMAP="${INGRESS_CONFIGMAP:-$INGRESS_SERVICE}"
ORIGIN_LOCK_STATUS="not requested"
REGISTRY_BOT_STATUS="not requested"
WORK_DIR=""
CURL_CONFIG=""

IFS=',' read -r -a DEFAULT_HOST_LABELS <<< "$DEFAULT_CLOUDFLARE_HOST_LABELS"

# Browser-facing administration interfaces belong here. Cluster automation uses
# Kubernetes service DNS and therefore does not need to bypass Access on these
# public hostnames.
IFS=',' read -r -a DEFAULT_ACCESS_HOST_LABELS <<< "$DEFAULT_CLOUDFLARE_ACCESS_HOST_LABELS"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: scripts/configure-cloudflare.sh [options]

Configures a fresh or existing Cloudflare account for the cluster. The script
creates or finds the zone, reconciles proxied DNS records, installs a wildcard
Cloudflare Origin CA certificate in Kubernetes, and applies a secure/performance
baseline, scoped WAF/cache rules, and email-OTP Access for administrative UIs.

Options:
  --zone DOMAIN       Cloudflare zone (default: config/platform.env)
  --account-id ID     Cloudflare account ID; discovered when omitted
  --origin-ip IP      NGINX public IPv4; discovered from Kubernetes when omitted
  -h, --help          Show this help

Secret input:
  The script prompts for a Cloudflare User API Token (current cfut_... type).
  CLOUDFLARE_API_TOKEN may be used for non-interactive automation.

Optional environment variables:
  CLOUDFLARE_HOST_LABELS   Space-separated labels replacing the default list
  CLOUDFLARE_TLS_SECRET_NAME
  CLOUDFLARE_MIN_TLS_VERSION       Default: 1.2
  CLOUDFLARE_ENABLE_HSTS           Default: true
  CLOUDFLARE_HSTS_MAX_AGE          Default: 31536000 seconds
  CLOUDFLARE_ENABLE_DNSSEC         Default: true
  CLOUDFLARE_LOCK_ORIGIN           Allow ports 80/443 only from Cloudflare (default: true)
  CLOUDFLARE_ENABLE_WAF            Default: true
  CLOUDFLARE_ENABLE_RATE_LIMIT     Default: true
  CLOUDFLARE_ENABLE_CACHE_RULES    Default: true
  CLOUDFLARE_ENABLE_REGISTRY_API_COMPATIBILITY
                                      Prevent browser-only bot challenges on the Registry (default: true)
  CLOUDFLARE_ENABLE_ACCESS         Default: true
  CLOUDFLARE_PUBLISH_APEX          Publish the zone apex to its safe dashboard redirect (default: true)
  CLOUDFLARE_ACCESS_ALLOWED_EMAILS Space-separated Access email allowlist
  CLOUDFLARE_ACCESS_SESSION_DURATION  Default: 24h
  CLOUDFLARE_ACCESS_HOST_LABELS    Space-separated admin labels replacing defaults
  CLOUDFLARE_ACCESS_TEAM_NAME      Used only when creating a Zero Trust organization
  INGRESS_NAMESPACE
  INGRESS_SERVICE
  INGRESS_CONFIGMAP
EOF
}

cleanup() {
    API_TOKEN=""
    unset CLOUDFLARE_API_TOKEN || true
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        find "$WORK_DIR" -type f -delete 2>/dev/null || true
        find "$WORK_DIR" -depth -type d -empty -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --zone)
            [[ $# -ge 2 ]] || error "--zone requires a value."
            ZONE_NAME="$2"
            shift 2
            ;;
        --account-id)
            [[ $# -ge 2 ]] || error "--account-id requires a value."
            ACCOUNT_ID="$2"
            shift 2
            ;;
        --origin-ip)
            [[ $# -ge 2 ]] || error "--origin-ip requires a value."
            ORIGIN_IP="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

ZONE_NAME="${ZONE_NAME,,}"
ACCESS_TEAM_NAME="${ACCESS_TEAM_NAME:-bm-cluster-${ZONE_NAME//./-}}"
[[ "$ZONE_NAME" != "${DEFAULT_INTERNAL_DNS_ZONE:-swirlit.internal}" ]] || \
    error "$ZONE_NAME is the cluster-only CoreDNS zone and must never be published through Cloudflare."
[[ "$ZONE_NAME" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || \
    error "Invalid zone name: $ZONE_NAME"
[[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" =~ ^[a-f0-9]{32}$ ]] || \
    error "Cloudflare account IDs must contain 32 lowercase hexadecimal characters."
[[ "$MIN_TLS_VERSION" =~ ^1\.[23]$ ]] || error "CLOUDFLARE_MIN_TLS_VERSION must be 1.2 or 1.3."
[[ "$ENABLE_HSTS" =~ ^(true|false)$ ]] || error "CLOUDFLARE_ENABLE_HSTS must be true or false."
[[ "$ENABLE_DNSSEC" =~ ^(true|false)$ ]] || error "CLOUDFLARE_ENABLE_DNSSEC must be true or false."
[[ "$LOCK_ORIGIN" =~ ^(true|false)$ ]] || error "CLOUDFLARE_LOCK_ORIGIN must be true or false."
[[ "$ENABLE_WAF" =~ ^(true|false)$ ]] || error "CLOUDFLARE_ENABLE_WAF must be true or false."
[[ "$ENABLE_RATE_LIMIT" =~ ^(true|false)$ ]] || error "CLOUDFLARE_ENABLE_RATE_LIMIT must be true or false."
[[ "$ENABLE_CACHE_RULES" =~ ^(true|false)$ ]] || error "CLOUDFLARE_ENABLE_CACHE_RULES must be true or false."
[[ "$ENABLE_REGISTRY_API_COMPATIBILITY" =~ ^(true|false)$ ]] || \
    error "CLOUDFLARE_ENABLE_REGISTRY_API_COMPATIBILITY must be true or false."
[[ "$ENABLE_ACCESS" =~ ^(true|false)$ ]] || error "CLOUDFLARE_ENABLE_ACCESS must be true or false."
[[ "$PUBLISH_APEX" =~ ^(true|false)$ ]] || error "CLOUDFLARE_PUBLISH_APEX must be true or false."
[[ "$HSTS_MAX_AGE" =~ ^[0-9]+$ ]] || error "CLOUDFLARE_HSTS_MAX_AGE must be seconds as a whole number."
[[ "$ACCESS_SESSION_DURATION" =~ ^[1-9][0-9]*(m|h)$ ]] || \
    error "CLOUDFLARE_ACCESS_SESSION_DURATION must be a positive duration such as 30m or 24h."
[[ "$ACCESS_TEAM_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
    error "CLOUDFLARE_ACCESS_TEAM_NAME must contain lowercase letters, numbers, and hyphens."

for command_name in curl jq openssl kubectl base64; do
    command -v "$command_name" >/dev/null 2>&1 || error "Required command not found: $command_name"
done
kubectl cluster-info >/dev/null 2>&1 || error "Cannot reach the Kubernetes cluster."

if [[ -z "$API_TOKEN" ]]; then
    cat >&2 <<'EOF'

Cloudflare credential required:
  Type: Cloudflare User API Token (current cfut_... format)
  Do not use: Account API Token (cfat_...) or Global API Key (cfk_...)

The custom user token must allow:
  User    -> Memberships              -> Read
  Zone    -> Zone                     -> Read
  Zone    -> Zone                     -> Edit
  Zone    -> DNS                      -> Edit
  Zone    -> Zone Settings            -> Edit
  Zone    -> SSL and Certificates     -> Edit
  Zone    -> WAF                      -> Edit
  Zone    -> Cache Rules              -> Edit
  Zone    -> Bot Management           -> Read
  Zone    -> Bot Management           -> Edit
  Account -> Access: Apps and Policies -> Edit
  Account -> Access: Organizations, Identity Providers, and Groups -> Edit

For a blank account, scope the zone permissions to all zones in the selected
account; a token restricted to a specific existing zone cannot create the zone.
EOF
    read -rsp "Cloudflare User API Token (cfut_...): " API_TOKEN
    echo >&2
fi

case "$API_TOKEN" in
    cfut_*) ;;
    cfat_*) error "An Account API Token (cfat_...) was supplied; a User API Token (cfut_...) is required." ;;
    cfk_*)  error "A Global API Key (cfk_...) was supplied; a scoped User API Token (cfut_...) is required." ;;
    *)      error "Expected a current Cloudflare User API Token beginning with cfut_." ;;
esac

if [[ "$ENABLE_ACCESS" == "true" && -z "$ACCESS_ALLOWED_EMAILS" ]]; then
    read -rp "Email address(es) allowed into BM Cluster admin UIs (space-separated): " ACCESS_ALLOWED_EMAILS
fi
if [[ "$ENABLE_ACCESS" == "true" ]]; then
    read -r -a ACCESS_EMAILS <<< "$ACCESS_ALLOWED_EMAILS"
    (( ${#ACCESS_EMAILS[@]} > 0 )) || error "At least one Access email address is required."
    for access_email in "${ACCESS_EMAILS[@]}"; do
        [[ "$access_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || \
            error "Invalid Access email address: $access_email"
    done
fi

WORK_DIR="$(mktemp -d /tmp/bm-cloudflare.XXXXXX)"
CURL_CONFIG="$WORK_DIR/curl.conf"
printf 'silent\nshow-error\nheader = "Authorization: Bearer %s"\n' "$API_TOKEN" > "$CURL_CONFIG"
chmod 600 "$CURL_CONFIG"

cf_request() {
    local method="$1"
    local path="$2"
    local data_file="${3:-}"
    local curl_args=(
        --config "$CURL_CONFIG"
        --request "$method"
        --url "$API_BASE$path"
        --header "Content-Type: application/json"
    )

    if [[ -n "$data_file" ]]; then
        curl_args+=(--data-binary "@$data_file")
    fi

    curl "${curl_args[@]}"
}

require_success() {
    local response="$1"
    local operation="$2"

    if ! jq -e '.success == true' <<< "$response" >/dev/null 2>&1; then
        local details
        details="$(jq -r '[.errors[]?.message, .messages[]?.message] | map(select(. != null and . != "")) | join("; ")' <<< "$response" 2>/dev/null || true)"
        error "$operation failed${details:+: $details}"
    fi
}

set_zone_setting() {
    local setting_id="$1"
    local desired_value="$2"
    local description="$3"
    local setting_file response current_value

    response="$(cf_request GET "/zones/$ZONE_ID/settings/$setting_id")"
    require_success "$response" "Reading $description"
    current_value="$(jq -c '.result.value' <<< "$response")"
    if [[ "$current_value" == "$(jq -cn --arg value "$desired_value" '$value')" ]]; then
        info "$description already set to $desired_value."
        return 0
    fi

    setting_file="$WORK_DIR/setting-$setting_id.json"
    jq -n --arg value "$desired_value" '{value:$value}' > "$setting_file"
    response="$(cf_request PATCH "/zones/$ZONE_ID/settings/$setting_id" "$setting_file")"
    require_success "$response" "Setting $description"
    info "Set $description to $desired_value."
}

reconcile_ruleset_rule() {
    local phase="$1"
    local ruleset_name="$2"
    local rule_description="$3"
    local desired_rule_file="$4"
    local ruleset_response ruleset_id rule_count rule_id update_response
    local create_file current_fingerprint desired_fingerprint

    ruleset_response="$(cf_request GET "/zones/$ZONE_ID/rulesets/phases/$phase/entrypoint")"
    if jq -e '.success == true' <<< "$ruleset_response" >/dev/null 2>&1; then
        ruleset_id="$(jq -r '.result.id' <<< "$ruleset_response")"
    elif jq -e 'any(.errors[]?; .code == 10003)' <<< "$ruleset_response" >/dev/null 2>&1; then
        create_file="$WORK_DIR/ruleset-create-${phase}.json"
        jq -n \
            --arg name "$ruleset_name" \
            --arg phase "$phase" \
            --slurpfile rule "$desired_rule_file" \
            '{name:$name,kind:"zone",phase:$phase,rules:$rule}' > "$create_file"
        update_response="$(cf_request POST "/zones/$ZONE_ID/rulesets" "$create_file")"
        require_success "$update_response" "Creating $ruleset_name"
        info "Created Cloudflare rule: $rule_description"
        return 0
    else
        require_success "$ruleset_response" "Reading $ruleset_name"
    fi

    rule_count="$(jq --arg description "$rule_description" \
        '[.result.rules[]? | select(.description == $description)] | length' <<< "$ruleset_response")"
    ((rule_count <= 1)) || error "More than one Cloudflare rule is named: $rule_description"

    if ((rule_count == 0)); then
        update_response="$(cf_request POST "/zones/$ZONE_ID/rulesets/$ruleset_id/rules" "$desired_rule_file")"
        require_success "$update_response" "Creating Cloudflare rule: $rule_description"
        info "Created Cloudflare rule: $rule_description"
        return 0
    fi

    rule_id="$(jq -r --arg description "$rule_description" \
        '.result.rules[] | select(.description == $description) | .id' <<< "$ruleset_response")"
    current_fingerprint="$(jq -Sc --arg description "$rule_description" \
        '.result.rules[] | select(.description == $description) |
         {action,action_parameters,description,enabled,expression,ratelimit} |
         with_entries(select(.value != null))' <<< "$ruleset_response")"
    desired_fingerprint="$(jq -Sc \
        '{action,action_parameters,description,enabled,expression,ratelimit} |
         with_entries(select(.value != null))' "$desired_rule_file")"
    if [[ "$current_fingerprint" == "$desired_fingerprint" ]]; then
        info "Cloudflare rule already correct: $rule_description"
        return 0
    fi

    update_response="$(cf_request PATCH "/zones/$ZONE_ID/rulesets/$ruleset_id/rules/$rule_id" "$desired_rule_file")"
    require_success "$update_response" "Updating Cloudflare rule: $rule_description"
    info "Updated Cloudflare rule: $rule_description"
}

configure_registry_bot_compatibility() {
    local registry_host="${DEFAULT_K3S_REGISTRY_HOST:-registry.$ZONE_NAME}"
    local registry_is_published=false
    local bot_response bot_setting_file update_response
    local fight_mode=false
    local sbfm_active=false
    local skip_rule_file skip_expression
    local fqdn

    if [[ "$ENABLE_REGISTRY_API_COMPATIBILITY" != "true" ]]; then
        REGISTRY_BOT_STATUS="left unchanged"
        warn "Registry bot compatibility reconciliation is disabled."
        return 0
    fi

    for fqdn in "${DNS_HOSTS[@]}"; do
        if [[ "$fqdn" == "$registry_host" ]]; then
            registry_is_published=true
            break
        fi
    done
    if [[ "$registry_is_published" != "true" ]]; then
        REGISTRY_BOT_STATUS="not applicable"
        return 0
    fi

    step "Reconciling Cloudflare bot protection for Registry API clients"
    bot_response="$(cf_request GET "/zones/$ZONE_ID/bot_management")"
    if ! jq -e '.success == true' <<< "$bot_response" >/dev/null 2>&1; then
        if jq -e 'any(.errors[]?; .code == 10000)' <<< "$bot_response" >/dev/null 2>&1; then
            error "Reading Bot Management failed. Add Zone -> Bot Management -> Read and Edit to the Cloudflare token; Docker clients cannot complete browser challenges."
        fi
        require_success "$bot_response" "Reading Bot Management configuration"
    fi

    fight_mode="$(jq -r '(.result.fight_mode // .result.stale_zone_configuration.fight_mode // false)' <<< "$bot_response")"
    if [[ "$fight_mode" == "true" ]]; then
        # Basic Bot Fight Mode is zone-wide and cannot be skipped by hostname.
        # Cloudflare's DDoS protection, custom WAF, and rate limits stay enabled.
        bot_setting_file="$WORK_DIR/registry-bot-management.json"
        jq -n '{fight_mode:false}' > "$bot_setting_file"
        update_response="$(cf_request PUT "/zones/$ZONE_ID/bot_management" "$bot_setting_file")"
        require_success "$update_response" "Disabling basic Bot Fight Mode for Registry API compatibility"
        info "Disabled basic Bot Fight Mode; it cannot exempt Docker Registry clients by hostname."
    fi

    if jq -e '.result |
        ((.sbfm_definitely_automated? // "allow") != "allow") or
        ((.sbfm_likely_automated? // "allow") != "allow") or
        ((.sbfm_verified_bots? // "allow") != "allow") or
        (.sbfm_static_resource_protection? == true)' <<< "$bot_response" >/dev/null; then
        sbfm_active=true
    fi

    if [[ "$sbfm_active" == "true" ]]; then
        # Super Bot Fight Mode is Ruleset Engine based, so it supports a precise
        # hostname exception without weakening protection on browser services.
        skip_rule_file="$WORK_DIR/rule-registry-sbfm-skip.json"
        skip_expression="(http.host eq \"$registry_host\")"
        jq -n \
            --arg expression "$skip_expression" \
            '{
                action:"skip",
                action_parameters:{phases:["http_request_sbfm"]},
                description:"bm-cluster: allow non-browser Registry clients",
                enabled:true,
                expression:$expression,
                logging:{enabled:true}
            }' > "$skip_rule_file"
        reconcile_ruleset_rule \
            http_request_firewall_custom \
            "BM Cluster custom firewall rules" \
            "bm-cluster: allow non-browser Registry clients" \
            "$skip_rule_file"
        REGISTRY_BOT_STATUS="Super Bot Fight Mode skipped for $registry_host"
    elif [[ "$fight_mode" == "true" ]]; then
        REGISTRY_BOT_STATUS="basic Bot Fight Mode disabled"
    else
        REGISTRY_BOT_STATUS="compatible"
        info "Cloudflare bot protection already permits non-browser Registry clients."
    fi

    bot_response="$(cf_request GET "/zones/$ZONE_ID/bot_management")"
    require_success "$bot_response" "Verifying Bot Management configuration"
    jq -e '(.result.fight_mode // .result.stale_zone_configuration.fight_mode // false) == false' \
        <<< "$bot_response" >/dev/null || error "Basic Bot Fight Mode still challenges Registry API clients."
}

configure_edge_rules() {
    local host_set=""
    local fqdn host_literal waf_expression cache_expression
    local rule_file

    for fqdn in "${DNS_HOSTS[@]}"; do
        printf -v host_literal '"%s"' "$fqdn"
        host_set+="${host_set:+ }$host_literal"
    done

    if [[ "$ENABLE_WAF" == "true" ]]; then
        step "Reconciling the BM Cluster custom WAF rule"
        waf_expression="(http.host in {$host_set} and ((http.request.method in {\"TRACE\" \"TRACK\"}) or (http.request.uri.path in {\"/.env\" \"/.git/config\" \"/.git/HEAD\" \"/wp-login.php\" \"/xmlrpc.php\" \"/server-status\" \"/actuator/env\" \"/actuator/heapdump\" \"/actuator/configprops\"}) or starts_with(http.request.uri.path, \"/phpmyadmin\") or starts_with(http.request.uri.path, \"/vendor/phpunit/\")))"
        rule_file="$WORK_DIR/rule-waf.json"
        jq -n \
            --arg expression "$waf_expression" \
            '{action:"block",description:"bm-cluster: block unsafe methods and scanner targets",enabled:true,expression:$expression}' \
            > "$rule_file"
        reconcile_ruleset_rule \
            http_request_firewall_custom \
            "BM Cluster custom firewall rules" \
            "bm-cluster: block unsafe methods and scanner targets" \
            "$rule_file"
    fi

    if [[ "$ENABLE_RATE_LIMIT" == "true" ]]; then
        step "Reconciling the BM Cluster login rate limit"
        rule_file="$WORK_DIR/rule-rate-limit.json"
        jq -n '{
            action:"block",
            description:"bm-cluster: rate limit interactive login endpoints",
            enabled:true,
            expression:"(http.request.uri.path in {\"/web/login\" \"/users/sign_in\"})",
            ratelimit:{
                characteristics:["cf.colo.id","ip.src"],
                period:10,
                requests_per_period:20,
                mitigation_timeout:10
            }
        }' > "$rule_file"
        reconcile_ruleset_rule \
            http_ratelimit \
            "BM Cluster rate limiting rules" \
            "bm-cluster: rate limit interactive login endpoints" \
            "$rule_file"
    fi

    if [[ "$ENABLE_CACHE_RULES" == "true" ]]; then
        step "Reconciling the BM Cluster private-response cache bypass"
        cache_expression="(http.host in {$host_set} and ((any(http.request.headers[\"authorization\"][*] ne \"\")) or starts_with(http.request.uri.path, \"/api/\") or starts_with(http.request.uri.path, \"/auth/\") or starts_with(http.request.uri.path, \"/oauth\") or starts_with(http.request.uri.path, \"/realms/\") or starts_with(http.request.uri.path, \"/admin/\") or starts_with(http.request.uri.path, \"/websocket\") or starts_with(http.request.uri.path, \"/socket.io/\") or (http.request.uri.path in {\"/login\" \"/web/login\" \"/users/sign_in\"})))"
        rule_file="$WORK_DIR/rule-cache.json"
        jq -n \
            --arg expression "$cache_expression" \
            '{action:"set_cache_settings",action_parameters:{cache:false},description:"bm-cluster: bypass cache for private and authenticated traffic",enabled:true,expression:$expression}' \
            > "$rule_file"
        reconcile_ruleset_rule \
            http_request_cache_settings \
            "BM Cluster cache rules" \
            "bm-cluster: bypass cache for private and authenticated traffic" \
            "$rule_file"
    fi
}

access_app_name() {
    case "$1" in
        argocd) echo "Argo CD" ;;
        dbgate) echo "DBGate" ;;
        grafana) echo "Grafana" ;;
        kafka) echo "Kafka UI" ;;
        kibana) echo "Kibana" ;;
        longhorn) echo "Longhorn" ;;
        portainer) echo "Portainer" ;;
        sonarqube) echo "SonarQube" ;;
        vault) echo "Vault" ;;
        *) echo "$1" ;;
    esac
}

configure_access() {
    local organization_response organization_file idp_response idp_count otp_idp_id
    local idp_file policy_response policy_count policy_id policy_file update_response
    local access_emails_json app_response app_count app_id app_file app_name fqdn label retired_label
    local current_fingerprint desired_fingerprint
    local configured_labels=" ${HOST_LABELS[*]} "

    [[ "$ENABLE_ACCESS" == "true" ]] || return 0
    step "Reconciling Zero Trust Access for BM Cluster admin interfaces"

    organization_response="$(cf_request GET "/accounts/$ACCOUNT_ID/access/organizations")"
    if ! jq -e '.success == true' <<< "$organization_response" >/dev/null 2>&1; then
        organization_file="$WORK_DIR/access-organization.json"
        jq -n \
            --arg name "BM Cluster" \
            --arg auth_domain "$ACCESS_TEAM_NAME.cloudflareaccess.com" \
            '{name:$name,auth_domain:$auth_domain,auto_redirect_to_identity:true,deny_unmatched_requests:false}' \
            > "$organization_file"
        organization_response="$(cf_request POST "/accounts/$ACCOUNT_ID/access/organizations" "$organization_file")"
        require_success "$organization_response" "Creating the Cloudflare Zero Trust organization (set CLOUDFLARE_ACCESS_TEAM_NAME if its name is unavailable)"
        info "Created the Cloudflare Zero Trust organization."
    else
        info "Using the existing Cloudflare Zero Trust organization without changing its account-wide settings."
    fi

    idp_response="$(cf_request GET "/accounts/$ACCOUNT_ID/access/identity_providers")"
    require_success "$idp_response" "Reading Access identity providers"
    idp_count="$(jq '[.result[] | select(.type == "onetimepin")] | length' <<< "$idp_response")"
    if ((idp_count == 0)); then
        idp_file="$WORK_DIR/access-otp-idp.json"
        printf '{"name":"BM Cluster one-time PIN","type":"onetimepin","config":{}}\n' > "$idp_file"
        update_response="$(cf_request POST "/accounts/$ACCOUNT_ID/access/identity_providers" "$idp_file")"
        require_success "$update_response" "Creating the Access one-time PIN identity provider"
        otp_idp_id="$(jq -r '.result.id' <<< "$update_response")"
        info "Created the one-time PIN identity provider."
    else
        otp_idp_id="$(jq -r '[.result[] | select(.type == "onetimepin")][0].id' <<< "$idp_response")"
        info "Using the existing one-time PIN identity provider."
    fi

    access_emails_json="$(printf '%s\n' "${ACCESS_EMAILS[@]}" | jq -R . | jq -s .)"
    policy_file="$WORK_DIR/access-policy.json"
    jq -n \
        --arg name "BM Cluster administrators" \
        --arg duration "$ACCESS_SESSION_DURATION" \
        --arg idp_id "$otp_idp_id" \
        --argjson emails "$access_emails_json" \
        '{
            name:$name,
            decision:"allow",
            session_duration:$duration,
            include:($emails | map({email:{email:.}})),
            exclude:[],
            require:[{login_method:{id:$idp_id}}]
        }' > "$policy_file"

    policy_response="$(cf_request GET "/accounts/$ACCOUNT_ID/access/policies?per_page=100")"
    require_success "$policy_response" "Reading reusable Access policies"
    policy_count="$(jq '[.result[] | select(.name == "BM Cluster administrators" and .reusable == true)] | length' <<< "$policy_response")"
    ((policy_count <= 1)) || error "More than one reusable Access policy is named BM Cluster administrators."
    if ((policy_count == 0)); then
        update_response="$(cf_request POST "/accounts/$ACCOUNT_ID/access/policies" "$policy_file")"
        require_success "$update_response" "Creating the BM Cluster Access policy"
        policy_id="$(jq -r '.result.id' <<< "$update_response")"
        info "Created the BM Cluster email allowlist policy."
    else
        policy_id="$(jq -r '.result[] | select(.name == "BM Cluster administrators" and .reusable == true) | .id' <<< "$policy_response")"
        current_fingerprint="$(jq -Sc \
            '.result[] | select(.name == "BM Cluster administrators" and .reusable == true) |
             {name,decision,session_duration,include,exclude,require}' <<< "$policy_response")"
        desired_fingerprint="$(jq -Sc \
            '{name,decision,session_duration,include,exclude,require}' "$policy_file")"
        if [[ "$current_fingerprint" == "$desired_fingerprint" ]]; then
            info "The BM Cluster email allowlist policy is already correct."
        else
            update_response="$(cf_request PUT "/accounts/$ACCOUNT_ID/access/policies/$policy_id" "$policy_file")"
            require_success "$update_response" "Updating the BM Cluster Access policy"
            info "Reconciled the BM Cluster email allowlist policy."
        fi
    fi

    if [[ -n "${CLOUDFLARE_ACCESS_HOST_LABELS:-}" ]]; then
        read -r -a ACCESS_HOST_LABELS <<< "$CLOUDFLARE_ACCESS_HOST_LABELS"
    else
        ACCESS_HOST_LABELS=("${DEFAULT_ACCESS_HOST_LABELS[@]}")
    fi
    (( ${#ACCESS_HOST_LABELS[@]} > 0 )) || error "At least one Access hostname label is required."

    for label in "${ACCESS_HOST_LABELS[@]}"; do
        [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || error "Invalid Access hostname label: $label"
        [[ "$configured_labels" == *" $label "* ]] || error "Access hostname $label is not present in CLOUDFLARE_HOST_LABELS."
        fqdn="$label.$ZONE_NAME"
        app_name="BM Cluster - $(access_app_name "$label")"
        app_file="$WORK_DIR/access-app-$label.json"
        jq -n \
            --arg name "$app_name" \
            --arg domain "$fqdn" \
            --arg duration "$ACCESS_SESSION_DURATION" \
            --arg idp_id "$otp_idp_id" \
            --arg policy_id "$policy_id" \
            '{
                name:$name,
                domain:$domain,
                type:"self_hosted",
                session_duration:$duration,
                app_launcher_visible:true,
                allowed_idps:[$idp_id],
                auto_redirect_to_identity:true,
                http_only_cookie_attribute:true,
                policies:[{id:$policy_id,precedence:1}]
            }' > "$app_file"

        app_response="$(cf_request GET "/accounts/$ACCOUNT_ID/access/apps?per_page=100")"
        require_success "$app_response" "Reading Access applications"
        app_count="$(jq --arg domain "$fqdn" '[.result[] | select(.domain == $domain and .type == "self_hosted")] | length' <<< "$app_response")"
        ((app_count <= 1)) || error "More than one Access application targets $fqdn."
        if ((app_count == 0)); then
            update_response="$(cf_request POST "/accounts/$ACCOUNT_ID/access/apps" "$app_file")"
            require_success "$update_response" "Creating the Access application for $fqdn"
            info "Protected $fqdn with email OTP Access."
        else
            app_id="$(jq -r --arg domain "$fqdn" '.result[] | select(.domain == $domain and .type == "self_hosted") | .id' <<< "$app_response")"
            current_fingerprint="$(jq -Sc --arg domain "$fqdn" \
                '.result[] | select(.domain == $domain and .type == "self_hosted") |
                 {name,domain,type,session_duration,app_launcher_visible,allowed_idps,
                  auto_redirect_to_identity,http_only_cookie_attribute,
                  policies:(.policies | map({id,precedence}))}' <<< "$app_response")"
            desired_fingerprint="$(jq -Sc \
                '{name,domain,type,session_duration,app_launcher_visible,allowed_idps,
                 auto_redirect_to_identity,http_only_cookie_attribute,policies}' "$app_file")"
            if [[ "$current_fingerprint" == "$desired_fingerprint" ]]; then
                info "Access protection is already correct for $fqdn."
            else
                update_response="$(cf_request PUT "/accounts/$ACCOUNT_ID/access/apps/$app_id" "$app_file")"
                require_success "$update_response" "Updating the Access application for $fqdn"
                info "Reconciled Access protection for $fqdn."
            fi
        fi
    done

    for retired_label in "${RETIRED_HOST_LABELS[@]}"; do
        fqdn="$retired_label.$ZONE_NAME"
        app_response="$(cf_request GET "/accounts/$ACCOUNT_ID/access/apps?per_page=100")"
        require_success "$app_response" "Reading retired Access applications"
        mapfile -t retired_app_ids < <(
            jq -r --arg domain "$fqdn" \
                '.result[] | select(.domain == $domain and .type == "self_hosted") | .id' \
                <<< "$app_response"
        )
        for app_id in "${retired_app_ids[@]}"; do
            update_response="$(cf_request DELETE "/accounts/$ACCOUNT_ID/access/apps/$app_id")"
            require_success "$update_response" "Deleting the retired Access application for $fqdn"
            info "Deleted the retired Access application for $fqdn."
        done
    done
}

append_unique_namespace() {
    local candidate="$1"
    local existing

    [[ -n "$candidate" ]] || return 0
    for existing in "${TLS_NAMESPACES[@]}"; do
        [[ "$existing" == "$candidate" ]] && return 0
    done
    TLS_NAMESPACES+=("$candidate")
}

configure_ingress_proxy_trust() {
    local cidr_csv="$1"
    local current_data desired_data

    if ! kubectl get configmap "$INGRESS_CONFIGMAP" -n "$INGRESS_NAMESPACE" >/dev/null 2>&1; then
        warn "Ingress ConfigMap $INGRESS_NAMESPACE/$INGRESS_CONFIGMAP was not found; skipping Cloudflare client-IP trust configuration."
        return 0
    fi

    desired_data="$(jq -n --arg cidrs "$cidr_csv" '{
        "enable-real-ip":"true",
        "forwarded-for-header":"CF-Connecting-IP",
        "proxy-real-ip-cidr":$cidrs,
        "use-forwarded-headers":"true",
        "ssl-protocols":"TLSv1.2 TLSv1.3",
        "server-tokens":"false"
    }')"
    current_data="$(kubectl get configmap "$INGRESS_CONFIGMAP" -n "$INGRESS_NAMESPACE" -o json | jq -c '.data // {}')"
    if jq -ne --argjson current "$current_data" --argjson desired "$desired_data" \
        '$desired | to_entries | all(. as $entry | $current[$entry.key] == $entry.value)' >/dev/null; then
        info "Ingress already trusts only Cloudflare proxy ranges for client IP headers."
        return 0
    fi

    kubectl patch configmap "$INGRESS_CONFIGMAP" -n "$INGRESS_NAMESPACE" --type merge \
        -p "$(jq -cn --argjson data "$desired_data" '{data:$data}')" >/dev/null
    info "Configured ingress to trust CF-Connecting-IP only from Cloudflare proxy ranges."
}

lock_origin_firewall() {
    local cidr
    local previous_cidr
    local sudo_command=()

    if [[ "$LOCK_ORIGIN" != "true" ]]; then
        ORIGIN_LOCK_STATUS="left unchanged"
        warn "Origin firewall locking is disabled by CLOUDFLARE_LOCK_ORIGIN=false."
        return 0
    fi
    if ! command -v ufw >/dev/null 2>&1; then
        ORIGIN_LOCK_STATUS="provider firewall required"
        warn "UFW is not installed; restrict origin ports 80/443 to Cloudflare networks in the provider firewall."
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        if ! command -v sudo >/dev/null 2>&1; then
            ORIGIN_LOCK_STATUS="provider firewall required"
            warn "sudo is unavailable; restrict origin ports 80/443 to Cloudflare networks in the provider firewall."
            return 0
        fi
        sudo_command=(sudo)
    fi
    if ! "${sudo_command[@]}" ufw status | grep -q '^Status: active'; then
        ORIGIN_LOCK_STATUS="provider firewall required"
        warn "UFW is inactive; restrict origin ports 80/443 to Cloudflare networks in the provider firewall."
        return 0
    fi

    step "Restricting the origin web ports to Cloudflare proxies"
    for cidr in "${CLOUDFLARE_PROXY_CIDRS[@]}"; do
        "${sudo_command[@]}" ufw allow from "$cidr" to any port 80 proto tcp comment 'Cloudflare proxy' >/dev/null
        "${sudo_command[@]}" ufw allow from "$cidr" to any port 443 proto tcp comment 'Cloudflare proxy' >/dev/null
    done
    if "${sudo_command[@]}" test -f /etc/bm-cluster/cloudflare-proxy-only; then
        while IFS= read -r previous_cidr; do
            [[ "$previous_cidr" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] || continue
            if [[ ",${cloudflare_proxy_cidr_csv}," != *",${previous_cidr},"* ]]; then
                "${sudo_command[@]}" ufw --force delete allow from "$previous_cidr" to any port 80 proto tcp >/dev/null 2>&1 || true
                "${sudo_command[@]}" ufw --force delete allow from "$previous_cidr" to any port 443 proto tcp >/dev/null 2>&1 || true
            fi
        done < <("${sudo_command[@]}" cat /etc/bm-cluster/cloudflare-proxy-only)
    fi
    "${sudo_command[@]}" ufw --force delete allow 80/tcp >/dev/null 2>&1 || true
    "${sudo_command[@]}" ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
    "${sudo_command[@]}" ufw --force delete allow 'Nginx Full' >/dev/null 2>&1 || true
    "${sudo_command[@]}" install -d -m 0755 /etc/bm-cluster
    printf '%s\n' '# Managed by bm-cluster: web ingress is restricted to these Cloudflare proxy networks.' "${CLOUDFLARE_PROXY_CIDRS[@]}" | \
        "${sudo_command[@]}" tee /etc/bm-cluster/cloudflare-proxy-only >/dev/null
    ORIGIN_LOCK_STATUS="Cloudflare proxy networks only"
    info "Direct Internet access to origin ports 80/443 is now blocked."
}

certificate_is_usable() {
    local cert_file="$1"
    local key_file="$2"
    local cert_public_key key_public_key san issuer

    [[ -s "$cert_file" && -s "$key_file" ]] || return 1
    openssl x509 -in "$cert_file" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
    issuer="$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null)"
    [[ "$issuer" == *"CloudFlare Origin SSL Certificate Authority"* ]] || return 1
    san="$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null)"
    grep -Fq "DNS:*.$ZONE_NAME" <<< "$san" || return 1
    grep -Fq "DNS:$ZONE_NAME" <<< "$san" || return 1
    cert_public_key="$(openssl x509 -in "$cert_file" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256)"
    key_public_key="$(openssl pkey -in "$key_file" -pubout -outform DER 2>/dev/null | openssl sha256)"
    [[ -n "$cert_public_key" && "$cert_public_key" == "$key_public_key" ]]
}

step "Validating the Cloudflare User API Token"
token_response="$(cf_request GET /user/tokens/verify)"
require_success "$token_response" "Token verification"
[[ "$(jq -r '.result.status' <<< "$token_response")" == "active" ]] || error "The Cloudflare token is not active."

step "Finding or creating the Cloudflare zone"
zone_response="$(cf_request GET "/zones?name=$ZONE_NAME&per_page=50")"
require_success "$zone_response" "Zone lookup"
zone_count="$(jq '.result | length' <<< "$zone_response")"
((zone_count <= 1)) || error "More than one accessible zone named $ZONE_NAME was returned."

if ((zone_count == 1)); then
    ZONE_ID="$(jq -r '.result[0].id' <<< "$zone_response")"
    ACCOUNT_ID="$(jq -r '.result[0].account.id' <<< "$zone_response")"
    ZONE_STATUS="$(jq -r '.result[0].status' <<< "$zone_response")"
    mapfile -t ZONE_NAMESERVERS < <(jq -r '.result[0].name_servers[]?' <<< "$zone_response")
    info "Using existing zone $ZONE_NAME."
else
    if [[ -z "$ACCOUNT_ID" ]]; then
        membership_response="$(cf_request GET '/memberships?status=accepted&per_page=50')"
        require_success "$membership_response" "Account membership lookup (the token needs User -> Memberships -> Read)"
        membership_count="$(jq '.result | length' <<< "$membership_response")"
        ((membership_count > 0)) || error "No accessible Cloudflare accounts were returned."

        if ((membership_count == 1)); then
            ACCOUNT_ID="$(jq -r '.result[0].account.id' <<< "$membership_response")"
            info "Using Cloudflare account: $(jq -r '.result[0].account.name' <<< "$membership_response")"
        else
            echo "Accessible Cloudflare accounts:" >&2
            jq -r '.result[] | "  \(.account.id)  \(.account.name)"' <<< "$membership_response" >&2
            read -rp "Cloudflare account ID for $ZONE_NAME: " ACCOUNT_ID
            [[ "$ACCOUNT_ID" =~ ^[a-f0-9]{32}$ ]] || error "Invalid Cloudflare account ID."
            jq -e --arg id "$ACCOUNT_ID" 'any(.result[]; .account.id == $id)' <<< "$membership_response" >/dev/null || \
                error "The selected account ID was not returned by the token."
        fi
    fi

    zone_create_file="$WORK_DIR/zone-create.json"
    jq -n --arg account_id "$ACCOUNT_ID" --arg name "$ZONE_NAME" \
        '{account:{id:$account_id},name:$name,type:"full"}' > "$zone_create_file"
    zone_response="$(cf_request POST /zones "$zone_create_file")"
    require_success "$zone_response" "Zone creation"
    ZONE_ID="$(jq -r '.result.id' <<< "$zone_response")"
    ZONE_STATUS="$(jq -r '.result.status' <<< "$zone_response")"
    mapfile -t ZONE_NAMESERVERS < <(jq -r '.result.name_servers[]?' <<< "$zone_response")
    info "Created zone $ZONE_NAME."
fi

if [[ "$ZONE_STATUS" != "active" ]]; then
    warn "Cloudflare zone $ZONE_NAME is $ZONE_STATUS."
    warn "Delegate the domain at its registrar to these Cloudflare nameservers:"
    for nameserver in "${ZONE_NAMESERVERS[@]}"; do
        echo "  - $nameserver" >&2
    done
    warn "The script will prepare the pending zone now; rerun it after delegation to confirm activation."
fi

if [[ -z "$ORIGIN_IP" ]]; then
    ORIGIN_IP="$(kubectl get service "$INGRESS_SERVICE" -n "$INGRESS_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
fi
valid_ipv4 "$ORIGIN_IP" || error "Could not discover a valid public IPv4 for $INGRESS_NAMESPACE/$INGRESS_SERVICE; use --origin-ip."
info "Using NGINX origin IP: $ORIGIN_IP"

proxy_ip_response="$(cf_request GET /ips)"
require_success "$proxy_ip_response" "Reading Cloudflare proxy networks"
mapfile -t CLOUDFLARE_PROXY_CIDRS < <(jq -r '.result.ipv4_cidrs[], .result.ipv6_cidrs[]' <<< "$proxy_ip_response")
(( ${#CLOUDFLARE_PROXY_CIDRS[@]} > 0 )) || error "Cloudflare returned no proxy networks."
cloudflare_proxy_cidr_csv="$(IFS=,; echo "${CLOUDFLARE_PROXY_CIDRS[*]}")"
configure_ingress_proxy_trust "$cloudflare_proxy_cidr_csv"

if [[ -n "${CLOUDFLARE_HOST_LABELS:-}" ]]; then
    read -r -a HOST_LABELS <<< "$CLOUDFLARE_HOST_LABELS"
else
    HOST_LABELS=("${DEFAULT_HOST_LABELS[@]}")
fi
(( ${#HOST_LABELS[@]} > 0 )) || error "At least one public hostname is required."
IFS=',' read -r -a RETIRED_HOST_LABELS <<< "${CLOUDFLARE_RETIRED_HOST_LABELS:-${DEFAULT_CLOUDFLARE_RETIRED_HOST_LABELS:-}}"

configured_host_labels=" $(printf '%s ' "${HOST_LABELS[@]}")"
for retired_label in "${RETIRED_HOST_LABELS[@]}"; do
    [[ -n "$retired_label" ]] || continue
    [[ "$retired_label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
        error "Invalid retired hostname label: $retired_label"
    [[ "$configured_host_labels" != *" $retired_label "* ]] || \
        error "Retired hostname $retired_label is also present in CLOUDFLARE_HOST_LABELS."
done

DNS_HOSTS=()
if [[ "$PUBLISH_APEX" == "true" ]]; then
    DNS_HOSTS+=("$ZONE_NAME")
fi
for label in "${HOST_LABELS[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || error "Invalid hostname label: $label"
    DNS_HOSTS+=("$label.$ZONE_NAME")
done

step "Reconciling proxied DNS records"
for retired_label in "${RETIRED_HOST_LABELS[@]}"; do
    [[ -n "$retired_label" ]] || continue
    fqdn="$retired_label.$ZONE_NAME"
    record_response="$(cf_request GET "/zones/$ZONE_ID/dns_records?name=$fqdn&per_page=100")"
    require_success "$record_response" "DNS lookup for retired hostname $fqdn"
    mapfile -t retired_record_ids < <(
        jq -r '.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME") | .id' \
            <<< "$record_response"
    )
    for record_id in "${retired_record_ids[@]}"; do
        update_response="$(cf_request DELETE "/zones/$ZONE_ID/dns_records/$record_id")"
        require_success "$update_response" "Deleting retired DNS record $fqdn"
        info "Deleted retired DNS record $fqdn."
    done
done

for fqdn in "${DNS_HOSTS[@]}"; do
    record_response="$(cf_request GET "/zones/$ZONE_ID/dns_records?name=$fqdn&per_page=100")"
    require_success "$record_response" "DNS lookup for $fqdn"
    address_record_count="$(jq '[.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME")] | length' <<< "$record_response")"
    ((address_record_count <= 1)) || error "$fqdn has multiple A/AAAA/CNAME records; reconcile the conflict before rerunning."

    desired_record_file="$WORK_DIR/dns-${fqdn//./-}.json"
    jq -n --arg name "$fqdn" --arg content "$ORIGIN_IP" \
        '{type:"A",name:$name,content:$content,ttl:1,proxied:true,comment:"Managed by bm-cluster/scripts/configure-cloudflare.sh"}' \
        > "$desired_record_file"

    if ((address_record_count == 0)); then
        update_response="$(cf_request POST "/zones/$ZONE_ID/dns_records" "$desired_record_file")"
        require_success "$update_response" "Creating DNS record $fqdn"
        info "Created $fqdn -> $ORIGIN_IP (proxied)."
        continue
    fi

    current_record="$(jq -c '[.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME")][0]' <<< "$record_response")"
    if jq -e --arg content "$ORIGIN_IP" \
        '.type == "A" and .content == $content and .proxied == true and .ttl == 1' \
        <<< "$current_record" >/dev/null; then
        info "DNS record already correct: $fqdn"
        continue
    fi

    record_id="$(jq -r '.id' <<< "$current_record")"
    update_response="$(cf_request PUT "/zones/$ZONE_ID/dns_records/$record_id" "$desired_record_file")"
    require_success "$update_response" "Updating DNS record $fqdn"
    info "Updated $fqdn -> $ORIGIN_IP (proxied)."
done

step "Ensuring a wildcard Cloudflare Origin CA certificate"
origin_cert="$WORK_DIR/origin.crt"
origin_key="$WORK_DIR/origin.key"
certificate_created=false

if kubectl get secret "$TLS_SECRET_NAME" -n "$INGRESS_NAMESPACE" >/dev/null 2>&1; then
    kubectl get secret "$TLS_SECRET_NAME" -n "$INGRESS_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$origin_cert"
    kubectl get secret "$TLS_SECRET_NAME" -n "$INGRESS_NAMESPACE" -o jsonpath='{.data.tls\.key}' | base64 -d > "$origin_key"
fi

if certificate_is_usable "$origin_cert" "$origin_key"; then
    info "Reusing the valid Origin CA certificate from $INGRESS_NAMESPACE/$TLS_SECRET_NAME."
else
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$origin_key" 2>/dev/null
    origin_csr="$WORK_DIR/origin.csr"
    openssl req -new -key "$origin_key" -out "$origin_csr" -subj "/CN=*.$ZONE_NAME"
    certificate_request_file="$WORK_DIR/certificate-request.json"
    jq -n --rawfile csr "$origin_csr" --arg wildcard "*.$ZONE_NAME" --arg apex "$ZONE_NAME" \
        '{hostnames:[$wildcard,$apex],requested_validity:5475,request_type:"origin-rsa",csr:$csr}' \
        > "$certificate_request_file"
    certificate_response="$(cf_request POST /certificates "$certificate_request_file")"
    require_success "$certificate_response" "Origin CA certificate creation"
    jq -r '.result.certificate' <<< "$certificate_response" > "$origin_cert"
    certificate_is_usable "$origin_cert" "$origin_key" || error "Cloudflare returned an unusable Origin CA certificate."
    certificate_created=true
    info "Created a 15-year wildcard Origin CA certificate for *.$ZONE_NAME."
fi

TLS_NAMESPACES=("$INGRESS_NAMESPACE")
while IFS= read -r namespace; do
    append_unique_namespace "$namespace"
done < <(kubectl get ingress -A -o json 2>/dev/null | jq -r --arg secret "$TLS_SECRET_NAME" \
    '.items[] | select(any(.spec.tls[]?; .secretName == $secret)) | .metadata.namespace' | sort -u)
if kubectl get namespace apps >/dev/null 2>&1; then
    append_unique_namespace apps
fi

for namespace in "${TLS_NAMESPACES[@]}"; do
    if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
        warn "Skipping TLS secret sync because namespace does not exist: $namespace"
        continue
    fi
    kubectl create secret tls "$TLS_SECRET_NAME" \
        --namespace "$namespace" \
        --cert "$origin_cert" \
        --key "$origin_key" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    info "Installed $TLS_SECRET_NAME in namespace $namespace."
done

step "Applying the Cloudflare security and performance baseline"
set_zone_setting ssl strict "Full (strict) TLS"
set_zone_setting always_use_https on "Always Use HTTPS"
set_zone_setting min_tls_version "$MIN_TLS_VERSION" "minimum edge TLS version"
# Cloudflare's 'zrt' value enables TLS 1.3 0-RTT. Avoid replayable early data
# because this zone hosts login pages, APIs, and administrative actions.
set_zone_setting tls_1_3 on "TLS 1.3 without 0-RTT"
set_zone_setting automatic_https_rewrites on "Automatic HTTPS Rewrites"
set_zone_setting brotli on "Brotli compression"
set_zone_setting http3 on "HTTP/3"
set_zone_setting opportunistic_encryption on "opportunistic encryption"
set_zone_setting websockets on "WebSockets"
set_zone_setting early_hints on "Early Hints"
set_zone_setting ipv6 on "IPv6 compatibility"
# This zone serves REST APIs, Git webhooks, CLIs, and CI agents in addition to
# browsers. Browser Integrity Check challenges legitimate non-browser clients;
# authentication and Cloudflare's network-level protections remain in place.
# The cluster-only swirlit.internal zone is resolved exclusively by CoreDNS and is
# intentionally absent from every Cloudflare DNS and edge rule.
set_zone_setting browser_check off "Browser Integrity Check for API compatibility"
# These HTML-rewriting/content-blocking features are a poor fit for dashboards
# and cross-host assets and can cause missing images or modified application UI.
set_zone_setting hotlink_protection off "Hotlink Protection for application compatibility"
set_zone_setting email_obfuscation off "Email Address Obfuscation for application compatibility"

hsts_setting_file="$WORK_DIR/security-header-setting.json"
jq -n \
    --argjson enabled "$ENABLE_HSTS" \
    --argjson max_age "$HSTS_MAX_AGE" \
    '{value:{strict_transport_security:{enabled:$enabled,max_age:$max_age,include_subdomains:$enabled,preload:false,nosniff:true}}}' \
    > "$hsts_setting_file"
setting_response="$(cf_request PATCH "/zones/$ZONE_ID/settings/security_header" "$hsts_setting_file")"
require_success "$setting_response" "Configuring HSTS and X-Content-Type-Options"
if [[ "$ENABLE_HSTS" == "true" ]]; then
    info "Enabled HSTS for one year, including subdomains; preload remains intentionally disabled."
else
    info "HSTS is disabled by configuration."
fi

configure_registry_bot_compatibility
configure_edge_rules
configure_access

dnssec_response="$(cf_request GET "/zones/$ZONE_ID/dnssec")"
require_success "$dnssec_response" "Reading DNSSEC status"
dnssec_status="$(jq -r '.result.status' <<< "$dnssec_response")"
if [[ "$ENABLE_DNSSEC" == "true" && "$dnssec_status" == "disabled" ]]; then
    dnssec_setting_file="$WORK_DIR/dnssec-setting.json"
    printf '{"status":"active"}\n' > "$dnssec_setting_file"
    dnssec_response="$(cf_request PATCH "/zones/$ZONE_ID/dnssec" "$dnssec_setting_file")"
    require_success "$dnssec_response" "Enabling DNSSEC"
    dnssec_status="$(jq -r '.result.status' <<< "$dnssec_response")"
    info "Enabled Cloudflare DNSSEC."
elif [[ "$ENABLE_DNSSEC" == "true" ]]; then
    info "DNSSEC is already $dnssec_status."
fi

if [[ "$ENABLE_DNSSEC" == "true" && "$dnssec_status" != "active" ]]; then
    warn "DNSSEC is $dnssec_status until the registrar publishes this DS record:"
    jq -r '.result | "  Key tag: \(.key_tag)\n  Algorithm: \(.algorithm)\n  Digest type: \(.digest_algorithm)\n  Digest: \(.digest)\n  DS: \(.ds)"' <<< "$dnssec_response" >&2
fi

lock_origin_firewall

step "Verifying Cloudflare and Kubernetes state"
for fqdn in "${DNS_HOSTS[@]}"; do
    record_response="$(cf_request GET "/zones/$ZONE_ID/dns_records?type=A&name=$fqdn&per_page=100")"
    require_success "$record_response" "Final DNS verification for $fqdn"
    jq -e --arg content "$ORIGIN_IP" \
        '.result | length == 1 and .[0].content == $content and .[0].proxied == true' \
        <<< "$record_response" >/dev/null || error "Final DNS verification failed for $fqdn."
done

ssl_response="$(cf_request GET "/zones/$ZONE_ID/settings/ssl")"
require_success "$ssl_response" "Final SSL setting verification"
[[ "$(jq -r '.result.value' <<< "$ssl_response")" == "strict" ]] || error "Cloudflare SSL mode is not strict."

https_response="$(cf_request GET "/zones/$ZONE_ID/settings/always_use_https")"
require_success "$https_response" "Final HTTPS setting verification"
[[ "$(jq -r '.result.value' <<< "$https_response")" == "on" ]] || error "Always Use HTTPS is not enabled."

min_tls_response="$(cf_request GET "/zones/$ZONE_ID/settings/min_tls_version")"
require_success "$min_tls_response" "Final minimum TLS verification"
[[ "$(jq -r '.result.value' <<< "$min_tls_response")" == "$MIN_TLS_VERSION" ]] || error "Minimum TLS is not $MIN_TLS_VERSION."

tls13_response="$(cf_request GET "/zones/$ZONE_ID/settings/tls_1_3")"
require_success "$tls13_response" "Final TLS 1.3 verification"
[[ "$(jq -r '.result.value' <<< "$tls13_response")" == "on" ]] || error "TLS 1.3 without 0-RTT is not enabled."

hsts_response="$(cf_request GET "/zones/$ZONE_ID/settings/security_header")"
require_success "$hsts_response" "Final HSTS verification"
if [[ "$ENABLE_HSTS" == "true" ]]; then
    jq -e --argjson max_age "$HSTS_MAX_AGE" \
        '.result.value.strict_transport_security | .enabled == true and .max_age == $max_age and .include_subdomains == true and .preload == false and .nosniff == true' \
        <<< "$hsts_response" >/dev/null || error "HSTS did not match the secure baseline."
fi

kubectl get secret "$TLS_SECRET_NAME" -n "$INGRESS_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORK_DIR/verify.crt"
openssl x509 -in "$WORK_DIR/verify.crt" -noout -checkend 2592000 >/dev/null 2>&1 || \
    error "The Kubernetes Origin CA certificate failed final validation."

info "Cloudflare configuration is complete."
echo ""
echo "  Zone:          $ZONE_NAME ($ZONE_STATUS)"
echo "  Origin:        $ORIGIN_IP"
echo "  DNS records:   ${#DNS_HOSTS[@]} proxied A records"
echo "  TLS mode:      Full (strict)"
echo "  Minimum TLS:   $MIN_TLS_VERSION"
echo "  TLS 1.3:       enabled (0-RTT disabled)"
echo "  HTTPS redirect: enabled"
echo "  HSTS:          $([[ "$ENABLE_HSTS" == "true" ]] && echo enabled || echo disabled)"
echo "  HTTP/3/Brotli: enabled"
echo "  WAF baseline:  $([[ "$ENABLE_WAF" == "true" ]] && echo enabled || echo disabled)"
echo "  Login limit:   $([[ "$ENABLE_RATE_LIMIT" == "true" ]] && echo enabled || echo disabled)"
echo "  Cache safety:  $([[ "$ENABLE_CACHE_RULES" == "true" ]] && echo enabled || echo disabled)"
echo "  Registry bots: $REGISTRY_BOT_STATUS"
echo "  Admin Access:  $([[ "$ENABLE_ACCESS" == "true" ]] && echo "email OTP ($ACCESS_SESSION_DURATION sessions)" || echo disabled)"
echo "  DNSSEC:        $dnssec_status"
echo "  Origin access: $ORIGIN_LOCK_STATUS"
echo "  Origin cert:   $([[ "$certificate_created" == "true" ]] && echo created || echo reused)"

if [[ "$ZONE_STATUS" != "active" ]]; then
    echo ""
    warn "Zone activation is still pending; rerun this script after registrar delegation."
fi
