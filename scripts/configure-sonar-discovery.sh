#!/usr/bin/env bash
# Provision the namespace discovery credential without changing project visibility.
set -euo pipefail
set +x
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info() { printf '[INFO] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
# shellcheck source=lib/gitlab-admin-token.sh
source "$script_dir/lib/gitlab-admin-token.sh"
# shellcheck source=lib/vault-access.sh
source "$script_dir/lib/vault-access.sh"
VAULT_POD="$(vault_runtime_pod infra)"
export VAULT_POD
GITLAB_BOOTSTRAP_TOKEN_NAME=bm-cluster-sonar-discovery-bootstrap
trap gitlab_revoke_ephemeral_admin_token EXIT
gitlab_acquire_admin_token
python3 - <<'PY'
import datetime, json, os, subprocess, urllib.parse, urllib.request, urllib.error

def kubectl(*args, **kw):
    return subprocess.check_output(['kubectl', *args], **kw)
namespace = os.environ.get('GITLAB_NAMESPACE', 'infra')
service = json.loads(kubectl('-n', namespace, 'get', 'service', 'gitlab', '-o', 'json'))
base = os.environ.get('GITLAB_API_URL', 'http://' + service['spec']['clusterIP'] + '/api/v4')
def api(method, path, data=None, token=None):
    request = urllib.request.Request(base + '/' + path,
        data=None if data is None else json.dumps(data).encode(), method=method,
        headers={'PRIVATE-TOKEN':token or os.environ['GITLAB_ADMIN_TOKEN'], 'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read() or '{}')
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'{method} {path}: HTTP {error.code}') from None
vault_token = subprocess.check_output(['sudo','cat',os.environ.get('VAULT_TOKEN_FILE','/var/lib/bm-cluster/vault-bootstrap-token')]).decode().strip()
def vault(script, values=()):
    return kubectl('-n','infra','exec','-i',os.environ['VAULT_POD'],'--','sh','-ceu',
        'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; ' + script,
        input=('\n'.join([vault_token,*values])+'\n').encode()).decode().strip()
old = vault('vault kv get -field=sonar_discovery_api_token secret/infra/gitlab 2>/dev/null || true')
if old:
    try:
        current = api('GET','personal_access_tokens/self',token=old)
        expiry = datetime.date.fromisoformat(current['expires_at'])
        if expiry > datetime.date.today() + datetime.timedelta(days=30):
            print('Sonar discovery group token is valid through ' + current['expires_at'])
            raise SystemExit(0)
    except (RuntimeError, ValueError, KeyError):
        pass
group_path = os.environ.get('GITLAB_GROUP_PATH','swirlit')
group = api('GET','groups/'+urllib.parse.quote(group_path,safe=''))
name = 'bm-cluster-sonar-apps-discovery'
# Keep prior tokens until the replacement is safely written to Vault.
previous = api('GET',f'groups/{group["id"]}/access_tokens?per_page=100')
created = api('POST',f'groups/{group["id"]}/access_tokens', {
    'name':name, 'access_level':40, 'scopes':['api'],
    'expires_at':str(datetime.date.today()+datetime.timedelta(days=364)),
})
vault('IFS= read -r discovery_token; vault kv patch secret/infra/gitlab sonar_discovery_api_token="$discovery_token" >/dev/null', [created['token']])
# Refresh ESO before revoking an older credential.
subprocess.run(['kubectl','-n','infra','annotate','externalsecret','sonar-apps-discovery-token',
    'force-sync='+str(int(datetime.datetime.now().timestamp())),'--overwrite'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
for token in previous:
    if token['name']==name and not token.get('revoked'):
        api('DELETE',f'groups/{group["id"]}/access_tokens/{token["id"]}')
print('Dedicated group Maintainer API token stored in Vault; expires ' + created['expires_at'])
PY
