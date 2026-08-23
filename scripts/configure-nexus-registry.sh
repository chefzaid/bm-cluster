#!/bin/bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-infra}"
NEXUS_DEPLOYMENT="${NEXUS_DEPLOYMENT:-nexus}"
NEXUS_SERVICE="${NEXUS_SERVICE:-nexus}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_TOKEN_FILE="${VAULT_BOOTSTRAP_TOKEN_FILE:-/var/lib/bm-cluster/vault-bootstrap-token}"
REGISTRY_REPOSITORY="${REGISTRY_REPOSITORY:-docker-hosted}"
PUSH_USERNAME="${PUSH_USERNAME:-jenkins-registry}"
PULL_USERNAME="${PULL_USERNAME:-devapp-registry}"
DEPENDENCY_USERNAME="${DEPENDENCY_USERNAME:-jenkins-dependencies}"

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
generate_secret() { openssl rand -hex 24; }

for command_name in kubectl curl jq openssl sudo; do
  command -v "$command_name" >/dev/null || fail "$command_name is required"
done

kubectl rollout status deployment/"$NEXUS_DEPLOYMENT" -n "$NAMESPACE" --timeout=10m >/dev/null
sudo test -s "$VAULT_TOKEN_FILE" || fail "Vault bootstrap token is missing from $VAULT_TOKEN_FILE"

NEXUS_ADMIN_PASSWORD="${NEXUS_ADMIN_PASSWORD:-}"
if [[ -z "$NEXUS_ADMIN_PASSWORD" ]]; then
  NEXUS_ADMIN_PASSWORD="$(kubectl exec -n "$NAMESPACE" deployment/"$NEXUS_DEPLOYMENT" -- \
    cat /nexus-data/admin.password 2>/dev/null || true)"
fi
[[ -n "$NEXUS_ADMIN_PASSWORD" ]] || fail "Set NEXUS_ADMIN_PASSWORD; Nexus has no readable initial admin password"

nexus_ip="$(kubectl get service "$NEXUS_SERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')"
nexus_api="http://$nexus_ip:8081/service/rest/v1"
work_dir="$(mktemp -d)"
chmod 0700 "$work_dir"
trap 'rm -rf -- "$work_dir"; unset NEXUS_ADMIN_PASSWORD vault_token push_password pull_password dependency_password' EXIT

nexus_request() {
  local method="$1"
  local path="$2"
  local payload_file="${3:-}"
  local content_type="${4:-application/json}"
  local config_file="$work_dir/curl-config"

  umask 077
  {
    printf 'silent\nshow-error\nuser = "admin:%s"\n' "$NEXUS_ADMIN_PASSWORD"
    printf 'request = "%s"\nurl = "%s/%s"\n' "$method" "$nexus_api" "$path"
  } > "$config_file"

  if [[ -n "$payload_file" ]]; then
    curl --config "$config_file" --header "Content-Type: $content_type" \
      --data-binary "@$payload_file" --output /dev/null --write-out '%{http_code}'
  else
    curl --config "$config_file" --output /dev/null --write-out '%{http_code}'
  fi
}

nexus_get() {
  local path="$1"
  local config_file="$work_dir/curl-config-get"
  umask 077
  {
    printf 'silent\nshow-error\nfail\nuser = "admin:%s"\n' "$NEXUS_ADMIN_PASSWORD"
    printf 'url = "%s/%s"\n' "$nexus_api" "$path"
  } > "$config_file"
  curl --config "$config_file"
}

expect_status() {
  local status="$1"
  shift
  case "$status" in
    200|201|204) ;;
    *) fail "Nexus API returned HTTP $status while configuring $*" ;;
  esac
}

vault_token="$(sudo cat "$VAULT_TOKEN_FILE")"
registry_secret_json="$({ printf '%s\n' "$vault_token"; } | \
  kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
    IFS= read -r VAULT_TOKEN
    export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
    vault kv get -format=json secret/infra/registry 2>/dev/null || true
  ')"

push_password="$(jq -r '.data.data.push_password // empty' <<<"$registry_secret_json")"
pull_password="$(jq -r '.data.data.pull_password // empty' <<<"$registry_secret_json")"
dependency_password="$(jq -r '.data.data.dependency_password // empty' <<<"$registry_secret_json")"
[[ -n "$push_password" ]] || push_password="$(generate_secret)"
[[ -n "$pull_password" ]] || pull_password="$(generate_secret)"
[[ -n "$dependency_password" ]] || dependency_password="$(generate_secret)"

