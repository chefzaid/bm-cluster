# Security and access

Vault owns infrastructure credentials; External Secrets supplies namespace-scoped
Kubernetes Secrets. Keep credentials, local environment files, setup tokens and
recovery material outside Git. Rotate bootstrap credentials and revoke temporary
setup tokens after use. See [Vault operations](vault.md) for audit, unseal and
recovery procedures, and [image maintenance](security-images.md) for container
updates and Trivy findings.

## Host policy

Installer and Ansible use [configure-node-security.sh](../scripts/configure-node-security.sh).
Transport setup and required private ports are covered in [networking](networking.md).

| Node | Installed host controls |
| --- | --- |
| Internet-facing control plane | UFW, Lynis, Fail2ban, CrowdSec and SSH hardening. |
| Local/private control plane | UFW and Lynis. |
| Worker | UFW; no Fail2ban, CrowdSec or persistent Lynis installation. |

Internet-facing control planes retain password SSH, disable root SSH and limit
authentication attempts and connection bursts. Fail2ban escalates repeat bans;
CrowdSec also detects slow brute-force and user-enumeration patterns. The shared
script owns ban periods, authentication-log retention and rules. Follow
[the private SSH preflight](networking.md) before applying a node's firewall.

## Host audits

Control planes run `bm-cluster-lynis.timer`. Check its next run and inspect the
root-only reports under `/var/log/lynis-reports`; the latest report is
`/var/log/lynis-report.dat`. Schedule and archive retention are maintained in
[configure-lynis-schedule.sh](../scripts/configure-lynis-schedule.sh).

```sh
systemctl list-timers bm-cluster-lynis.timer
bm-cluster-audit-nodes
```

Run the audit assistant with the user and SSH identity used for enrollment.
It discovers workers, asks for SSH settings, temporarily copies Lynis to each
worker, runs it with passwordless `sudo`, retrieves reports into
`~/.local/state/bm-cluster/lynis-reports`, and removes the temporary copy.
Use `--targets user@host,user@host` for explicit targets or `--help` for automation.
Filebeat ships control-plane findings to Kibana's **Lynis Security Audits**
dashboard; audit retention is separate from ordinary logs.

## Administrator sign-in

Normal browser access uses the administrator login selected during installation.
[Keycloak reconciliation](../k8s/platform/keycloak-sso.yaml) maintains matching
managed identities in `master` and `swirlit`. A username gets the primary email
`<username>@<your-domain>`; an email login stays unchanged. The `master` identity
can administer every realm at
`https://keycloak.<your-domain>/auth/admin/master/console/`.

Membership in `platform-admins` grants broad platform administration. Native
OIDC integrations establish service sessions where supported. Other UIs use the
Keycloak proxy boundary; administrative public hosts also sit behind Cloudflare
Access. Internal automation retains token-based endpoints. See [networking](networking.md)
for the hostname inventory and boundary configuration.

| Service | Managed administrator access |
| --- | --- |
| Keycloak | Master `admin` and `swirlit` realm administration. |
| GitLab | Existing canonical `root` instance administrator. |
| Grafana / Argo CD | Grafana server administrator / Argo CD `role:admin`. |
| Vault | `platform-admin`, including all paths and `sudo`. |
| Portainer | Application administrator and Kubernetes `cluster-admin`. |
| Odoo / SonarQube | Existing Odoo Settings administrator / Sonar global administration. |
| Kibana / Elasticsearch | A distinct named Elastic identity with `superuser`. |
| DBGate / Kafka UI | Database administrator connections / full Kafka write access. |
| Longhorn / Homepage | Full UI access through the administrator gate. |

GitLab links SSO to its existing root account, preserving project ownership;
its bootstrap removes a duplicate matching the selected login. Profile sync
preserves locally edited GitLab names. Kibana validates the signed session and
keeps individual profiles, favorites and preferences. Its reconciler disables
managed identities that leave `platform-admins`; the dashboard-import account
is separate from browser identities. Give automation only its required service
credentials rather than this full administrator access.

## Recovery credentials

Read credentials only in a private terminal. For example, retrieve the managed
SSO login or password individually from `infra/keycloak-sso-credentials` using
keys `SSO_BOOTSTRAP_USERNAME` and `SSO_BOOTSTRAP_PASSWORD`:

```sh
kubectl get secret -n infra keycloak-sso-credentials \
  -o jsonpath='{.data.SSO_BOOTSTRAP_USERNAME}' | base64 -d
```

The same command works with the namespace, Secret and key below. These local
credentials serve recovery or automation; normal access uses SSO.

| Service | Namespace / Secret | Password key |
| --- | --- | --- |
| Grafana | `infra/grafana-admin-secret` | `GF_SECURITY_ADMIN_PASSWORD` |
| Keycloak bootstrap | `infra/keycloak-admin-secret` | `KC_BOOTSTRAP_ADMIN_PASSWORD` |
| Elasticsearch `admin` / `elastic` | `infra/elasticsearch-security-bootstrap` | `ADMIN_PASSWORD` / `ELASTIC_PASSWORD` |
| MongoDB | `infra/mongodb-secret` | `MONGO_INITDB_ROOT_PASSWORD` |
| PostgreSQL | `infra/postgres-secret` | `POSTGRES_PASSWORD` |
| Portainer | `infra/portainer-auth-secret` | `ADMIN_PASSWORD` |
| Odoo | `corp/odoo-secret` | `ODOO_ADMIN_PASSWORD` |

Username fields and Vault mappings live with the
[ExternalSecrets](../k8s/platform/vault.yaml) and [Odoo manifest](../k8s/corp/odoo.yaml).
Vault's `secret` KV engine also holds these recovery and automation fields:

| Service | Path | Field |
| --- | --- | --- |
| GitLab | `infra/gitlab` | `root_password` |
| SonarQube | `infra/sonarqube` | `admin_password`, `admin_token` |
| Longhorn origin login | `infra/platform-ui` | `password` |

Use Vault's authenticated UI to read those fields. During an SSO outage, reach
Vault locally with `kubectl port-forward -n infra service/vault 8200:8200` and
open `http://127.0.0.1:8200/ui`. Its Token login accepts the root-only recovery
token stored at `/var/lib/bm-cluster/vault-bootstrap-token`. Keep it out of
command arguments and logs. Argo CD's local `admin` is disabled; DBGate, Kafka UI,
Longhorn and Homepage rely on their authentication boundary.

## Rotate local administrator passwords

The optional installer rotation step aligns infrastructure-local administrator
passwords. It does not run implicitly in unattended `--yes` installs; automation
must set `ROTATE_LOCAL_ADMIN_PASSWORDS=true` and provide `LOCAL_ADMIN_PASSWORD`
through its secret environment. To run it later in Bash:

```bash
read -rsp 'Local administrator password: ' LOCAL_ADMIN_PASSWORD
printf '\n'
printf '%s\n' "$LOCAL_ADMIN_PASSWORD" | \
  scripts/rotate-local-admin-passwords.sh --password-stdin
unset LOCAL_ADMIN_PASSWORD
```

[The rotation helper](../scripts/rotate-local-admin-passwords.sh) updates service
credentials, persists them in Vault, refreshes External Secrets, restarts affected
consumers and checks availability. Application users, Keycloak SSO identities,
API tokens and ingress Basic Auth credentials have separate lifecycles.
