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
- Prometheus, Grafana, Elasticsearch, Logstash, Kibana, Fluent Bit, and Filebeat
- Trivy Operator with continuous vulnerability, configuration, RBAC, exposed-secret, infrastructure, and compliance reports
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
Trivy Operator continuously scans cluster workloads and controls, keeps its
Kubernetes-native reports current, and publishes both summary and detailed
finding metrics to the provisioned **Trivy Security Reports** Grafana dashboard.
Fluent Bit ships Kubernetes container logs with namespace, pod, container, and
label metadata to Elasticsearch for Kibana discovery. A control-plane Filebeat
agent separately ships structured Lynis audit records through Logstash.

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

Open `https://dashboard.<your-domain>` for the complete categorized service
catalog; the zone apex redirects there. Cloudflare Access protects the
administrative host inventory in `config/platform.env` through Keycloak SSO
with a 24-hour session.
Cluster automation uses internal Kubernetes service names, so these public
administration hostnames can remain protected without blocking builds,
deployments, package downloads, or scans.

### Internal service DNS

Cluster workloads use the private `internal.<your-domain>` DNS zone. CoreDNS maps every
`<name>.internal.<your-domain>` query to the same Service name in the `infra` namespace,
preserving additional labels for headless services such as
`kafka-controller-0.kafka-controller.internal.<your-domain>`. Curated aliases map
`longhorn.internal.<your-domain>` into `longhorn-system`; application-owned services
use their canonical Kubernetes DNS names.

The zone is cluster-only: it is not published by Cloudflare and is not expected
to resolve on the public Internet or from ordinary host tools. K3s/containerd
maps `registry.<your-domain>` to a fixed internal Registry service endpoint. The
Dependency Proxy retains its canonical `gitlab.<your-domain>` HTTPS route because
containerd's mirror query parameter interferes with GitLab Workhorse cache
uploads. Kubernetes API endpoints retain their canonical
`kubernetes.default.svc` identity because that name is covered by the API server
certificate.

Public Docker clients also use `registry.<your-domain>`. Cloudflare reconciliation
keeps the hostname proxied but prevents browser-only bot challenges from
intercepting the Registry API: basic Bot Fight Mode is disabled because it has
no hostname exceptions, while Super Bot Fight Mode is skipped only for the
Registry hostname. Custom WAF rules, rate limiting, strict TLS, and Cloudflare
DDoS protection remain enabled. The setup token therefore needs `Bot Management
Read` and `Bot Management Edit` zone permissions in addition to the permissions
printed by the configurator.

### GitLab delivery

The infrastructure repository lives at `<gitlab-group>/bm-cluster` in GitLab.
Its instance-scoped Kubernetes runner executes `.gitlab-ci.yml` in the isolated
`gitlab-runners` namespace. The default branch is continuously reconciled by
the `bm-cluster` Argo CD Application. Centrally owned Odoo resources under
`k8s/apps` are included when `appsEnabled=true`; DevApp, Thoughty, and Indezy
remain outside this infrastructure GitOps boundary and reconcile through their
own Argo CD Applications.

Repository synchronization is optional. When selected in the installer, it asks
for any number of `GitHub-owner/repository=GitLab-group/repository` mappings and
a GitHub fine-grained token. GitHub pushes start
`.github/workflows/sync-gitlab.yml`; GitLab push and tag webhooks dispatch the
same reconciler. It discovers each GitLab project ID through the API,
initializes an empty GitLab repository automatically, fast-forwards the lagging
side, merges divergent branches without force pushing, and refuses conflicting
tag rewrites. A monthly schedule self-rotates the managed GitLab credential.

GitLab stores private OCI images at `registry.<your-domain>`. Application
pipelines retain downloadable build, test, coverage, browser, and quality
artifacts for seven days and publish
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

The three application repositories use one bootstrap and operator-reconciliation contract:

| Project | Argo CD bootstrap | Desired state | Operator playbook |
|---|---|---|---|
| `<gitlab-group>/devapp` | `infra/argocd/application.yaml` | `infra/k8s` | `infra/ansible/site.yaml` |
| `<gitlab-group>/thoughty` | `infra/argocd/application.yaml` | `infra/k8s/overlays/bm-cluster` | `infra/ansible/site.yaml` |
| `<gitlab-group>/indezy` | `infra/argocd/application.yaml` | `infra/k8s` | `infra/ansible/site.yaml` |

