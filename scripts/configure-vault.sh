#!/bin/bash
set -euo pipefail

NAMESPACE="${1:-infra}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_ADDR="http://127.0.0.1:8200"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_CONFIG="$REPO_ROOT/config/platform.env"
if [[ -r "$PLATFORM_CONFIG" ]]; then
  # shellcheck source=config/platform.env
  source "$PLATFORM_CONFIG"
fi
PLATFORM_DOMAIN="${PLATFORM_DOMAIN:-${DEFAULT_PLATFORM_DOMAIN:-}}"
SSO_ADMIN_LIBRARY="$SCRIPT_DIR/lib/sso-admin.sh"
VAULT_STATE_DIR="${VAULT_STATE_DIR:-/var/lib/bm-cluster}"
VAULT_UNSEAL_KEY_FILE="$VAULT_STATE_DIR/vault-unseal-key"
VAULT_BOOTSTRAP_TOKEN_FILE="$VAULT_STATE_DIR/vault-bootstrap-token"

info()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

vault_cmd() {
  kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- env VAULT_ADDR="$VAULT_ADDR" vault "$@"
}

vault_cmd_auth() {
  local token="$1"
  shift
  { printf '%s\n' "$token"; } | kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
    IFS= read -r VAULT_TOKEN
    export VAULT_TOKEN VAULT_ADDR="$1"
    shift
    exec vault "$@"
  ' sh "$VAULT_ADDR" "$@"
}

vault_stdin_auth() {
  local token="$1"
  shift
  { printf '%s\n' "$token"; cat; } | kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
    IFS= read -r VAULT_TOKEN
    export VAULT_TOKEN VAULT_ADDR="$1"
    shift
    exec vault "$@" -
  ' sh "$VAULT_ADDR" "$@"
}

generate_secret() {
  openssl rand -base64 36 | tr -d '\n' | tr '/+' 'ab' | cut -c1-32
}

install_host_secret() {
  local value="$1"
  local destination="$2"
  local temporary_file

  umask 077
  temporary_file="$(mktemp)"
  printf '%s' "$value" > "$temporary_file"
  sudo install -o root -g root -m 0600 "$temporary_file" "$destination"
  rm -f "$temporary_file"
}

install_host_unseal_service() {
  sudo install -d -o root -g root -m 0700 "$VAULT_STATE_DIR"
  sudo install -o root -g root -m 0750 \
    "$REPO_ROOT/scripts/vault-unseal.sh" /usr/local/sbin/bm-vault-unseal
  sudo install -o root -g root -m 0644 \
    "$REPO_ROOT/config/systemd/bm-vault-unseal.service" /etc/systemd/system/bm-vault-unseal.service
  sudo install -o root -g root -m 0644 \
    "$REPO_ROOT/config/systemd/bm-vault-unseal.timer" /etc/systemd/system/bm-vault-unseal.timer
  sudo systemctl daemon-reload
  sudo systemctl enable --now bm-vault-unseal.timer >/dev/null
}

