# Bare-Metal Cluster

Single- or multi-node K3s infrastructure for development and self-hosted platform
services. The repository installs the control plane and workers, storage, ingress,
security tools, secrets management, data stores, observability, CI/CD tools, and
Odoo.

## Components

- K3s, NGINX Ingress, Longhorn, and the Descheduler addon
- Vault and External Secrets Operator
- PostgreSQL, MongoDB, Redis, and Kafka in KRaft mode
- Keycloak, GitLab CI/CD, GitLab Container and Package Registries, ArgoCD, and SonarQube
- Prometheus, Grafana, Elasticsearch, Logstash, and Kibana
- DBGate, Kafbat UI, Portainer CE, and Odoo Community
- Homepage service catalog and Kubernetes status dashboard
- UFW on every node, Fail2ban and CrowdSec on the internet-facing control plane, and control-plane Lynis audits

## Architecture

Public HTTPS traffic enters only through the control-plane NGINX LoadBalancer and is routed by
hostname to ClusterIP services. Cloudflare provides public DNS and edge TLS;
NGINX uses a wildcard Cloudflare Origin CA certificate for strict end-to-end
TLS.

Vault is the source of infrastructure credentials. External Secrets syncs those
values into namespace-scoped Kubernetes Secrets. Longhorn provides persistent
storage. Prometheus collects node, Kubernetes object, pod, container, and
annotation-enabled application metrics; Grafana includes a provisioned cluster
dashboard and loads application-owned dashboards from labeled ConfigMaps.
Fluent Bit ships Kubernetes container logs with namespace, pod, container, and
label metadata to Elasticsearch for Kibana discovery.

PostgreSQL 18 is shared by the compatible applications, including Keycloak,
Odoo, and SonarQube. GitLab keeps its bundled PostgreSQL 17 because GitLab 19
does not support PostgreSQL 18.

Databases, caches, queues, and search backends remain internal Kubernetes
services and are not published through public DNS.

DBGate is preconfigured from Kubernetes Secrets with access to every logical
database in the PostgreSQL cluster, plus MongoDB and Redis. Kafka administration
is available through Kafbat UI, while Elasticsearch administration remains in
Kibana. Portainer manages the local Kubernetes environment and automatically
discovers workloads, services, pods, storage, and namespaces across the cluster.

Homepage is the single entry point for every installed application, platform
tool, internal data service, observability component, security tool, and
Kubernetes system service. Public entries are clickable; internal-only entries
show their purpose and live Kubernetes status without exposing them publicly.
This repository owns Odoo in the shared `apps` namespace. DevApp, Thoughty, and
Indezy publish their dashboard entries from their own Kubernetes Ingress
annotations, without adding application-specific runtime resources here. Their
public hostnames remain part of the central Cloudflare inventory so DNS and edge
configuration are reproducible from this repository.

## Service dashboard

Open `https://dashboard.swirlit.dev` for the complete categorized service
catalog; the zone apex redirects there. Cloudflare Access protects the
administrative host inventory in `config/platform.env` with an email one-time
PIN and a 24-hour session.
Cluster automation uses internal Kubernetes service names, so these public
administration hostnames can remain protected without blocking builds,
deployments, package downloads, or scans.

### Internal service DNS

Cluster workloads use the private `swirlit.internal` DNS zone. CoreDNS maps every
`<name>.swirlit.internal` query to the same Service name in the `infra` namespace,
preserving additional labels for headless services such as
`kafka-controller-0.kafka-controller.swirlit.internal`. Curated aliases map
`longhorn.swirlit.internal` into `longhorn-system`; application-owned services
use their canonical Kubernetes DNS names.

The zone is cluster-only: it is not published by Cloudflare and is not expected
to resolve on the public Internet or from ordinary host tools. K3s/containerd
maps `registry.swirlit.dev` to a fixed internal Registry service endpoint. The
Dependency Proxy retains its canonical `gitlab.swirlit.dev` HTTPS route because
containerd's mirror query parameter interferes with GitLab Workhorse cache
uploads. Kubernetes API endpoints retain their canonical
`kubernetes.default.svc` identity because that name is covered by the API server
certificate.