Each application pipeline exposes ordered `build`, `verify`, `release`, and
`version` stages. Compilation and package validation are required; unit tests
and the 80 percent coverage policy fail only the non-blocking test job. Manual
E2E remains independent; `02-quality` and the separately runnable `03-security`
Trivy scan are optional manual branches in standard mode and run automatically
as non-blocking branches in full mode. Numeric naming places security after
quality in the verify-stage display without making it depend on quality.
Release depends on the required build path, deploy depends on release, and the
manual major-version action is never allowed to fail silently.

Their pipelines use the internal `gitlab.internal.<your-domain>` API/clone route and
the internal Registry service for cluster traffic, while user-facing GitLab and
Registry URLs remain `gitlab.<your-domain>` and `registry.<your-domain>`. Each app
repository owns its GitLab bootstrap, Vault contracts, Argo CD Application, and
runtime manifests; `bm-cluster` owns only the generic runner and shared platform.

Registry retention is declared in `k8s/platform/gitlab-registry-retention.yaml`.
Every day it reconciles GitLab's native container-image cleanup policy for all
projects in the installer-selected GitLab group and removes Package Registry versions created more
than 1,095 days ago. GitLab continues to protect protected container tags and
the literal `latest` tag. The group-scoped API token is stored in Vault at
`secret/infra/gitlab`, projected by External Secrets, and never committed.

GitLab and the runner expose Prometheus metrics through pod annotations. The
provisioned GitLab Delivery dashboard is loaded by Grafana, and Fluent Bit ships
their JSON container logs into the existing Elasticsearch/Kibana pipeline.

GitLab CI/registry setup does not require a manually created token when run on
the control plane. The configurator creates a one-day administrator token with
`gitlab-rails`, uses it through the API, and revokes it on exit. For optional
GitHub/GitLab synchronization, provide the public domain, repository mapping,
and GitHub token:

```bash
PLATFORM_DOMAIN='<your-domain>' \
CONFIGURE_REPOSITORY_SYNC=true \
GITHUB_OWNER='<github-owner>' \
GITHUB_REPOSITORY='<repository>' \
GITLAB_GROUP_PATH='<gitlab-group>' \
GITLAB_PROJECT_PATH='<gitlab-group>/<repository>' \
GITHUB_ADMIN_TOKEN='...' \
  ./scripts/configure-gitlab-ci.sh
```

The script always reconciles the group, project, Dependency Proxy, image
retention policy, instance runner, and Vault tokens. Repository secrets,
variables, the first synchronization, and the GitLab dispatch webhook are
created only when synchronization is enabled. No credential is committed.

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