require_cmd kubectl
require_cmd jq
require_cmd openssl
require_cmd sudo
require_cmd systemctl
[[ "$PLATFORM_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || \
  error "Set PLATFORM_DOMAIN to the cluster's public base domain."
[[ -r "$SSO_ADMIN_LIBRARY" ]] || error "Shared SSO administrator library not found: $SSO_ADMIN_LIBRARY"
# shellcheck source=scripts/lib/sso-admin.sh
source "$SSO_ADMIN_LIBRARY"

sudo install -d -o root -g root -m 0700 "$VAULT_STATE_DIR"

info "Waiting for Vault pod ($VAULT_POD) to be running..."
kubectl wait --for=jsonpath='{.status.phase}'=Running "pod/$VAULT_POD" -n "$NAMESPACE" --timeout=300s >/dev/null

status_json="$(vault_cmd status -format=json 2>/dev/null || true)"
[[ -n "$status_json" ]] || error "Unable to read Vault status."
initialized="$(echo "$status_json" | jq -r '.initialized')"
sealed="$(echo "$status_json" | jq -r '.sealed')"

if [[ "$initialized" != "true" ]]; then
  info "Initializing Vault..."
  init_json="$(vault_cmd operator init -key-shares=1 -key-threshold=1 -format=json)"
  unseal_key="$(echo "$init_json" | jq -r '.unseal_keys_b64[0]')"
  root_token="$(echo "$init_json" | jq -r '.root_token')"
  install_host_secret "$unseal_key" "$VAULT_UNSEAL_KEY_FILE"
  install_host_secret "$root_token" "$VAULT_BOOTSTRAP_TOKEN_FILE"
  unset init_json
  info "Stored Vault initialization material in root-only host files."
fi

if [[ ! -s "$VAULT_UNSEAL_KEY_FILE" && ! -s "$VAULT_BOOTSTRAP_TOKEN_FILE" ]] && \
   kubectl get secret vault-init -n "$NAMESPACE" >/dev/null 2>&1; then
  info "Migrating legacy Vault initialization material out of Kubernetes..."
  legacy_unseal_key="$(kubectl get secret vault-init -n "$NAMESPACE" -o jsonpath='{.data.unseal_key}' | base64 -d)"
  legacy_root_token="$(kubectl get secret vault-init -n "$NAMESPACE" -o jsonpath='{.data.root_token}' | base64 -d)"
  [[ -n "$legacy_unseal_key" && -n "$legacy_root_token" ]] || error "Legacy Vault bootstrap secret is incomplete."
  install_host_secret "$legacy_unseal_key" "$VAULT_UNSEAL_KEY_FILE"
  install_host_secret "$legacy_root_token" "$VAULT_BOOTSTRAP_TOKEN_FILE"
  unset legacy_unseal_key legacy_root_token
fi

sudo test -s "$VAULT_UNSEAL_KEY_FILE" || error "Missing $VAULT_UNSEAL_KEY_FILE. Restore the Vault unseal key before continuing."
sudo test -s "$VAULT_BOOTSTRAP_TOKEN_FILE" || error "Missing $VAULT_BOOTSTRAP_TOKEN_FILE. Restore the Vault bootstrap token before continuing."

unseal_key="$(sudo cat "$VAULT_UNSEAL_KEY_FILE")"
root_token="$(sudo cat "$VAULT_BOOTSTRAP_TOKEN_FILE")"

if [[ "$sealed" == "true" ]]; then
  info "Unsealing Vault..."
  printf '%s\n' "$unseal_key" | kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- \
    env VAULT_ADDR="$VAULT_ADDR" vault operator unseal >/dev/null
fi

status_json="$(vault_cmd status -format=json 2>/dev/null || true)"
[[ -n "$status_json" ]] || error "Unable to read Vault status after unseal."
sealed="$(echo "$status_json" | jq -r '.sealed')"
[[ "$sealed" == "false" ]] || error "Vault remains sealed after unseal attempt."

if ! vault_cmd_auth "$root_token" audit list -format=json | jq -e '."stdout/"' >/dev/null 2>&1; then
  info "Enabling the Vault stdout audit device..."
  vault_cmd_auth "$root_token" audit enable -path=stdout file \
    file_path=stdout \
    format=json \
    elide_list_responses=true \
    hmac_accessor=false >/dev/null
fi

if ! vault_cmd_auth "$root_token" audit list -format=json | jq -e '."file/"' >/dev/null 2>&1; then
  if kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- test -w /vault/audit; then
    info "Enabling the persistent Vault file audit device..."
    vault_cmd_auth "$root_token" audit enable -path=file file \
      file_path=/vault/audit/vault-audit.log \
      mode=0600 \
      format=json \
      elide_list_responses=true \
      hmac_accessor=false >/dev/null
  else
    warn "Persistent audit storage is not writable at /vault/audit; stdout auditing remains active."
  fi
fi

if ! vault_cmd_auth "$root_token" secrets list -format=json | jq -e '."secret/"' >/dev/null 2>&1; then
  info "Enabling Vault KV v2 engine at path 'secret/'..."
  vault_cmd_auth "$root_token" secrets enable -path=secret kv-v2 >/dev/null
fi

if ! vault_cmd_auth "$root_token" auth list -format=json | jq -e '."kubernetes/"' >/dev/null 2>&1; then
  info "Enabling Kubernetes auth method..."
  vault_cmd_auth "$root_token" auth enable kubernetes >/dev/null
fi

info "Configuring Kubernetes auth backend..."
# Vault runs in Kubernetes and its service account has system:auth-delegator.
# Leaving the reviewer JWT and CA unset makes Vault re-read its projected token
# and cluster CA as they rotate, instead of persisting credentials that expire.
vault_cmd_auth "$root_token" write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  token_reviewer_jwt="" \
  kubernetes_ca_cert="" >/dev/null

cat <<'EOF' | vault_stdin_auth "$root_token" policy write external-secrets-policy >/dev/null
path "secret/data/infra/*" {
  capabilities = ["read"]
}

path "secret/metadata/infra/*" {
  capabilities = ["read", "list"]
}

path "secret/data/apps/*" {
  capabilities = ["read"]
}

path "secret/metadata/apps/*" {
  capabilities = ["read"]
}
EOF

vault_cmd_auth "$root_token" write auth/kubernetes/role/external-secrets-role \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces="$NAMESPACE" \
  audience=vault \
  policies=external-secrets-policy \
  ttl=24h >/dev/null

postgres_default_username="${POSTGRES_DEFAULT_USERNAME:-admin}"
postgres_default_password="${POSTGRES_DEFAULT_PASSWORD:-}"
postgres_runtime_username="$(kubectl exec -n "$NAMESPACE" deployment/postgres -- printenv POSTGRES_USER 2>/dev/null || true)"
postgres_runtime_password="$(kubectl exec -n "$NAMESPACE" deployment/postgres -- printenv POSTGRES_PASSWORD 2>/dev/null || true)"
[[ -n "$postgres_default_password" ]] || postgres_default_password="$(generate_secret)"

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/postgres >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/postgres"
  vault_cmd_auth "$root_token" kv put secret/infra/postgres \
    username="${postgres_runtime_username:-$postgres_default_username}" \
    password="${postgres_runtime_password:-$postgres_default_password}" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/postgres | jq -e '.data.data.username' >/dev/null 2>&1; then
  vault_cmd_auth "$root_token" kv patch secret/infra/postgres username="${postgres_runtime_username:-$postgres_default_username}" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/postgres | jq -e '.data.data.password' >/dev/null 2>&1; then
  vault_cmd_auth "$root_token" kv patch secret/infra/postgres password="${postgres_runtime_password:-$postgres_default_password}" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/mongodb >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/mongodb"
  vault_cmd_auth "$root_token" kv put secret/infra/mongodb \
    root_username="admin" \
    root_password="$(generate_secret)" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/odoo >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/odoo"
  vault_cmd_auth "$root_token" kv put secret/infra/odoo \
    database_username="odoo" \
    database_password="$(generate_secret)" \
    admin_password="$(generate_secret)" \
    database_master_password="$(generate_secret)" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/sonarqube >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/sonarqube"
  sonar_password="$(generate_secret)"
  vault_cmd_auth "$root_token" kv put secret/infra/sonarqube \
    postgresql_password="$sonar_password" \
    jdbc_password="$sonar_password" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/grafana >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/grafana"
  vault_cmd_auth "$root_token" kv put secret/infra/grafana admin_password="$(generate_secret)" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/monitoring >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/monitoring"
  vault_cmd_auth "$root_token" kv put secret/infra/monitoring \
    gitlab_alert_token="$(openssl rand -hex 16)" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/keycloak >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/keycloak"
  keycloak_admin_password="$(generate_secret)"
  keycloak_user_password="$(generate_secret)"
  keycloak_client_secret="$(generate_secret)"
  realm_export_json="$(
    jq -cn \
      --arg keycloak_user_password "$keycloak_user_password" \
      --arg keycloak_client_secret "$keycloak_client_secret" \
      --arg platform_domain "$PLATFORM_DOMAIN" \
      '{
        realm: "application",
        enabled: true,
        users: [
          {
            username: "user",
            enabled: true,
            email: "user@example.com",
            firstName: "Test",
            lastName: "User",
            credentials: [
              {
                type: "password",
                value: $keycloak_user_password,
                temporary: false
              }
            ],
            realmRoles: ["user"],
            clientRoles: {
              account: ["view-profile", "manage-account"]
            }
          }
        ],
        roles: {
          realm: [
            {
              name: "user",
              description: "User role"
            },
            {
              name: "admin",
              description: "Admin role"
            }
          ]
        },
        clients: [
          {
            clientId: "api-gateway",
            enabled: true,
            clientAuthenticatorType: "client-secret",
            secret: $keycloak_client_secret,
            redirectUris: [
              "http://localhost:8080/login/oauth2/code/keycloak",
              "http://api-gateway:8080/login/oauth2/code/keycloak",
              "*"
            ],
            webOrigins: ["*"],
            standardFlowEnabled: true,
            implicitFlowEnabled: false,
            directAccessGrantsEnabled: true,
            serviceAccountsEnabled: true,
            publicClient: false,
            protocol: "openid-connect"
          },
          {
            clientId: "application-web",
            enabled: true,
            publicClient: true,
            redirectUris: [("https://app." + $platform_domain + "/*")],
            webOrigins: [("https://app." + $platform_domain)],
            standardFlowEnabled: true,
            directAccessGrantsEnabled: true
          }
        ]
      }'
  )"
  vault_cmd_auth "$root_token" kv put secret/infra/keycloak \
    admin_username="admin" \
    admin_password="$keycloak_admin_password" \
    realm_export_json="$realm_export_json" >/dev/null
