#!/bin/bash
set -euo pipefail
set +x
umask 077

NAMESPACE="${NAMESPACE:-infra}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_ADDR="http://127.0.0.1:8200"
VAULT_BOOTSTRAP_TOKEN_FILE="${VAULT_BOOTSTRAP_TOKEN_FILE:-/var/lib/bm-cluster/vault-bootstrap-token}"

info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
fail() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  printf '%s\n' "$PASSWORD" | scripts/rotate-local-admin-passwords.sh --password-stdin
  printf '%s\n' "$PASSWORD" | scripts/rotate-local-admin-passwords.sh --password-stdin --from sonarqube
  LOCAL_ADMIN_PASSWORD=... scripts/rotate-local-admin-passwords.sh

Rotates local infrastructure administrator passwords in the services and in
Vault. Application accounts, SSO identities, API tokens, ingress Basic Auth,
and services without an internal administrator are deliberately excluded.
EOF
}

for command_name in base64 curl jq kubectl sudo; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: $command_name"
done

local_admin_password="${LOCAL_ADMIN_PASSWORD:-}"
password_from_stdin=false
start_at="${START_AT:-postgres}"
while (( $# > 0 )); do
  case "$1" in
    --password-stdin)
      password_from_stdin=true
      shift
      ;;
    --from)
      (( $# >= 2 )) || fail "--from requires a service name."
      start_at="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ "$password_from_stdin" == true ]]; then
  IFS= read -r local_admin_password || true
fi

case "$start_at" in
  postgres|mongodb|gitlab|grafana|keycloak|portainer|sonarqube|elasticsearch) ;;
  *) fail "Unknown --from service: $start_at" ;;
esac