It first asks for the public base domain and the K3s control-plane node name.
The private service zone is derived as `internal.<your-domain>`; manifests are
rendered from domain-neutral templates, and Argo CD receives the same values for
all future reconciliation. Public node administration uses the separate
`CLOUDFLARE_NODE_DNS_LABEL` (default `node-01`), so changing a Kubernetes node
name does not silently rename the unproxied `node-01.<your-domain>` record.
When Cloudflare is enabled, the installer also asks for the Zero Trust team
label (the first part of `TEAM.cloudflareaccess.com`) so the
Keycloak callback is rendered without embedding an account hostname. It then
asks whether to install `infra` only or
`infra + apps`. The apps choice deploys Odoo, the repository-owned ERP/CRM
workload.
Questions are grouped into cluster identity and scope, host and K3s nodes,
platform components, recovery and public access, GitOps delivery, and
administrator credentials. The recommended platform bundle replaces seven
repetitive component questions; decline it only when you want to select those
components individually.
The installer asks for the total cluster node count, including the control
plane, and then whether that control plane is a schedulable controller-worker
or a tainted controller-only node. A one-node cluster must use controller-worker
mode. Worker enrollment derives its count from the total, so the same number is
not requested twice.
When platform services are selected, it asks for a platform administrator
login and a confirmed hidden password. That identity is provisioned through
Keycloak as administrator for every integrated service and application. The
password must contain at least 12 characters with lowercase, uppercase,
numeric, and special characters.
It then asks which infrastructure features to install and, when workers are
selected, starts the vRack or Tailscale prerequisite wizard before any UFW
change. Each wizard shows the exact account page, pauses while you complete the
manual account step, collects secrets with hidden input, checks the account
read-only, and resumes. Cloudflare setup verifies registrar nameserver
delegation and the public DNSSEC DS record; Cloudflare Registrar completes these
automatically, while other registrars pause with the exact values to enter.
The repository-sync and encrypted S3-compatible backup features are separate
installer choices and request credentials only when selected. Runtime secrets
are never committed. `./install-control-plane.sh --yes`
defaults to `infra + apps`; set `INSTALL_SCOPE=infra` for an infrastructure-only
non-interactive run. Non-interactive platform installation also requires
`PLATFORM_DOMAIN`, `CONTROL_PLANE_NODE_NAME`, `GITOPS_REPOSITORY_URL`,
`KEYCLOAK_SSO_BOOTSTRAP_USERNAME`, and `KEYCLOAK_SSO_BOOTSTRAP_PASSWORD`.
Override `CLOUDFLARE_NODE_DNS_LABEL` only when the public node hostname should
differ from `node-01`.
Set `CLUSTER_NODE_COUNT` and `CONTROL_PLANE_SCHEDULABLE=true|false` to override
the node-list-derived non-interactive topology defaults.
Selected identity and transport secrets are supplied as environment variables.

## Adding worker nodes

Worker enrollment is built into `install-control-plane.sh`. Answer **yes** to
adding workers, choose **OVHcloud-only vRack** or **Tailscale for
hybrid/non-OVHcloud providers**, then enter any number of workers. Use one
transport consistently for the control plane and all workers in an enrollment
run. Adding workers increases workload capacity; it does not make the single
K3s control plane highly available.

After every worker enrollment, `scripts/reconcile-cluster-topology.sh` updates
the stored topology and
reconciles Longhorn's live setting, Helm values, default StorageClass, and
existing volumes. Once workers exist, Longhorn stops scheduling storage on the
control plane and safely evicts its old replicas to worker storage in the
background.
Standalone `./install-worker.sh --control-plane` enrollment asks whether to
convert the control plane to controller-only after the new worker is Ready; the
default answer is yes. It skips that question when every control-plane node
already has the standard controller-only `NoSchedule` taint. Non-interactive
enrollment from a schedulable control plane requires an explicit
`--control-plane-schedulable true|false|preserve` safeguard. Enrollment launched
by the main installer does not repeat the question because it passes through
the explicit scheduling choice made earlier.
Longhorn uses one replica with only the control plane or one worker; with two or
more workers its replica count equals the Ready worker count. The control plane
is excluded from Longhorn storage scheduling whenever a worker exists:

| Topology | Longhorn replicas |
|---|---:|
| Control plane only | 1 |
| Control plane + 1 worker | 1 |
| Control plane + 2 workers | 2 |
| Control plane + 3 workers | 3 |
| Control plane + N workers | N |

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

The host security reconciler also installs `bm-cluster-lynis.timer`. It runs a
local control-plane audit on the 15th of every month at 03:00 in the node's
local timezone, updates `/var/log/lynis-report.dat`, and retains timestamped
root-only report, log, and output archives under `/var/log/lynis-reports` for
365 days. Check the next run with `systemctl list-timers bm-cluster-lynis.timer`.

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
is derived as `<username>@<your-domain>`; an email login is used unchanged.
Membership in `platform-admins` supplies the application administrative role.
The `master` identity receives Keycloak's composite `admin` role and can
therefore administer the complete Keycloak instance from
`https://keycloak.<your-domain>/auth/admin/master/console/`.
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
separate GitLab users. The bootstrap reconciles the primary email and admin
status but deliberately leaves the GitLab full name untouched; OmniAuth
profile synchronization is likewise restricted to email so a name edited in
GitLab survives sign-in and redeployment. Grafana maps the identity to Grafana Admin,
Argo CD to its admin role, Vault to `platform-admin`, and Portainer to role `1`
with Kubernetes `cluster-admin`. Odoo maps it to its existing administrator,
and SonarQube synchronizes the Keycloak
group to its global `admin` permission. The application dashboards and services
without native OIDC use the same Keycloak session at their proxy boundary, so
they do not introduce another user or password.

