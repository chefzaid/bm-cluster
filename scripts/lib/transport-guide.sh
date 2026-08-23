#!/bin/bash
# Shared interactive account-readiness wizards for private node transports.
# The caller owns strict-mode settings and provides info(), warn(), and error().

TRANSPORT_GUIDE_OVH_DOC_URL="https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/vrack-configuring-on-dedicated-server"
TRANSPORT_GUIDE_OVH_MANAGER_URL="https://www.ovh.com/manager/#/dedicated/vrack"
TRANSPORT_GUIDE_OVH_API_DOC_URL="https://docs.ovhcloud.com/en/guides/manage-and-operate/api/first-steps"
TRANSPORT_GUIDE_TAILSCALE_ADMIN_URL="https://login.tailscale.com/admin"
TRANSPORT_GUIDE_TAILSCALE_KEYS_URL="https://login.tailscale.com/admin/settings/keys"
TRANSPORT_GUIDE_TAILSCALE_API_DOC_URL="https://tailscale.com/docs/reference/tailscale-api"

transport_guide_prompt() {
    local variable_name="$1" prompt_text="$2" default_value="${3:-}" answer=""
    read -rp "$prompt_text${default_value:+ [$default_value]}: " answer
    printf -v "$variable_name" '%s' "${answer:-$default_value}"
}

transport_guide_secret() {
    local variable_name="$1" prompt_text="$2" answer=""
    read -rsp "$prompt_text: " answer
    printf '\n' >&2
    printf -v "$variable_name" '%s' "$answer"
}

transport_guide_continue() {
    local prompt_text="$1" answer=""
    read -rp "$prompt_text [Enter=continue, q=quit]: " answer
    [[ "${answer,,}" != "q" ]] || return 1
}

transport_guide_tailscale_account() {
    local non_interactive="$1" configurator="$2" prompt_node_identity="${3:-true}" expiry_minutes answer=""

    if [[ "$non_interactive" != "true" ]]; then
        cat >&2 <<EOF

Tailscale prerequisite guide (hybrid cloud or non-OVHcloud providers)
  1. Sign in or create the tailnet: $TRANSPORT_GUIDE_TAILSCALE_ADMIN_URL
  2. Use an Owner, Admin, IT admin, or Network admin account.
  3. Open Settings -> Keys: $TRANSPORT_GUIDE_TAILSCALE_KEYS_URL
  4. Under API access tokens, choose Generate access token. This must be a
     personal tskey-api token, not a tskey-auth device key. Choose the shortest
     practical expiry; the token is used only for this run and is not saved.

Official API-token reference: $TRANSPORT_GUIDE_TAILSCALE_API_DOC_URL
EOF
        transport_guide_continue "Return here after the tailnet and API access token are ready" || return 1
        transport_guide_prompt TAILSCALE_TAILNET "Tailnet name/login domain ('-' uses the token's tailnet)" "$TAILSCALE_TAILNET"
        transport_guide_prompt TAILSCALE_MESH_NAME "Unique Tailscale mesh/cluster name" "$TAILSCALE_MESH_NAME"
        if [[ "$prompt_node_identity" == "true" ]]; then
            transport_guide_prompt TAILSCALE_NODE_HOSTNAME "Tailscale hostname for this node" "$TAILSCALE_NODE_HOSTNAME"
        fi
        [[ "$TAILSCALE_AUTH_KEY_EXPIRY_SECONDS" =~ ^[0-9]+$ ]] || return 1
        expiry_minutes="$((TAILSCALE_AUTH_KEY_EXPIRY_SECONDS / 60))"
        transport_guide_prompt expiry_minutes "One-use node auth-key lifetime in minutes" "$expiry_minutes"
        [[ "$expiry_minutes" =~ ^[1-9][0-9]*$ ]] || return 1
        TAILSCALE_AUTH_KEY_EXPIRY_SECONDS="$((expiry_minutes * 60))"
        [[ -n "$TAILSCALE_API_TOKEN" ]] || \
            transport_guide_secret TAILSCALE_API_TOKEN "Tailscale personal API access token (tskey-api-...)"
    fi

    [[ "$TAILSCALE_API_TOKEN" =~ ^tskey-api-[A-Za-z0-9_-]+$ ]] || return 1
    while ! printf '%s\n' "$TAILSCALE_API_TOKEN" | \
        "$configurator" --verify-account --role control-plane \
            --tailnet "$TAILSCALE_TAILNET" --mesh-name "$TAILSCALE_MESH_NAME" \
            --api-token-stdin --non-interactive >/dev/null; do
        [[ "$non_interactive" != "true" ]] || return 1
        warn "Tailscale could not verify that token and tailnet. No host firewall change was made."
        read -rp "Press Enter to retry, r to replace the token, or q to quit: " answer
        case "${answer,,}" in
            q) return 1 ;;
            r) transport_guide_secret TAILSCALE_API_TOKEN "Replacement Tailscale personal API access token" ;;
        esac
    done
    info "Tailscale account access is verified; transport setup may continue."
}

transport_guide_vrack_token_url() {
    case "$1" in
        ovh-eu) printf '%s\n' 'https://eu.api.ovh.com/createToken/' ;;
        ovh-ca) printf '%s\n' 'https://ca.api.ovh.com/createToken/' ;;
        ovh-us) printf '%s\n' 'https://api.us.ovhcloud.com/createToken/' ;;
        *) return 1 ;;
    esac
}