Public Docker clients also use `registry.swirlit.dev`. Cloudflare reconciliation
keeps the hostname proxied but prevents browser-only bot challenges from
intercepting the Registry API: basic Bot Fight Mode is disabled because it has
no hostname exceptions, while Super Bot Fight Mode is skipped only for the
Registry hostname. Custom WAF rules, rate limiting, strict TLS, and Cloudflare
DDoS protection remain enabled. The setup token therefore needs `Bot Management
Read` and `Bot Management Edit` zone permissions in addition to the permissions
printed by the configurator.

### GitLab delivery

The infrastructure repository lives at `swirlit/bm-cluster` in GitLab.
Its instance-scoped Kubernetes runner executes `.gitlab-ci.yml` in the isolated
`gitlab-runners` namespace. The default branch is continuously reconciled by
the `bm-cluster` Argo CD Application; application manifests under `k8s/apps`
remain outside this infrastructure GitOps boundary.

GitHub and GitLab branches and tags are synchronized after every push. GitHub
pushes start `.github/workflows/sync-gitlab.yml` directly; GitLab push and tag
webhooks call GitHub's repository-dispatch endpoint and start the same
reconciler, even when a commit skips CI. It fast-forwards the lagging side,
merges divergent branches without force pushing, and refuses conflicting tag
rewrites. A monthly schedule self-rotates the managed GitLab credential into
the encrypted GitHub secret before expiry.

GitLab stores private OCI images at `registry.swirlit.dev`. Application
pipelines retain downloadable job artifacts for seven days and publish
immutable release outputs through each project's Generic Package Registry:
DevApp publishes two JARs and its SPA archive, Thoughty publishes server and web
archives, and Indezy publishes its JAR and SPA archive. Every package version
also contains `SHA256SUMS`. These are visible under **Deploy > Package Registry**;
the Container Registry UI intentionally shows only images and Kaniko cache
repositories.

The infrastructure pipeline pins its Alpine base by Docker Hub digest; the
K3s/containerd `IfNotPresent` policy reuses the node-local copy without relying
on mutable Dependency Proxy cache metadata. The group Dependency Proxy remains
available for non-critical upstream image acceleration. Application Maven/npm
dependencies resolve from their public upstreams and use the runner's persistent
5 GiB build cache. Application image jobs can rebuild their disposable Kaniko
layers as needed. A cold pipeline must still compile, test, upload immutable
outputs, and roll out workloads, while later pipelines avoid most unchanged
dependency work. This provides practical reuse without operating a separate
repository manager.

The three application repositories use one bootstrap contract:

| Project | Argo CD bootstrap | Desired state |
|---|---|---|
| `swirlit/devapp` | `infra/argocd/application.yaml` | `infra/k8s` |
| `swirlit/thoughty` | `infra/argocd/application.yaml` | `infra/k8s/overlays/bm-cluster` |
| `swirlit/indezy` | `infra/argocd/application.yaml` | `infra/k8s` |

Their pipelines use the internal `gitlab.swirlit.internal` API/clone route and
the internal Registry service for cluster traffic, while user-facing GitLab and
Registry URLs remain `gitlab.swirlit.dev` and `registry.swirlit.dev`. Each app
repository owns its GitLab bootstrap, Vault contracts, Argo CD Application, and
runtime manifests; `bm-cluster` owns only the generic runner and shared platform.

Registry retention is declared in `k8s/platform/gitlab-registry-retention.yaml`.
Every day it reconciles GitLab's native container-image cleanup policy for all
projects in the SwirlIT group and removes Package Registry versions created more
than 1,095 days ago. GitLab continues to protect protected container tags and
the literal `latest` tag. The group-scoped API token is stored in Vault at
`secret/infra/gitlab`, projected by External Secrets, and never committed.

GitLab and the runner expose Prometheus metrics through pod annotations. The
provisioned GitLab Delivery dashboard is loaded by Grafana, and Fluent Bit ships
their JSON container logs into the existing Elasticsearch/Kibana pipeline.

Create administrator tokens for the one-time GitLab and GitHub bootstrap, then
run:

```bash
GITLAB_ADMIN_TOKEN='...' \
GITHUB_ADMIN_TOKEN='...' \
  ./scripts/configure-gitlab-ci.sh
```