Kibana revalidates that signed Keycloak session at its own boundary and
authenticates each request as a distinct, same-named Elastic identity. This
keeps Kibana profiles, favorites, and preferences separate instead of attaching
them to the gateway service account. A five-minute
reconciler gives enabled `platform-admins` members the `superuser` role, disables
managed identities that leave the group, and aligns their hidden gateway
credential used only to establish the Kibana session. Ownership is recorded in
a separate hidden Elasticsearch index, so editing a person's Kibana full name
cannot remove the reconciliation marker; locally edited full names are retained.
The separate
`kibana_dashboard_bootstrap` account is used only by dashboard-import jobs and
is never the browser identity. Cloud Connect and Elastic's product-feedback
intercepts are disabled because this self-managed deployment does not configure
either integration; this avoids background 503 and 403 requests in the UI.

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
| Kibana / Elasticsearch | Named Keycloak user mapped to an individual Elastic identity with `superuser` |
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
| Odoo | SSO primary email | `kubectl get secret -n apps odoo-secret -o jsonpath='{.data.ODOO_ADMIN_PASSWORD}' \| base64 -d` |
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
headers. Kibana revalidates the Keycloak session and uses its named,
role-synchronized Elastic identity, while Longhorn relies on the gate because
it has no native authentication provider. Scanner, registry, and internal
automation endpoints retain their non-interactive token interfaces.

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
**Applications Namespace Logs** dashboard filtered only by namespace. Filebeat
tails `/var/log/lynis-report.dat` on the control plane, Logstash parses its
key/value and warning/suggestion fields, and Kibana provisions a **Lynis
Security Audits** dashboard with a hardening-index trend and finding details.
Trivy Operator runs in `infra`, scans current workload revisions across all
namespaces, and refreshes image/SBOM, configuration, RBAC, exposed-secret,
infrastructure, and cluster-compliance reports. Prometheus scrapes its annotated
metrics endpoint; Grafana's **Trivy Security Reports** dashboard shows severity
totals plus workload, CVE/package/fix, policy, RBAC, secret-metadata,
infrastructure, and compliance detail. The dashboard never exposes discovered
secret values. Inspect the source reports directly with, for example,
`kubectl get vulnerabilityreports,configauditreports,exposedsecretreports -A`.
This keeps
platform discovery independent of application names; app repositories own their
metrics endpoints, structured stdout format, and optional detailed dashboards.
Prometheus evaluates node-capacity, workload-availability, crash-loop, OOM,
failed-Job, released-volume, pending-claim, and scrape-target rules. Alertmanager
deduplicates those alerts and sends firing and resolved events to the
`swirlit/bm-cluster` project's **Monitor > Alerts** page in GitLab using a
Vault-backed, reconciled Prometheus integration credential.
The logging bootstrap applies a seven-day lifecycle policy to container and
application logs and a separate 365-day policy to monthly `lynis-audits-*`
indices. Elasticsearch security is enabled: Kibana uses its reserved system
account, ingestion and Grafana use dedicated least-privilege users, and
dashboard import hooks use a dedicated account with the `kibana_admin` role.
Interactive requests use the individual identities synchronized from the
Keycloak `platform-admins` group; the proxy credential has no direct data or
Kibana privileges. All credentials and Kibana encryption keys are synchronized
from Vault.

The installer-provided display name seeds new Keycloak identities. Subsequent
first/last-name edits in Keycloak are preserved by reconciliation. GitLab and
SonarQube likewise keep locally edited display names while still reconciling
email, group, and administrator privileges. Odoo consistently uses the SSO
primary email as the administrator login, and Portainer's PostSync hook
reasserts the SSO administrator role and credential on every platform sync.

