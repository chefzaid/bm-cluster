#!/bin/bash
set -euo pipefail

NAMESPACE="${1:-infra}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_ADDR="http://127.0.0.1:8200"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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
  kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- env VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$token" vault "$@"
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
    "$REPO_ROOT/systemd/bm-vault-unseal.service" /etc/systemd/system/bm-vault-unseal.service
  sudo install -o root -g root -m 0644 \
    "$REPO_ROOT/systemd/bm-vault-unseal.timer" /etc/systemd/system/bm-vault-unseal.timer
  sudo systemctl daemon-reload
  sudo systemctl enable --now bm-vault-unseal.timer >/dev/null
}

require_cmd kubectl
require_cmd jq
require_cmd openssl
require_cmd sudo
require_cmd systemctl

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

if ! vault_cmd_auth "$root_token" secrets list -format=json | jq -e '."secret/"' >/dev/null 2>&1; then
  info "Enabling Vault KV v2 engine at path 'secret/'..."
  vault_cmd_auth "$root_token" secrets enable -path=secret kv-v2 >/dev/null
fi

if ! vault_cmd_auth "$root_token" auth list -format=json | jq -e '."kubernetes/"' >/dev/null 2>&1; then
  info "Enabling Kubernetes auth method..."
  vault_cmd_auth "$root_token" auth enable kubernetes >/dev/null
fi

info "Configuring Kubernetes auth backend..."
kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- env VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$root_token" sh -c \
  'vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" >/dev/null'

cat <<'EOF' | kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- env VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$root_token" vault policy write external-secrets-policy - >/dev/null
path "secret/data/infra/*" {
  capabilities = ["read"]
}

path "secret/metadata/infra/*" {
  capabilities = ["read", "list"]
}

path "secret/data/devapp/ci" {
  capabilities = ["read"]
}

path "secret/metadata/devapp/ci" {
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

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/keycloak >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/keycloak"
  keycloak_admin_password="$(generate_secret)"
  keycloak_user_password="$(generate_secret)"
  keycloak_client_secret="$(generate_secret)"
  realm_export_json="$(
    jq -cn \
      --arg keycloak_user_password "$keycloak_user_password" \
      --arg keycloak_client_secret "$keycloak_client_secret" \
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
            redirectUris: ["https://app.swirlit.dev/*"],
            webOrigins: ["https://app.swirlit.dev"],
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

if ! vault_cmd_auth "$root_token" kv get -format=json secret/infra/jenkins >/dev/null 2>&1; then
  info "Seeding Vault secret: infra/jenkins"
  nexus_password="$(kubectl exec -n "$NAMESPACE" deployment/nexus -- cat /nexus-data/admin.password 2>/dev/null || true)"
  if [[ -z "$nexus_password" ]]; then
    warn "Unable to read Nexus admin password; seeding Jenkins config with generated placeholder password."
    nexus_password="$(generate_secret)"
  fi
  nexus_auth="$(printf 'admin:%s' "$nexus_password" | base64 | tr -d '\n')"
  settings_xml="$(cat <<EOF
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <servers>
    <server>
      <id>central</id>
      <username>admin</username>
      <password>$nexus_password</password>
    </server>
    <server>
      <id>snapshots</id>
      <username>admin</username>
      <password>$nexus_password</password>
    </server>
    <server>
      <id>nexus-releases</id>
      <username>admin</username>
      <password>$nexus_password</password>
    </server>
    <server>
      <id>nexus-snapshots</id>
      <username>admin</username>
      <password>$nexus_password</password>
    </server>
  </servers>
</settings>
EOF
)"
  npmrc="$(cat <<EOF
registry=http://nexus.infra.svc.cluster.local:8081/repository/npm-group/
_auth=$nexus_auth
always-auth=true
EOF
)"
  vault_cmd_auth "$root_token" kv put secret/infra/jenkins \
    settings_xml="$settings_xml" \
    npmrc="$npmrc" >/dev/null
fi

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

install_host_unseal_service
sudo systemctl start bm-vault-unseal.service

# Remove the legacy in-cluster unseal path only after the host-side copy and
# systemd timer have both been installed successfully.
kubectl delete cronjob/vault-unseal rolebinding/vault-unseal role/vault-unseal \
  serviceaccount/vault-unseal -n "$NAMESPACE" --ignore-not-found >/dev/null
kubectl delete secret vault-init -n "$NAMESPACE" --ignore-not-found >/dev/null

unset unseal_key root_token
info "Vault bootstrap/configuration completed."