jq -cn \
  --arg push_username "$PUSH_USERNAME" --arg push_password "$push_password" \
  --arg pull_username "$PULL_USERNAME" --arg pull_password "$pull_password" \
  --arg dependency_username "$DEPENDENCY_USERNAME" --arg dependency_password "$dependency_password" \
  '{data:{push_username:$push_username,push_password:$push_password,pull_username:$pull_username,pull_password:$pull_password,dependency_username:$dependency_username,dependency_password:$dependency_password}}' \
  > "$work_dir/vault-registry.json"
{
  printf '%s\n' "$vault_token"
  cat "$work_dir/vault-registry.json"
} | kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
  IFS= read -r VAULT_TOKEN
  IFS= read -r payload
  export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
  printf "%s" "$payload" | vault write secret/data/infra/registry - >/dev/null
'
unset registry_secret_json

eula_json="$(nexus_get system/eula)"
eula_accepted="$(jq -r '.accepted // false' <<<"$eula_json")"
if [[ "$eula_accepted" != "true" ]]; then
  info "Accepting the Nexus Community Edition EULA required to enable repository traffic"
  jq '.accepted=true' <<<"$eula_json" > "$work_dir/eula.json"
  status="$(nexus_request POST system/eula "$work_dir/eula.json")"
  expect_status "$status" "Community Edition EULA"
fi
unset eula_json

if ! nexus_get repositories | jq -e --arg name "$REGISTRY_REPOSITORY" '.[] | select(.name==$name)' >/dev/null; then
  info "Creating the private Docker registry repository"
  jq -n --arg name "$REGISTRY_REPOSITORY" '{
    name:$name, online:true,
    storage:{blobStoreName:"default",strictContentTypeValidation:true,writePolicy:"ALLOW_ONCE",latestPolicy:false},
    docker:{v1Enabled:false,forceBasicAuth:true,httpPort:5000,httpsPort:null,subdomain:null}
  }' > "$work_dir/repository.json"
  status="$(nexus_request POST repositories/docker/hosted "$work_dir/repository.json")"
  expect_status "$status" "registry repository"
fi

if ! nexus_get repositories | jq -e '.[] | select(.name=="npm-proxy")' >/dev/null; then
  info "Creating the npmjs.org proxy repository"
  jq -n '{
    name:"npm-proxy",online:true,
    storage:{blobStoreName:"default",strictContentTypeValidation:true},
    proxy:{remoteUrl:"https://registry.npmjs.org",contentMaxAge:1440,metadataMaxAge:1440},
    negativeCache:{enabled:true,timeToLive:1440},
    httpClient:{blocked:false,autoBlock:true}
  }' > "$work_dir/npm-proxy.json"
  status="$(nexus_request POST repositories/npm/proxy "$work_dir/npm-proxy.json")"
  expect_status "$status" "npm proxy repository"
fi

if ! nexus_get repositories | jq -e '.[] | select(.name=="npm-group")' >/dev/null; then
  info "Creating the npm repository group"
  jq -n '{
    name:"npm-group",online:true,
    storage:{blobStoreName:"default",strictContentTypeValidation:true},
    group:{memberNames:["npm-proxy"]}
  }' > "$work_dir/npm-group.json"
  status="$(nexus_request POST repositories/npm/group "$work_dir/npm-group.json")"
  expect_status "$status" "npm group repository"
fi

configure_role() {
  local role_id="$1"
  local description="$2"
  shift 2
  local privileges_json method path status
  privileges_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  jq -n --arg id "$role_id" --arg description "$description" --argjson privileges "$privileges_json" \
    '{id:$id,name:$id,description:$description,privileges:$privileges,roles:[]}' > "$work_dir/role.json"
  if nexus_get security/roles | jq -e --arg id "$role_id" '.[] | select(.id==$id)' >/dev/null; then
    method=PUT
    path="security/roles/$role_id"
  else
    method=POST
    path=security/roles
  fi
  status="$(nexus_request "$method" "$path" "$work_dir/role.json")"
  expect_status "$status" "role $role_id"
}