GitLab KAS is disabled while no Kubernetes agents are registered. The internal
Registry Service publishes its endpoint independently of the slower Rails
readiness probe so cached or available Registry traffic is not unnecessarily
blocked during an Omnibus restart.

Trigger the Descheduler manually:

```bash
kubectl create -f k8s/addons/descheduler-run-job.yaml
kubectl get jobs -n infra -l app=descheduler -w
```

K3s creates a consistent root-only recovery archive every day and retains the
latest seven under `/var/backups/bm-cluster/k3s`. It contains compacted current
Kubernetes state, server/encryption credentials, a Vault Raft snapshot, and
logical PostgreSQL and MongoDB dumps when those services exist. When the guided
S3-compatible destination is enabled, restic encrypts and uploads each archive
and retains daily, weekly, and monthly recovery points. Longhorn simultaneously
backs up every labeled PVC to the same private bucket through a daily recurring
job; the host backup labels newly created volumes before that job runs. Run an
archive immediately with `sudo systemctl start bm-k3s-backup.service`.

The object-storage assistant explains how to create a bucket-scoped access
key/API token, then prompts with hidden input for the access key, secret, and
restic recovery password. Those values are stored root-only in
`/etc/bm-cluster/backup.env` and in the Longhorn credential Secret, never in Git.
If off-node storage is declined, the installer warns that local archives cannot
survive disk or host loss.

### Interactive scripts versus Ansible

| Path | Use it for | Prerequisites | Behavior |
|---|---|---|---|
| `./install-control-plane.sh` and `./install-worker.sh` | First installation, guided transport preparation, K3s installation, and worker onboarding | Supported Ubuntu/Debian host, non-root sudo user; workers also need SSH keys and passwordless sudo; vRack needs tested KVM/rescue access | Interactive and resumable; pauses for account work, verifies it, configures private networking before UFW, then installs K3s/platform resources |
| `ansible/deploy.yml` | Repeatable platform reconciliation on an existing control plane, including CI | Working K3s cluster and kubeconfig, `ansible-playbook`, `kubectl`, Helm, repository checkout, and sudo; transport account prerequisites must already be complete | Non-interactive; uses `config/platform.env` and the same transport/security scripts, but does not install the K3s control plane or enroll worker operating systems |

Run Ansible from the control-plane repository checkout with its local inventory:

```bash
export PLATFORM_DOMAIN='example.com'
export INTERNAL_DNS_ZONE='internal.example.com'
export CONTROL_PLANE_NODE_NAME='control-plane-01'
export CLOUDFLARE_NODE_DNS_LABEL='node-01'
export CONTROL_PLANE_SCHEDULABLE='false'
export GITOPS_REPOSITORY_URL='https://github.com/example/bm-cluster.git'
export CLOUDFLARE_ACCESS_TEAM_NAME='example-team'
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
Ansible preserves the installer-selected control-plane mode by default and
uses the same Ready-worker Longhorn replica rule. Set
`CONTROL_PLANE_SCHEDULABLE=true|false` only when intentionally changing it.

Local infrastructure password alignment is also explicit in Ansible. To run
the same post-deployment reconciliation as the installer without exposing the
password on the command line, export the secret only for the playbook process:

```bash
read -rsp 'Local administrator password: ' LOCAL_ADMIN_PASSWORD; echo
export LOCAL_ADMIN_PASSWORD ROTATE_LOCAL_ADMIN_PASSWORDS=true
ansible-playbook -i ansible/inventory ansible/deploy.yml
unset LOCAL_ADMIN_PASSWORD ROTATE_LOCAL_ADMIN_PASSWORDS
```

The playbook passes the value to the existing rotation script over stdin and
marks the task `no_log`; it does not alter SSO identities or application users.

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
export CLOUDFLARE_ACCESS_TEAM_NAME='example-team'
ansible-playbook -i ansible/inventory ansible/deploy.yml -e configure_cloudflare=true
```