transport_guide_vrack_account() {
    local non_interactive="$1" configurator="$2" answer="" token_url

    if [[ -z "$OVH_VRACK_AUTOMATE_ACCOUNT" ]]; then
        if [[ "$non_interactive" == "true" ]]; then
            if [[ -n "$OVH_APPLICATION_KEY$OVH_APPLICATION_SECRET$OVH_CONSUMER_KEY$OVH_VRACK_SERVICE_NAME" ]]; then
                OVH_VRACK_AUTOMATE_ACCOUNT=true
            else
                OVH_VRACK_AUTOMATE_ACCOUNT=false
            fi
        else
            read -rp "Use the OVHcloud API to attach server interfaces to an existing vRack? [Y/n]: " answer
            [[ "${answer:-Y}" =~ ^[Yy]$ ]] && OVH_VRACK_AUTOMATE_ACCOUNT=true || OVH_VRACK_AUTOMATE_ACCOUNT=false
        fi
    fi
    [[ "$OVH_VRACK_AUTOMATE_ACCOUNT" =~ ^(true|false)$ ]] || return 1

    if [[ "$non_interactive" != "true" ]]; then
        cat >&2 <<EOF

OVHcloud vRack prerequisite guide (OVHcloud Dedicated Servers only)
  1. Confirm every planned node is an eligible OVHcloud Dedicated Server.
  2. Order or activate a vRack in the Control Panel:
     $TRANSPORT_GUIDE_OVH_MANAGER_URL
  3. Before changing networking, verify KVM/IPMI or rescue access for every
     server. This is the recovery path if a NIC name or MAC is wrong.
  4. Record each Dedicated Server service name and choose one unused RFC1918
     subnet plus one unique address per node.

Official vRack host-network guide: $TRANSPORT_GUIDE_OVH_DOC_URL
EOF
        if [[ "$OVH_VRACK_AUTOMATE_ACCOUNT" == "true" ]]; then
            transport_guide_continue "Return here after the vRack is active and recovery access is proven" || return 1
            transport_guide_prompt OVH_API_ENDPOINT "OVHcloud API region endpoint (ovh-eu, ovh-ca, or ovh-us)" "$OVH_API_ENDPOINT"
            token_url="$(transport_guide_vrack_token_url "$OVH_API_ENDPOINT")" || return 1
            cat >&2 <<EOF

Create temporary OVHcloud API credentials at:
  $token_url

Grant these least-privilege paths (wildcards include interface/task reads):
  GET  /vrack
  GET  /vrack/*
  POST /vrack/*/dedicatedServerInterface
  GET  /dedicated/server/*/networking

Official API credential guide: $TRANSPORT_GUIDE_OVH_API_DOC_URL
EOF
            transport_guide_continue "Return here after the API credentials are created" || return 1
            transport_guide_prompt OVH_VRACK_SERVICE_NAME "Existing OVHcloud vRack service name (pn-...)" "$OVH_VRACK_SERVICE_NAME"
            [[ -n "$OVH_APPLICATION_KEY" ]] || transport_guide_prompt OVH_APPLICATION_KEY "OVHcloud API application key"
            [[ -n "$OVH_APPLICATION_SECRET" ]] || transport_guide_secret OVH_APPLICATION_SECRET "OVHcloud API application secret"
            [[ -n "$OVH_CONSUMER_KEY" ]] || transport_guide_secret OVH_CONSUMER_KEY "OVHcloud API consumer key"
        else
            cat >&2 <<'EOF'
  5. In the Control Panel, attach the control plane and every worker to that
     vRack, then record the private NIC name or MAC shown for each server.
EOF
            transport_guide_continue "Return here after every server is attached and recovery access is proven" || return 1
        fi
    fi

    if [[ "$OVH_VRACK_AUTOMATE_ACCOUNT" == "true" ]]; then
        [[ -n "$OVH_APPLICATION_KEY" && -n "$OVH_APPLICATION_SECRET" && -n "$OVH_CONSUMER_KEY" && -n "$OVH_VRACK_SERVICE_NAME" ]] || return 1
        while ! OVH_APPLICATION_KEY="$OVH_APPLICATION_KEY" \
            OVH_APPLICATION_SECRET="$OVH_APPLICATION_SECRET" \
            OVH_CONSUMER_KEY="$OVH_CONSUMER_KEY" \
            "$configurator" --verify-account --vrack "$OVH_VRACK_SERVICE_NAME" \
                --ovh-endpoint "$OVH_API_ENDPOINT" --non-interactive >/dev/null; do
            [[ "$non_interactive" != "true" ]] || return 1
            warn "OVHcloud could not verify those credentials and vRack. No NIC or firewall was changed."
            read -rp "Press Enter to retry, r to replace all API credentials, or q to quit: " answer
            case "${answer,,}" in
                q) return 1 ;;
                r)
                    transport_guide_prompt OVH_APPLICATION_KEY "Replacement OVHcloud API application key"
                    transport_guide_secret OVH_APPLICATION_SECRET "Replacement OVHcloud API application secret"
                    transport_guide_secret OVH_CONSUMER_KEY "Replacement OVHcloud API consumer key"
                    ;;
            esac
        done
        info "OVHcloud API access and vRack activation are verified; server attachment may continue."
    else
        warn "Using manually confirmed OVHcloud vRack attachment; each entered private NIC will still be validated on the host."
    fi
}