fi

# The shared SSO realm is reconciled after Keycloak starts, rather than relying
# on startup import (which Keycloak intentionally ignores for an existing
# realm/database). Installer-provided administrator credentials are
# authoritative and may be updated on a reconciliation run. Generated OIDC
# client secrets remain stable once they have been seeded.
keycloak_sso_secret_json="$(vault_cmd_auth "$root_token" kv get -format=json secret/infra/keycloak)"
requested_sso_username="${KEYCLOAK_SSO_BOOTSTRAP_USERNAME:-}"
requested_sso_password="${KEYCLOAK_SSO_BOOTSTRAP_PASSWORD:-}"

if [[ -n "$requested_sso_username" || -n "$requested_sso_password" ]]; then
  [[ -n "$requested_sso_username" && -n "$requested_sso_password" ]] || \
    error "KEYCLOAK_SSO_BOOTSTRAP_USERNAME and KEYCLOAK_SSO_BOOTSTRAP_PASSWORD must be supplied together."
  sso_admin_validate_username "$requested_sso_username" || error "$SSO_ADMIN_VALIDATION_ERROR"
  sso_admin_validate_password "$requested_sso_password" "$requested_sso_username" || \
    error "$SSO_ADMIN_VALIDATION_ERROR"
  requested_sso_email="$(sso_admin_primary_email "$requested_sso_username" "$PLATFORM_DOMAIN")"
  requested_sso_display_name="Platform Administrator"

  if ! jq -e \
      --arg username "$requested_sso_username" \
      --arg password "$requested_sso_password" \
      --arg email "$requested_sso_email" \
      --arg display_name "$requested_sso_display_name" \
      '.data.data.sso_bootstrap_username == $username and
       .data.data.sso_bootstrap_password == $password and
       .data.data.sso_primary_email == $email and
       .data.data.sso_display_name == $display_name' \
      <<<"$keycloak_sso_secret_json" >/dev/null; then
    info "Updating the managed Keycloak platform administrator in Vault"
    vault_cmd_auth "$root_token" kv patch secret/infra/keycloak \
      sso_bootstrap_username="$requested_sso_username" \
      sso_bootstrap_password="$requested_sso_password" \
      sso_primary_email="$requested_sso_email" \
      sso_display_name="$requested_sso_display_name" >/dev/null
    keycloak_sso_secret_json="$(vault_cmd_auth "$root_token" kv get -format=json secret/infra/keycloak)"
  fi