For off-node recovery, additionally export
`CONFIGURE_OFFSITE_BACKUPS=true`, `BACKUP_S3_ENDPOINT`, `BACKUP_S3_BUCKET`,
`BACKUP_S3_REGION`, `BACKUP_S3_ACCESS_KEY`, `BACKUP_S3_SECRET_KEY`, and
`BACKUP_REPOSITORY_PASSWORD`. Ansible is non-interactive and therefore never
prompts for missing secret inputs.

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
| `scripts/configure-lynis-schedule.sh` | Monthly control-plane Lynis timer and twelve-month local report retention |
| `scripts/configure-cloudflare.sh` | Cloudflare DNS, edge security, TLS, and Access reconciliation |
| `scripts/configure-tailscale.sh` | Provider-neutral tailnet policy, fleet inventory, role tags, one-use keys, and node reconciliation |
| `scripts/configure-ovh-vrack.sh` | OVHcloud vRack API attachment and safe private-interface reconciliation |
| `scripts/configure-vault.sh` | Vault initialization, policies, and secret seeding |
| `scripts/configure-k3s-backups.sh` | Local archive timer, encrypted S3/restic destination, and Longhorn recurring-backup reconciliation |
| `scripts/configure-k3s-apparmor.sh` | Enforced runtime-default profile with Ubuntu stacking compatibility |
| `scripts/configure-k3s-control-plane-network.sh` | Persist private cluster and public ingress addresses for the K3s control plane |
| `scripts/configure-k3s-registry-mirror.sh` | Reconcile the node runtime mirror for GitLab Container Registry |
| `scripts/configure-gitlab-ci.sh` | GitLab group, project, Dependency Proxy, instance runner, and Vault token reconciliation |
| `scripts/configure-repository-sync.sh` | Optional project-discovered GitHub/GitLab mirroring, webhook, variables, secrets, and first sync |
| `scripts/render-cluster-config.sh` | Render installer-selected domains and GitOps source from neutral templates |
| `scripts/configure-node-security.sh` | Host firewall, intrusion prevention, and Lynis schedule setup |
| `scripts/reconcile-cluster-topology.sh` | Reconcile control-plane taints, stored node topology, and worker-derived Longhorn replication |
| `scripts/lib/installer-prompts.sh` | Shared section, value, secret, confirmation, yes/no, and node-transport prompt primitives |
| `scripts/lib/network.sh` | Shared RFC1918, Tailscale, CIDR, and interface validation |
| `scripts/lib/transport-guide.sh` | Shared guided vRack/Tailscale account prerequisites and verification |
| `scripts/lib/gitlab-admin-token.sh` | Short-lived local GitLab administrator token creation and revocation |
| `scripts/validate-repository.sh` | Consistency checks and optional live server dry-run |
| `k8s/base/` | Cluster namespaces, security baseline, host-policy record, and internal CoreDNS aliases |
| `k8s/datastores/` | PostgreSQL, Kafka, Redis, and MongoDB resources |
| `k8s/platform/` | Infrastructure services, observability, ingress, Vault integration, and bootstrap jobs |
| `k8s/apps/` | Repository-owned application resources |
| `k8s/addons/` | Optional cluster add-ons and their manually triggered jobs |
| `k8s/Chart.yaml` | Argo CD Helm entry point that renders the selected public/private domains and vendors the pinned Trivy Operator dependency |
| `ansible/` | Ansible deployment entry point |

## Security notes

- Keep PostgreSQL, MongoDB, Redis, Kafka, Elasticsearch, and Prometheus internal.
- Keep `internal.<your-domain>` in CoreDNS only; never publish it through Cloudflare or public DNS.
- Keep administrative UI hostnames behind Cloudflare Access.
- Review Trivy's Grafana findings and Kubernetes report resources regularly; keep the scanner/operator images and vendored chart pinned during upgrades.
- Keep both Vault audit devices enabled and alert on audit-write failures or audit-volume pressure.
- Revoke short-lived setup tokens after use and rotate bootstrap credentials.
- Keep only required public ports open and update Kubernetes workloads regularly.
- Workers accept no public traffic: never publish, forward, or load-balance traffic to them.
- Worker UFW permits SSH only from the control plane and private K3s peer traffic; outbound access remains available.
- Local-only nodes omit Fail2ban and CrowdSec; local control planes retain Lynis.

## License

GNU General Public License v3.0. See `LICENSE`.