configure_role nx-devapp-registry-push "Push only to the DevApp private registry" \
  "nx-repository-view-docker-$REGISTRY_REPOSITORY-add" \
  "nx-repository-view-docker-$REGISTRY_REPOSITORY-browse" \
  "nx-repository-view-docker-$REGISTRY_REPOSITORY-edit" \
  "nx-repository-view-docker-$REGISTRY_REPOSITORY-read"
configure_role nx-devapp-registry-pull "Pull only from the DevApp private registry" \
  "nx-repository-view-docker-$REGISTRY_REPOSITORY-browse" \
  "nx-repository-view-docker-$REGISTRY_REPOSITORY-read"
configure_role nx-jenkins-dependency-read "Read build dependencies through Nexus groups" \
  "nx-repository-view-maven2-maven-public-browse" \
  "nx-repository-view-maven2-maven-public-read" \
  "nx-repository-view-npm-npm-group-browse" \
  "nx-repository-view-npm-npm-group-read"

configure_user() {
  local user_id="$1"
  local password="$2"
  local role="$3"
  local method path status
  if nexus_get security/users | jq -e --arg id "$user_id" '.[] | select(.userId==$id)' >/dev/null; then
    method=PUT
    path="security/users/$user_id"
    jq -n --arg id "$user_id" --arg role "$role" '{
      userId:$id,firstName:$id,lastName:"service account",
      emailAddress:($id+"@invalid.local"),source:"default",status:"active",roles:[$role]
    }' > "$work_dir/user.json"
  else
    method=POST
    path=security/users
    jq -n --arg id "$user_id" --arg password "$password" --arg role "$role" '{
      userId:$id,firstName:$id,lastName:"service account",
      emailAddress:($id+"@invalid.local"),password:$password,status:"active",roles:[$role]
    }' > "$work_dir/user.json"
  fi
  status="$(nexus_request "$method" "$path" "$work_dir/user.json")"
  expect_status "$status" "service account $user_id"
  printf '%s' "$password" > "$work_dir/password"
  status="$(nexus_request PUT "security/users/$user_id/change-password" "$work_dir/password" text/plain)"
  expect_status "$status" "password for service account $user_id"
}

configure_user "$PUSH_USERNAME" "$push_password" nx-devapp-registry-push
configure_user "$PULL_USERNAME" "$pull_password" nx-devapp-registry-pull
configure_user "$DEPENDENCY_USERNAME" "$dependency_password" nx-jenkins-dependency-read

nexus_get security/realms/active | jq 'if index("DockerToken") then . else .+["DockerToken"] end' > "$work_dir/realms.json"
status="$(nexus_request PUT security/realms/active "$work_dir/realms.json")"
expect_status "$status" "Docker token realm"

npm_auth="$(printf '%s:%s' "$DEPENDENCY_USERNAME" "$dependency_password" | base64 | tr -d '\n')"
cat > "$work_dir/settings.xml" <<EOF
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
  <mirrors>
    <mirror>
      <id>nexus-maven-public</id>
      <mirrorOf>*</mirrorOf>
      <url>http://nexus.swirlit.local:8081/repository/maven-public/</url>
    </mirror>
  </mirrors>
  <servers>
    <server>
      <id>nexus-maven-public</id>
      <username>$DEPENDENCY_USERNAME</username>
      <password>$dependency_password</password>
    </server>
  </servers>
</settings>
EOF
cat > "$work_dir/npmrc" <<EOF
registry=http://nexus.swirlit.local:8081/repository/npm-group/
//nexus.swirlit.local:8081/repository/npm-group/:_auth=$npm_auth
EOF
jq -cn --rawfile settings_xml "$work_dir/settings.xml" --rawfile npmrc "$work_dir/npmrc" \
  '{data:{settings_xml:$settings_xml,npmrc:$npmrc}}' > "$work_dir/vault-jenkins.json"
{
  printf '%s\n' "$vault_token"
  cat "$work_dir/vault-jenkins.json"
} | kubectl exec -i -n "$NAMESPACE" "$VAULT_POD" -- sh -ceu '
  IFS= read -r VAULT_TOKEN
  IFS= read -r payload
  export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
  printf "%s" "$payload" | vault write secret/data/infra/jenkins - >/dev/null
'
unset npm_auth dependency_password

info "Nexus registry, least-privilege accounts, Docker realm, and Vault credentials are configured."