The script creates or reconciles the group, project, Dependency Proxy, image
retention policy, instance runner, encrypted repository-sync credentials, and
GitLab repository-dispatch webhook. It stores the runner authentication token
and a group-scoped registry-retention API token in Vault; no credential is
committed.

The catalog, icons, Kubernetes read-only status integration, Deployment,
Service, and Ingress are defined together in `k8s/platform/homepage.yaml`. Both
the interactive installer and `ansible/deploy.yml` apply it automatically.

## Quick start

Requirements:

- Ubuntu 22.04 or newer
- 8 or more CPUs, 32 GB or more RAM, and 250 GB or more disk
- A sudo-capable non-root user
- A domain registered for public deployments
- SSH keys and passwordless `sudo` from the control plane to every worker

For a new cluster, run the guided installer on the future control-plane host:

```bash
./install-control-plane.sh
```

It first asks whether to install `infra` only or `infra + apps`. The apps choice
deploys Odoo, the repository-owned ERP/CRM workload.
When platform services are selected, it asks for a platform administrator
login and a confirmed hidden password. That identity is provisioned through
Keycloak as administrator for every integrated service and application. The
password must contain at least 12 characters with lowercase, uppercase,
numeric, and special characters.
It then asks which infrastructure features to install and, when workers are
selected, starts the vRack or Tailscale prerequisite wizard before any UFW
change. Each wizard shows the exact account page, pauses while you complete the
manual account step, collects secrets with hidden input, checks the account
read-only, and resumes. Nothing is persisted. `./install-control-plane.sh --yes`
defaults to `infra + apps`; set `INSTALL_SCOPE=infra` for an infrastructure-only
non-interactive run. Non-interactive platform installation also requires
`KEYCLOAK_SSO_BOOTSTRAP_USERNAME` and `KEYCLOAK_SSO_BOOTSTRAP_PASSWORD`.
Selected identity and transport secrets are supplied as environment variables.

## Adding worker nodes

Worker enrollment is built into `install-control-plane.sh`. Answer **yes** to
adding workers, choose **OVHcloud-only vRack** or **Tailscale for
hybrid/non-OVHcloud providers**, then enter any number of workers. Use one
transport consistently for the control plane and all workers in an enrollment
run. Adding workers increases workload capacity; it does not make the single
K3s control plane highly available.

Worker requirements:

- Debian or Ubuntu, a unique hostname, and sufficient CPU, memory, and disk
- SSH key authentication from the control plane as root or a user with
  passwordless `sudo`
- No public DNS, port-forward, load balancer, or application ingress targeting a
  worker
- Workers may retain a provider interface for initial bootstrap and controlled
  outbound traffic, but it receives no inbound UFW rule after private SSH is proven

### Private node network

#### OVHcloud vRack — OVHcloud-only

Choose this only when every node is an eligible OVHcloud Dedicated Server. The
wizard guides the unavoidable manual steps—vRack ordering/contract acceptance
and recovery-console verification—then offers either API-managed or manual
server attachment. API mode asks for a temporary AK/AS/CK set and prints the
exact least-privilege paths before validating it. Keep each service name, one
unused RFC1918 subnet, a unique IP per host, and the private NIC name or MAC
ready. The current [OVHcloud vRack host guide](https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/vrack-configuring-on-dedicated-server)
is linked by the wizard.

Automation attaches the interface, waits for the account task, configures
Netplan or ifupdown without replacing the public route, proves private SSH, and
only then applies UFW. A failure leaves the bootstrap path and firewall intact,
so rerunning resumes safely.

#### Tailscale — hybrid cloud or non-OVHcloud providers