fi

existing_sso_username="$(jq -r '.data.data.sso_bootstrap_username // empty' <<<"$keycloak_sso_secret_json")"
default_sso_username="${requested_sso_username:-${existing_sso_username:-platform-admin}}"
default_sso_password="${requested_sso_password:-$(generate_secret)}"
default_sso_email="$(sso_admin_primary_email "$default_sso_username" "$PLATFORM_DOMAIN")"
declare -A keycloak_sso_defaults=(
  [sso_bootstrap_username]="$default_sso_username"
  [sso_bootstrap_password]="$default_sso_password"
  [sso_primary_email]="$default_sso_email"
  [sso_display_name]="Platform Administrator"
  [oauth2_proxy_client_secret]="$(generate_secret)"
  [oauth2_proxy_cookie_secret]="$(generate_secret)"
  [gitlab_client_secret]="$(generate_secret)"
  [cloudflare_access_client_secret]="$(generate_secret)"
  [grafana_client_secret]="$(generate_secret)"
  [vault_client_secret]="$(generate_secret)"
  [kafka_ui_client_secret]="$(generate_secret)"
  [portainer_client_secret]="$(generate_secret)"
  [odoo_client_secret]="$(generate_secret)"
)
for keycloak_sso_field in "${!keycloak_sso_defaults[@]}"; do
  if ! jq -e --arg field "$keycloak_sso_field" '.data.data[$field] | strings | length > 0' \
    <<<"$keycloak_sso_secret_json" >/dev/null; then
    info "Adding Keycloak SSO secret field: $keycloak_sso_field"
    vault_cmd_auth "$root_token" kv patch secret/infra/keycloak \
      "$keycloak_sso_field=${keycloak_sso_defaults[$keycloak_sso_field]}" >/dev/null
  fi