[[ -n "$local_admin_password" ]] || fail "Supply the password through stdin or LOCAL_ADMIN_PASSWORD."
(( ${#local_admin_password} >= 12 )) || fail "The local administrator password must contain at least 12 characters."
[[ ! "$local_admin_password" =~ [[:cntrl:]] ]] || fail "The local administrator password cannot contain control characters."
[[ "$local_admin_password" =~ [[:lower:]] &&
   "$local_admin_password" =~ [[:upper:]] &&
   "$local_admin_password" =~ [[:digit:]] &&
   "$local_admin_password" =~ [^[:alnum:]] ]] || \
  fail "The local administrator password must include lowercase, uppercase, numeric, and special characters."

forward_pid=""
forward_log=""
forward_port=""
vault_token=""

stop_forward() {
  if [[ -n "$forward_pid" ]]; then
    kill "$forward_pid" >/dev/null 2>&1 || true
    wait "$forward_pid" >/dev/null 2>&1 || true
    forward_pid=""
  fi
  if [[ -n "$forward_log" && -f "$forward_log" ]]; then
    rm -f -- "$forward_log"
    forward_log=""
  fi
  forward_port=""
}

cleanup() {
  stop_forward
  local_admin_password=""
  vault_token=""
  unset LOCAL_ADMIN_PASSWORD local_admin_password vault_token
}
trap cleanup EXIT INT TERM

start_forward() {
  local service_name="$1"
  local remote_port="$2"
  local attempt

  stop_forward
  forward_log="$(mktemp)"
  kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 \
    "service/$service_name" ":$remote_port" >"$forward_log" 2>&1 &
  forward_pid="$!"

  for ((attempt = 1; attempt <= 100; attempt++)); do
    forward_port="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$forward_log" | head -n 1)"
    [[ -n "$forward_port" ]] && return 0
    kill -0 "$forward_pid" >/dev/null 2>&1 || {
      sed -n '1,20p' "$forward_log" >&2
      fail "Unable to forward service/$service_name."
    }
    sleep 0.2
  done

  fail "Timed out forwarding service/$service_name."
}

secret_value() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  kubectl -n "$namespace" get secret "$secret_name" \
    -o "jsonpath={.data.$key}" | base64 -d
}

vault_store() {
  local path="$1"
  local field="$2"

  { printf '%s\n' "$vault_token"; printf '%s\n' "$local_admin_password"; } | \
    kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ec '
      IFS= read -r token
      IFS= read -r value
      path="$1"
      field="$2"
      if VAULT_ADDR="$3" VAULT_TOKEN="$token" vault kv get "$path" >/dev/null 2>&1; then
        VAULT_ADDR="$3" VAULT_TOKEN="$token" vault kv patch "$path" "$field=$value" >/dev/null
      else
        VAULT_ADDR="$3" VAULT_TOKEN="$token" vault kv put "$path" "$field=$value" >/dev/null
      fi
    ' sh "$path" "$field" "$VAULT_ADDR"
}

refresh_external_secret() {
  local namespace="$1"
  local name="$2"
  if kubectl -n "$namespace" get externalsecret "$name" >/dev/null 2>&1; then
    kubectl -n "$namespace" annotate externalsecret "$name" \
      force-sync="$(date +%s%N)" --overwrite >/dev/null
  fi
}

wait_secret_value() {
  local namespace="$1"
  local secret_name="$2"
  local key="$3"
  local attempt
  local actual

  for ((attempt = 1; attempt <= 120; attempt++)); do
    actual="$(secret_value "$namespace" "$secret_name" "$key" 2>/dev/null || true)"
    [[ "$actual" == "$local_admin_password" ]] && return 0
    sleep 1
  done
  fail "Timed out waiting for $namespace/$secret_name:$key to synchronize."
}

rotate_postgres() {
  local current_password
  current_password="$(secret_value "$NAMESPACE" postgres-secret POSTGRES_PASSWORD)"
  info "Rotating PostgreSQL local superuser 'admin'..."
  { printf '%s\n' "$current_password"; printf '%s\n' "$local_admin_password"; } | \
    kubectl exec -i -n "$NAMESPACE" deployment/postgres -- sh -ec '
      IFS= read -r current_password
      IFS= read -r desired_password
      printf "%s\n" "ALTER ROLE :\"admin_user\" WITH LOGIN PASSWORD :'\''desired_password'\'';" | \
        PGPASSWORD="$current_password" psql \
          --username="$POSTGRES_USER" \
          --dbname=postgres \
          --set=ON_ERROR_STOP=1 \
          --set=admin_user="$POSTGRES_USER" \
          --set=desired_password="$desired_password" >/dev/null
    '
  vault_store secret/infra/postgres password
  unset current_password
}

rotate_mongodb() {
  local current_password
  current_password="$(secret_value "$NAMESPACE" mongodb-secret MONGO_INITDB_ROOT_PASSWORD)"
  info "Rotating MongoDB local superuser 'admin'..."
  { printf '%s\n' "$current_password"; printf '%s\n' "$local_admin_password"; } | \
    kubectl exec -i -n "$NAMESPACE" deployment/mongodb -- sh -ec '
      IFS= read -r current_password
      IFS= read -r desired_password
      export CURRENT_PASSWORD="$current_password" NEW_PASSWORD="$desired_password"
      mongosh --quiet \
        --username "$MONGO_INITDB_ROOT_USERNAME" \
        --password "$CURRENT_PASSWORD" \
        --authenticationDatabase admin \
        --eval "$1" >/dev/null
    ' sh 'db.getSiblingDB("admin").changeUserPassword(process.env.MONGO_INITDB_ROOT_USERNAME, process.env.NEW_PASSWORD)'
  vault_store secret/infra/mongodb root_password
  unset current_password
}

rotate_gitlab() {
  info "Rotating GitLab local superuser 'root'..."
  printf '%s\n' "$local_admin_password" | \
    kubectl exec -i -n "$NAMESPACE" deployment/gitlab -- bash -ec '
      IFS= read -r desired_password
      export GITLAB_DESIRED_ROOT_PASSWORD="$desired_password"
      gitlab-rails runner "$1"
    ' bash 'user = User.find_by_username!("root"); password = ENV.fetch("GITLAB_DESIRED_ROOT_PASSWORD"); user.password = password; user.password_confirmation = password; user.password_automatically_set = false; user.save!; raise "root is not an administrator" unless user.admin?'
  vault_store secret/infra/gitlab root_password
}

rotate_grafana() {
  info "Rotating Grafana local superuser 'admin'..."
  printf '%s\n' "$local_admin_password" | \
    kubectl exec -i -n "$NAMESPACE" deployment/grafana -c grafana -- \
      grafana cli --homepath /usr/share/grafana admin reset-admin-password \
        --password-from-stdin >/dev/null
  vault_store secret/infra/grafana admin_password
}

keycloak_login() {
  local username="$1"
  local password="$2"
  printf '%s' "$password" | curl --fail --silent --show-error \
    --data-urlencode client_id=admin-cli \
    --data-urlencode grant_type=password \
    --data-urlencode "username=$username" \
    --data-urlencode password@- \
    "http://127.0.0.1:$forward_port/auth/realms/master/protocol/openid-connect/token" | \
    jq -er '.access_token'
}

rotate_keycloak() {
  local admin_username current_password sso_username sso_password access_token user_id
  admin_username="$(secret_value "$NAMESPACE" keycloak-admin-secret KC_BOOTSTRAP_ADMIN_USERNAME)"
  current_password="$(secret_value "$NAMESPACE" keycloak-admin-secret KC_BOOTSTRAP_ADMIN_PASSWORD)"
  sso_username="$(secret_value "$NAMESPACE" keycloak-sso-credentials SSO_BOOTSTRAP_USERNAME)"
  sso_password="$(secret_value "$NAMESPACE" keycloak-sso-credentials SSO_BOOTSTRAP_PASSWORD)"

  info "Rotating Keycloak local bootstrap administrator '$admin_username'..."
  start_forward keycloak 8080
  access_token="$(keycloak_login "$admin_username" "$current_password" 2>/dev/null || true)"
  if [[ -z "$access_token" ]]; then
    access_token="$(keycloak_login "$sso_username" "$sso_password")"
  fi
  user_id="$(curl --fail --silent --show-error --get \
    --header "Authorization: Bearer $access_token" \
    --data-urlencode "username=$admin_username" \
    --data-urlencode exact=true \
    "http://127.0.0.1:$forward_port/auth/admin/realms/master/users" | jq -er '.[0].id')"
  jq -cn --arg password "$local_admin_password" \
    '{type:"password",value:$password,temporary:false}' | \
    curl --fail --silent --show-error --request PUT \
      --header "Authorization: Bearer $access_token" \
      --header 'Content-Type: application/json' \
      --data-binary @- \
      "http://127.0.0.1:$forward_port/auth/admin/realms/master/users/$user_id/reset-password" \
      >/dev/null
  keycloak_login "$admin_username" "$local_admin_password" >/dev/null
  stop_forward
  vault_store secret/infra/keycloak admin_password
  unset admin_username current_password sso_username sso_password access_token user_id
}

rotate_portainer() {
  local username current_password auth_response jwt user_id
  username="$(secret_value "$NAMESPACE" portainer-auth-secret ADMIN_USERNAME)"
  current_password="$(secret_value "$NAMESPACE" portainer-auth-secret ADMIN_PASSWORD)"

  info "Rotating Portainer local superuser '$username'..."
  start_forward portainer 9000
  auth_response="$(jq -cn --arg username "$username" --arg password "$current_password" \
    '{Username:$username,Password:$password}' | \
    curl --fail --silent --show-error \
      --header 'Content-Type: application/json' --data-binary @- \
      "http://127.0.0.1:$forward_port/api/auth")"
  jwt="$(jq -er '.jwt' <<<"$auth_response")"
  user_id="$(curl --fail --silent --show-error \
    --header "Authorization: Bearer $jwt" \
    "http://127.0.0.1:$forward_port/api/users/me" | jq -er '.Id')"
  jq -cn --arg current "$current_password" --arg desired "$local_admin_password" \
    '{Password:$current,NewPassword:$desired}' | \
    curl --fail --silent --show-error --request PUT \
      --header "Authorization: Bearer $jwt" \
      --header 'Content-Type: application/json' \
      --data-binary @- \
      "http://127.0.0.1:$forward_port/api/users/$user_id/passwd" >/dev/null
  jq -cn --arg username "$username" --arg password "$local_admin_password" \
    '{Username:$username,Password:$password}' | \
    curl --fail --silent --show-error \
      --header 'Content-Type: application/json' --data-binary @- \
      "http://127.0.0.1:$forward_port/api/auth" >/dev/null
  stop_forward
  vault_store secret/infra/portainer password
  unset username current_password auth_response jwt user_id
}

rotate_sonarqube() {
  local sso_email sso_username
  sso_email="$(secret_value "$NAMESPACE" keycloak-sso-credentials SSO_PRIMARY_EMAIL 2>/dev/null || true)"
  if [[ -z "$sso_email" ]]; then
    sso_username="$(secret_value "$NAMESPACE" keycloak-sso-credentials SSO_BOOTSTRAP_USERNAME)"
    if [[ "$sso_username" == *"@"* ]]; then
      sso_email="$sso_username"
    else
      sso_email="${sso_username}@swirlit.dev"
    fi
  fi
  info "Rotating SonarQube local superuser 'admin'..."
  start_forward sonarqube 9000
  printf '%s' "$local_admin_password" | \
    curl --fail --silent --show-error --request POST \
      --header "X-Auth-Request-Email: $sso_email" \
      --header 'X-Auth-Request-Groups: platform-admins' \
      --data-urlencode login=admin \
      --data-urlencode password@- \
      "http://127.0.0.1:$forward_port/api/users/change_password" >/dev/null
  curl --fail --silent --show-error --user "admin:$local_admin_password" \
    "http://127.0.0.1:$forward_port/api/authentication/validate" | \
    jq -e '.valid == true' >/dev/null
  stop_forward
  vault_store secret/infra/sonarqube admin_password
  unset sso_email sso_username
}

set_elasticsearch_password() {
  local username="$1"
  local current_elastic_password="$2"
  jq -cn --arg password "$local_admin_password" '{password:$password}' | \
    curl --fail --silent --show-error --request POST \
      --user "elastic:$current_elastic_password" \
      --header 'Content-Type: application/json' \
      --data-binary @- \
      "http://127.0.0.1:$forward_port/_security/user/$username/_password" >/dev/null
}

rotate_elasticsearch() {
  local current_elastic_password
  current_elastic_password="$(secret_value "$NAMESPACE" elasticsearch-security-bootstrap ELASTIC_PASSWORD)"
  info "Rotating Elasticsearch local superusers 'admin' and 'elastic'..."
  start_forward elasticsearch 9200
  set_elasticsearch_password admin "$current_elastic_password"
  set_elasticsearch_password elastic "$current_elastic_password"
  curl --fail --silent --show-error --user "admin:$local_admin_password" \
    "http://127.0.0.1:$forward_port/_security/_authenticate" >/dev/null
  curl --fail --silent --show-error --user "elastic:$local_admin_password" \
    "http://127.0.0.1:$forward_port/_security/_authenticate" >/dev/null
  stop_forward
  vault_store secret/infra/elasticsearch admin_password
  vault_store secret/infra/elasticsearch elastic_password
  unset current_elastic_password
}

rollout_restart() {
  local deployment="$1"
  local timeout="${2:-300s}"
  kubectl -n "$NAMESPACE" rollout restart "deployment/$deployment" >/dev/null
  kubectl -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout="$timeout"
}

sudo -n test -s "$VAULT_BOOTSTRAP_TOKEN_FILE" || \
  fail "Missing readable Vault bootstrap token: $VAULT_BOOTSTRAP_TOKEN_FILE"
vault_token="$(sudo -n cat "$VAULT_BOOTSTRAP_TOKEN_FILE")"

start_reached=false
for service_name in postgres mongodb gitlab grafana keycloak portainer sonarqube elasticsearch; do
  if [[ "$service_name" == "$start_at" ]]; then
    start_reached=true
  fi
  [[ "$start_reached" == true ]] || continue
  "rotate_$service_name"
done

info "Synchronizing Vault-backed Kubernetes Secrets..."
refresh_external_secret "$NAMESPACE" postgres-secret
refresh_external_secret "$NAMESPACE" mongodb-secret
refresh_external_secret "$NAMESPACE" grafana-admin-secret
refresh_external_secret "$NAMESPACE" keycloak-admin-secret
refresh_external_secret "$NAMESPACE" portainer-auth-secret
refresh_external_secret "$NAMESPACE" elasticsearch-security-bootstrap
refresh_external_secret apps odoo-secret

wait_secret_value "$NAMESPACE" postgres-secret POSTGRES_PASSWORD
wait_secret_value "$NAMESPACE" mongodb-secret MONGO_INITDB_ROOT_PASSWORD
wait_secret_value "$NAMESPACE" grafana-admin-secret GF_SECURITY_ADMIN_PASSWORD
wait_secret_value "$NAMESPACE" keycloak-admin-secret KC_BOOTSTRAP_ADMIN_PASSWORD
wait_secret_value "$NAMESPACE" portainer-auth-secret ADMIN_PASSWORD
wait_secret_value "$NAMESPACE" elasticsearch-security-bootstrap ADMIN_PASSWORD
wait_secret_value "$NAMESPACE" elasticsearch-security-bootstrap ELASTIC_PASSWORD

info "Restarting password consumers with synchronized Secrets..."
rollout_restart postgres
rollout_restart mongodb
rollout_restart elasticsearch 600s
rollout_restart grafana
rollout_restart keycloak
rollout_restart dbgate
rollout_restart portainer

info "Local infrastructure administrator password rotation completed."
info "Excluded by design: applications, SSO identities, Argo CD (local admin disabled), Vault tokens, proxy Basic Auth, DBGate, Kafka UI, Longhorn, Homepage, Prometheus, Redis, and Kafka."