Choose this for mixed providers, regions, or unrelated LANs. The wizard opens
the [Tailscale Keys page](https://login.tailscale.com/admin/settings/keys), waits
while an Owner, Admin, IT admin, or Network admin creates a short-lived personal
API access token (`tskey-api-`, not `tskey-auth-`), and verifies the token and
tailnet before changing a host. It then installs Tailscale, ETag-merges only this
cluster's tags and grants into the existing policy, creates one-use tagged node
keys, and switches enrollment to `tailscale0` before UFW closes bootstrap SSH.
No manual node, tag, policy, or address setup is needed.

To provision only a provider-neutral mesh, without K3s workers:

```bash
./scripts/configure-tailscale.sh --fleet
```

To add workers later, run the unified worker assistant from either the control
plane or the new worker:

```bash
./install-worker.sh
```

Control-plane mode enrolls any requested number of workers and waits for each
to become Ready. Worker mode joins only the current host and shows the commands
used to obtain its K3s join token:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
sudo k3s token create --ttl 1h --description worker-join
```

Workers have no internet-facing mode. UFW is default-deny inbound and permits
SSH only from the exact control-plane address plus required K3s/Longhorn peer
ports on the chosen private interface. Fail2ban, CrowdSec, and persistent Lynis
are absent from workers. Secret input is hidden and is never stored in the
repository or placed in command-line arguments. Worker UFW refuses to run unless
the active SSH session itself comes from the exact private control-plane IP to
the worker's vRack/Tailscale address, preventing a public-bootstrap lockout.
Both host input and forwarded Docker/Kubernetes traffic are denied on every
non-cluster interface for IPv4 and IPv6; outbound updates and their stateful
replies remain allowed.

## Host security policy

| Node | Exposure | Enforced host controls |
|---|---|---|
| Control plane | Local or internet-facing | UFW and Lynis; internet mode also enables Fail2ban, CrowdSec, and SSH hardening while retaining password authentication |
| Worker | Private only | UFW default-deny inbound, RFC1918 or Tailscale node IP, SSH only from the exact control-plane IP, and K3s peer ports only from the trusted node CIDR/interface |

The internet-facing control-plane policy keeps password SSH available as
requested, disables root SSH, limits authentication attempts and connection
bursts, and protects sshd with both Fail2ban and CrowdSec. Fail2ban observes a
one-hour window, starts with a 24-hour ban, and exponentially extends repeat
bans up to 30 days; CrowdSec also detects slow brute-force and user-enumeration
patterns and applies seven-day decisions. UFW exposes HTTP/HTTPS only to
Cloudflare proxy networks, keeps the Kubernetes API on the private interface,
and retains approximately three months of authentication logs for review. The
hardener detects the active SSH port, prepares its allow rule before enabling
UFW, and worker enrollment confirms a fresh private SSH connection afterward.

Lynis is installed only on the control plane. To audit the complete cluster,
run the control-plane audit assistant as the same user and SSH identity used to
enroll workers:

```bash
bm-cluster-audit-nodes
```

It discovers worker InternalIPs from Kubernetes, asks for SSH settings, copies
the control plane's Lynis files into a temporary worker directory, performs a
root audit through passwordless `sudo`, retrieves the reports under
`~/.local/state/bm-cluster/lynis-reports`, and removes the temporary copy. Explicit
targets can be supplied with `--targets user@host,user@host`; run
`bm-cluster-audit-nodes --help` for automation options.

## Identity and recovery credentials

Normal browser access uses the administrator login entered during cluster
installation. Because Keycloak realms are hard identity boundaries, the
reconciler maintains matching local identities in both `master` and `swirlit`
with the same managed password. If the login is a username, its primary email
is derived as `<username>@swirlit.dev`; an email login is used unchanged.
Membership in `platform-admins` supplies the application administrative role.
The `master` identity receives Keycloak's composite `admin` role and can
therefore administer the complete Keycloak instance from
`https://keycloak.swirlit.dev/auth/admin/master/console/`.
Retrieve the managed login and password from the cluster rather than storing
them in the repository:

```bash
kubectl get secret -n infra keycloak-sso-credentials \
  -o go-template='{{printf "%s:%s\n" (index .data "SSO_BOOTSTRAP_USERNAME" | base64decode) (index .data "SSO_BOOTSTRAP_PASSWORD" | base64decode)}}'
```

GitLab attaches this identity to its canonical `root` administrator, including
the projects, ownership, activity, and permissions already visible to the
break-glass root login. Its bootstrap removes any duplicate account matching
the selected login, so Keycloak and local root authentication do not create
separate GitLab users. Grafana maps the identity to Grafana Admin,
Argo CD to its admin role, Vault to `platform-admin`, and Portainer to role `1`
with Kubernetes `cluster-admin`. Odoo maps it to its existing administrator,
and SonarQube synchronizes the Keycloak
group to its global `admin` permission. The application dashboards and services
without native OIDC use the same Keycloak session at their proxy boundary, so
they do not introduce another user or password.

The effective authorization contract for that identity is deliberately
unrestricted:

| Target | Effective maximum access |
|---|---|
| Keycloak | Master-realm composite `admin` for every realm, plus `realm-admin` in `swirlit` |
| GitLab | Canonical `root` instance administrator and project owner |
| Grafana | Server-wide `GrafanaAdmin` and organization `Admin` |
| Argo CD | Built-in `role:admin` |
| Vault | Wildcard create/read/update/patch/delete/list/`sudo` policy |
| Portainer | Application role `1` and Kubernetes `cluster-admin` |
| Odoo | Existing Settings administrator (`base.user_admin`) |
| SonarQube | Global administration, provisioning, and scan permissions |
| Kibana / Elasticsearch | Managed origin user with `superuser` |
| Kafka UI | Full cluster write mode; read-only mode is disabled |
| DBGate | Keycloak-gated access to PostgreSQL superuser, MongoDB `root`, and unrestricted Redis connections |
| Longhorn / Homepage | Full product UI behind the `platform-admins` gate; neither product has an internal user-role hierarchy |
| DevApp / Thoughty / Indezy | All authenticated application functionality; these applications do not define a higher administrator role |

The following local credentials are break-glass or automation credentials, not
the normal browser sign-in path. Argo CD's local `admin` is disabled; DBGate and
Kafka UI use the Keycloak/proxy boundary; Longhorn and Homepage have no internal
user hierarchy; Vault uses tokens rather than a password.

| Service | Username | Password or token command |
|---|---|---|
| GitLab | `root` | `kubectl exec -n infra vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$(sudo cat /var/lib/bm-cluster/vault-bootstrap-token)" vault kv get -field=root_password secret/infra/gitlab` |
| Grafana | `admin` | `kubectl get secret -n infra grafana-admin-secret -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' \| base64 -d` |
| Keycloak | Secret value | `kubectl get secret -n infra keycloak-admin-secret -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' \| base64 -d` |
| Elasticsearch / Kibana | `admin` | `kubectl get secret -n infra elasticsearch-security-bootstrap -o jsonpath='{.data.ADMIN_PASSWORD}' \| base64 -d` |
| Elasticsearch | `elastic` | `kubectl get secret -n infra elasticsearch-security-bootstrap -o jsonpath='{.data.ELASTIC_PASSWORD}' \| base64 -d` |
| MongoDB | `admin` | `kubectl get secret -n infra mongodb-secret -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' \| base64 -d` |
| PostgreSQL | `admin` | `kubectl get secret -n infra postgres-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' \| base64 -d` |
| Longhorn origin login | `admin` | `kubectl exec -n infra vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$(sudo cat /var/lib/bm-cluster/vault-bootstrap-token)" vault kv get -field=password secret/infra/platform-ui` |
| Odoo | `admin` | `kubectl get secret -n apps odoo-secret -o jsonpath='{.data.ODOO_ADMIN_PASSWORD}' \| base64 -d` |
| Portainer | `admin` | `kubectl get secret -n infra portainer-auth-secret -o jsonpath='{.data.ADMIN_PASSWORD}' \| base64 -d` |
| SonarQube | `admin` | `kubectl exec -n infra vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$(sudo cat /var/lib/bm-cluster/vault-bootstrap-token)" vault kv get -field=admin_password secret/infra/sonarqube` |
| SonarQube automation | `admin` token | `kubectl exec -n infra vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$(sudo cat /var/lib/bm-cluster/vault-bootstrap-token)" vault kv get -field=admin_token secret/infra/sonarqube` |
| Vault | Token login | `sudo cat /var/lib/bm-cluster/vault-bootstrap-token` |

Vault records every API request and response to two audit devices. The stdout
device is collected by Fluent Bit, while the file device writes to the
dedicated `vault-audit` PVC. An unprivileged sidecar rotates the file at 256
MiB by atomically renaming it and sending Vault `SIGHUP`; it compresses closed
files and retains the eight newest archives. The rotation sidecar never
receives a Vault token and does not change Vault authentication or policies.

To align every genuine infrastructure-local superuser password, supply the
password without placing it on the command line:

```bash
read -rsp 'Local administrator password: ' LOCAL_ADMIN_PASSWORD; echo
printf '%s\n' "$LOCAL_ADMIN_PASSWORD" | \
  scripts/rotate-local-admin-passwords.sh --password-stdin
unset LOCAL_ADMIN_PASSWORD
```

When platform services are selected, the interactive installer offers this as
an optional `[y/N]` step and reads the password and confirmation with terminal
echo disabled. Non-interactive `--yes` runs never enable it implicitly; opt in
with `ROTATE_LOCAL_ADMIN_PASSWORDS=true` and provide `LOCAL_ADMIN_PASSWORD`
through the automation secret environment.

The rotation updates each service's internal credential first, persists the
matching value in Vault, refreshes External Secrets, restarts affected password
consumers, and verifies service availability. It deliberately does not modify
application users, Keycloak SSO identities, API tokens, the Longhorn ingress
password, or services without an internal administrator.

Cloudflare Access delegates its protected hosts to the same Keycloak realm.
Native OIDC integrations then establish the service session where supported.
SonarQube consumes the authenticated identity and groups as trusted SSO
headers. Kibana receives a managed `kibana_admin` origin identity after the
Keycloak gate, while Longhorn relies on the gate because it has no native
authentication provider. Scanner, registry, and internal automation endpoints
retain their non-interactive token interfaces.

## Operations

Inspect the platform:

```bash
kubectl get pods -A
kubectl get ingress -A
kubectl get pvc -A
```

Prometheus discovers metrics from any pod carrying `prometheus.io/scrape`,
`prometheus.io/path`, and `prometheus.io/port` annotations. Grafana discovers
application-owned dashboard ConfigMaps labeled `grafana_dashboard: "1"` in any
namespace, while its generic **Applications Namespace Overview** requires no
application inventory. Fluent Bit collects every container log, enriches records
from the `apps` namespace with a stable `observability_scope=application` field,
and copies the Kubernetes `app` label to a keyword field. Kibana provisions an
**Applications Namespace Logs** dashboard filtered only by namespace. This keeps
platform discovery independent of application names; app repositories own their
metrics endpoints, structured stdout format, and optional detailed dashboards.
The logging bootstrap applies a seven-day Elasticsearch lifecycle policy to
bound disk use. Elasticsearch security is enabled: Kibana uses its reserved
system account, ingestion and Grafana use dedicated least-privilege users, and
dashboard import hooks use a dedicated account with the `kibana_admin` role. All credentials
and Kibana encryption keys are synchronized from Vault.

Trigger the Descheduler manually:

```bash
kubectl create -f k8s/addons/descheduler-run-job.yaml
kubectl get jobs -n infra -l app=descheduler -w
```

K3s creates a consistent root-only recovery archive every day and retains the
latest seven under `/var/backups/bm-cluster/k3s`. The transactionally consistent
staging database is reduced to current Kubernetes state before archiving, so
superseded Kine revisions, tombstones, previous values, and SQLite free pages
are not retained. Run one immediately with
`sudo systemctl start bm-k3s-backup.service`, then copy the resulting archive to
encrypted off-node storage; a backup that remains on this server does not cover
disk or host loss.

### Interactive scripts versus Ansible

| Path | Use it for | Prerequisites | Behavior |
|---|---|---|---|
| `./install-control-plane.sh` and `./install-worker.sh` | First installation, guided transport preparation, K3s installation, and worker onboarding | Supported Ubuntu/Debian host, non-root sudo user; workers also need SSH keys and passwordless sudo; vRack needs tested KVM/rescue access | Interactive and resumable; pauses for account work, verifies it, configures private networking before UFW, then installs K3s/platform resources |
| `ansible/deploy.yml` | Repeatable platform reconciliation on an existing control plane, including CI | Working K3s cluster and kubeconfig, `ansible-playbook`, `kubectl`, Helm, repository checkout, and sudo; transport account prerequisites must already be complete | Non-interactive; uses `config/platform.env` and the same transport/security scripts, but does not install the K3s control plane or enroll worker operating systems |

Run Ansible from the control-plane repository checkout with its local inventory:

```bash
export KEYCLOAK_SSO_BOOTSTRAP_USERNAME='platform-admin'
export KEYCLOAK_SSO_BOOTSTRAP_PASSWORD='Replace-With-A-Strong-Password-1!'
ansible-playbook -i ansible/inventory ansible/deploy.yml
ansible-playbook -i ansible/inventory ansible/deploy.yml -e server_exposure=local
ansible-playbook -i ansible/inventory ansible/deploy.yml -e install_apps=false
```

Ansible uses the same release versions, ordered manifest inventories,
dependencies, and readiness checks as the interactive installer. It reconciles
all feature groups by default except Cloudflare. Feature switches are
`install_longhorn`, `install_ingress`, `install_vault_stack`,
`deploy_data_stores`, `deploy_platform_services`, `install_apps`, `install_odoo`,
`install_descheduler`, and `install_argocd`. Dependencies are enabled
automatically: `install_apps=false` disables Odoo, platform services and Odoo
require data stores, data stores require Vault and External Secrets, and
Cloudflare requires ingress.

Transport reconciliation is opt-in because it can change host networking. It
always runs before K3s network binding and host UFW. Ansible does not pause for
account setup: first complete the same prerequisites shown by the interactive
wizard, then export secrets in the current shell.

For vRack that means an activated OVHcloud vRack, tested KVM/rescue access, an
unused RFC1918 subnet, the service name and private NIC for each server, and a
temporary AK/AS/CK allowed `GET /vrack`, `GET /vrack/*`,
`POST /vrack/*/dedicatedServerInterface`, and
`GET /dedicated/server/*/networking`. For Tailscale it means a tailnet and a
short-lived personal `tskey-api-` token created by an Owner, Admin, IT admin, or
Network admin. Revoke temporary credentials after reconciliation.

For an already activated OVHcloud vRack, with API attachment enabled:

```bash
export OVH_API_ENDPOINT=ovh-eu
export OVH_APPLICATION_KEY='temporary application key'
export OVH_APPLICATION_SECRET='temporary application secret'
export OVH_CONSUMER_KEY='temporary consumer key'
export OVH_VRACK_SERVICE_NAME='pn-XXXXXX'
export OVH_CONTROL_PLANE_SERVICE_NAME='nsXXXXXX.ip-XX-XX-XX.eu'
ansible-playbook -i ansible/inventory ansible/deploy.yml \
  -e manage_private_transport=true \
  -e k3s_node_transport=vrack \
  -e ovh_vrack_automate_account=true \
  -e k3s_private_address=10.50.0.10 \
  -e k3s_private_interface=eno2 \
  -e k3s_node_network_cidr=10.50.0.0/24
```

For Tailscale, after creating the personal `tskey-api-` access token:

```bash
export TAILSCALE_API_TOKEN='temporary tskey-api token'
export TAILSCALE_TAILNET='example.com' # or '-' for the token's tailnet
export TAILSCALE_MESH_NAME='bm-cluster'
export TAILSCALE_NODE_HOSTNAME='bm-control-plane'
ansible-playbook -i ansible/inventory ansible/deploy.yml \
  -e manage_private_transport=true \
  -e k3s_node_transport=tailscale
```

Unset or revoke temporary credentials after the run. To reconcile only the
platform on an already configured private network, omit
`manage_private_transport`; provide `K3S_NODE_NETWORK_CIDR` when host security
must trust worker traffic.

To run the same non-interactive Cloudflare reconciliation from Ansible, export
the secret inputs and opt in explicitly:

```bash
export CLOUDFLARE_API_TOKEN='your Cloudflare User API Token (cfut_... type)'
export CLOUDFLARE_ACCESS_ALLOWED_EMAILS='admin@example.com'
ansible-playbook -i ansible/inventory ansible/deploy.yml -e configure_cloudflare=true
```

The playbook deploys platform resources through the active kubeconfig; K3s
control-plane installation and worker operating-system provisioning remain the
responsibility of the installers above.

Release defaults and ordered service inventories live only in
`config/platform.env`. Before committing or deploying, validate shell syntax,
Ansible, YAML, immutable image references, and hostname inventories:

```bash
./scripts/validate-repository.sh
./scripts/validate-repository.sh --live # server-side dry-run; no mutation
```

The same checks run in GitLab for every merge request and branch push; default
branch pipelines also verify Argo CD reconciliation, GitLab Registry health,
Prometheus targets, the Grafana dashboard, and GitLab logs in Elasticsearch.
EditorConfig and Git attributes keep text formatting portable.

## Repository layout

| Path | Purpose |
|---|---|
| `config/platform.env` | Shared release, internal-DNS, manifest-path, readiness, public-host, and private-transport contract |
| `config/apparmor/` | Host AppArmor policy installed on K3s nodes |
| `config/multipath/` | Host multipath configuration required by Longhorn |
| `config/systemd/` | Host services and timers installed by platform scripts |
| `install-control-plane.sh` | Install or reconcile the K3s control plane and platform services |
| `install-worker.sh` | Unified worker assistant for control-plane SSH enrollment or local self-join |
| `scripts/add-k3s-workers.sh` | Internal multi-worker SSH enrollment implementation |
| `scripts/install-k3s-worker.sh` | Internal local worker installation implementation |
| `scripts/audit-cluster-nodes.sh` | Control-plane Lynis runner for local and transient remote audits |
| `scripts/configure-cloudflare.sh` | Cloudflare DNS, edge security, TLS, and Access reconciliation |
| `scripts/configure-tailscale.sh` | Provider-neutral tailnet policy, fleet inventory, role tags, one-use keys, and node reconciliation |
| `scripts/configure-ovh-vrack.sh` | OVHcloud vRack API attachment and safe private-interface reconciliation |
| `scripts/configure-vault.sh` | Vault initialization, policies, and secret seeding |
| `scripts/configure-k3s-backups.sh` | Daily K3s/Vault recovery archives and retention |
| `scripts/configure-k3s-apparmor.sh` | Enforced runtime-default profile with Ubuntu stacking compatibility |
| `scripts/configure-k3s-control-plane-network.sh` | Persist private cluster and public ingress addresses for the K3s control plane |
| `scripts/configure-k3s-registry-mirror.sh` | Reconcile the node runtime mirror for GitLab Container Registry |
| `scripts/configure-gitlab-ci.sh` | GitLab group, project, Dependency Proxy, instance runner, and Vault token reconciliation |
| `scripts/configure-node-security.sh` | Host firewall and intrusion-prevention setup |
| `scripts/lib/network.sh` | Shared RFC1918, Tailscale, CIDR, and interface validation |
| `scripts/lib/transport-guide.sh` | Shared guided vRack/Tailscale account prerequisites and verification |
| `scripts/validate-repository.sh` | Consistency checks and optional live server dry-run |
| `k8s/base/` | Cluster namespaces, security baseline, host-policy record, and internal CoreDNS aliases |
| `k8s/datastores/` | PostgreSQL, Kafka, Redis, and MongoDB resources |
| `k8s/platform/` | Infrastructure services, observability, ingress, Vault integration, and bootstrap jobs |
| `k8s/apps/` | Repository-owned application resources |
| `k8s/addons/` | Optional cluster add-ons and their manually triggered jobs |
| `ansible/` | Ansible deployment entry point |

## Security notes

- Keep PostgreSQL, MongoDB, Redis, Kafka, Elasticsearch, and Prometheus internal.
- Keep `swirlit.internal` in CoreDNS only; never publish it through Cloudflare or public DNS.
- Keep administrative UI hostnames behind Cloudflare Access.
- Keep both Vault audit devices enabled and alert on audit-write failures or audit-volume pressure.
- Revoke short-lived setup tokens after use and rotate bootstrap credentials.
- Keep only required public ports open and update Kubernetes workloads regularly.
- Workers accept no public traffic: never publish, forward, or load-balance traffic to them.
- Worker UFW permits SSH only from the control plane and private K3s peer traffic; outbound access remains available.
- Local-only nodes omit Fail2ban and CrowdSec; local control planes retain Lynis.

## License

GNU General Public License v3.0. See `LICENSE`.