done

keycloak_sso_secret_json="$(vault_cmd_auth "$root_token" kv get -format=json secret/infra/keycloak)"
vault_oidc_client_secret="$(jq -r '.data.data.vault_client_secret' <<<"$keycloak_sso_secret_json")"

if ! vault_cmd_auth "$root_token" auth list -format=json | jq -e '."oidc/"' >/dev/null 2>&1; then
  info "Enabling Vault OIDC authentication..."
  vault_cmd_auth "$root_token" auth enable oidc >/dev/null
fi

info "Configuring Vault OIDC authentication against the SwirlIT Keycloak realm..."
vault_cmd_auth "$root_token" write auth/oidc/config \
  oidc_discovery_url="https://keycloak.$PLATFORM_DOMAIN/auth/realms/swirlit" \
  oidc_client_id="vault" \
  oidc_client_secret="$vault_oidc_client_secret" \
  default_role="platform-admin" >/dev/null

cat <<'EOF' | vault_stdin_auth "$root_token" policy write platform-admin >/dev/null
path "*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
}
EOF

jq -n --arg redirect_uri "https://vault.$PLATFORM_DOMAIN/ui/vault/auth/oidc/oidc/callback" '
  {
    role_type: "oidc",
    bound_audiences: ["vault"],
    allowed_redirect_uris: [$redirect_uri, "http://localhost:8250/oidc/callback"],
    user_claim: "preferred_username",
    groups_claim: "groups",
    oidc_scopes: ["openid", "profile", "email", "groups"],
    bound_claims: {groups: "platform-admins"},
    policies: ["platform-admin"],
    ttl: "1h",
    max_ttl: "8h"
  }
' | vault_stdin_auth "$root_token" write auth/oidc/role/platform-admin >/dev/null

unset vault_oidc_client_secret
unset keycloak_sso_secret_json keycloak_sso_defaults keycloak_sso_field
unset requested_sso_username requested_sso_password requested_sso_email requested_sso_display_name
unset existing_sso_username default_sso_username default_sso_password default_sso_email

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/dbgate >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/dbgate"
  vault_cmd_auth "$root_token" kv put secret/infra/dbgate \
    login="admin" \
    password="$(generate_secret)" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/kafka-ui >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/kafka-ui"
  vault_cmd_auth "$root_token" kv put secret/infra/kafka-ui \
    username="admin" \
    password="$(generate_secret)" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/portainer >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/portainer"
  vault_cmd_auth "$root_token" kv put secret/infra/portainer \
    username="admin" \
    password="$(generate_secret)" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/elasticsearch >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/elasticsearch"
  elastic_superuser_password="${ELASTIC_SUPERUSER_PASSWORD:-$(generate_secret)}"
  elastic_admin_password="${ELASTIC_ADMIN_PASSWORD:-$(generate_secret)}"
  kibana_system_password="$(generate_secret)"
  logstash_writer_password="$(generate_secret)"
  fluent_bit_writer_password="$(generate_secret)"
  grafana_reader_password="$(generate_secret)"
  kibana_bootstrap_password="$(generate_secret)"
  kibana_keycloak_proxy_password="$(generate_secret)"
  ci_observer_password="$(generate_secret)"
  vault_cmd_auth "$root_token" kv put secret/infra/elasticsearch \
    elastic_username="elastic" \
    elastic_password="$elastic_superuser_password" \
    admin_username="admin" \
    admin_password="$elastic_admin_password" \
    kibana_system_username="kibana_system" \
    kibana_system_password="$kibana_system_password" \
    logstash_writer_username="logstash_writer" \
    logstash_writer_password="$logstash_writer_password" \
    fluent_bit_writer_username="fluent_bit_writer" \
    fluent_bit_writer_password="$fluent_bit_writer_password" \
    grafana_reader_username="grafana_reader" \
    grafana_reader_password="$grafana_reader_password" \
    kibana_bootstrap_username="kibana_dashboard_bootstrap" \
    kibana_bootstrap_password="$kibana_bootstrap_password" \
    kibana_keycloak_proxy_username="kibana_keycloak_proxy" \
    kibana_keycloak_proxy_password="$kibana_keycloak_proxy_password" \
    ci_observer_username="ci_observer" \
    ci_observer_password="$ci_observer_password" \
    kibana_security_encryption_key="$(generate_secret)" \
    kibana_saved_objects_encryption_key="$(generate_secret)" \
    kibana_reporting_encryption_key="$(generate_secret)" >/dev/null
  unset elastic_superuser_password elastic_admin_password kibana_system_password
  unset logstash_writer_password fluent_bit_writer_password grafana_reader_password
  unset kibana_bootstrap_password kibana_keycloak_proxy_password ci_observer_password
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/elasticsearch | \
  jq -e '.data.data.ci_observer_username and .data.data.ci_observer_password' >/dev/null 2>&1; then
  info "Adding the Elastic CI observer credential to Vault"
  vault_cmd_auth "$root_token" kv patch secret/infra/elasticsearch \
    ci_observer_username="ci_observer" \
    ci_observer_password="$(generate_secret)" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/elasticsearch | \
  jq -e '.data.data.kibana_keycloak_proxy_username and .data.data.kibana_keycloak_proxy_password' >/dev/null 2>&1; then
  info "Adding the Kibana Keycloak proxy credential to Vault"
  vault_cmd_auth "$root_token" kv patch secret/infra/elasticsearch \
    kibana_keycloak_proxy_username="kibana_keycloak_proxy" \
    kibana_keycloak_proxy_password="$(generate_secret)" >/dev/null
fi

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/platform-ui >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/platform-ui"
  platform_ui_username="${PLATFORM_UI_USERNAME:-admin}"
  platform_ui_password="${PLATFORM_UI_PASSWORD:-$(generate_secret)}"
  platform_ui_htpasswd="$platform_ui_username:$(openssl passwd -apr1 "$platform_ui_password")"
  vault_cmd_auth "$root_token" kv put secret/infra/platform-ui \
    username="$platform_ui_username" \
    password="$platform_ui_password" \
    htpasswd="$platform_ui_htpasswd" >/dev/null
  unset platform_ui_username platform_ui_password platform_ui_htpasswd
fi

install_host_unseal_service
sudo systemctl start bm-vault-unseal.service

# Remove the legacy in-cluster unseal path only after the host-side copy and
# systemd timer have both been installed successfully.
kubectl delete cronjob/vault-unseal rolebinding/vault-unseal role/vault-unseal \
  serviceaccount/vault-unseal -n "$NAMESPACE" --ignore-not-found >/dev/null
kubectl delete secret vault-init -n "$NAMESPACE" --ignore-not-found >/dev/null

unset unseal_key root_token
info "Vault bootstrap/configuration completed."
