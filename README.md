# Bare-Metal Cluster

Single- or multi-node K3s infrastructure for development and self-hosted platform
services. The repository installs the control plane and workers, storage, ingress,
security tools, secrets management, data stores, observability, CI/CD tools, and
Odoo.

## Components

- K3s, NGINX Ingress, Longhorn, and the Descheduler addon
- Vault and External Secrets Operator
- PostgreSQL, MongoDB, Redis, and Kafka in KRaft mode
- Keycloak, GitLab, Jenkins, ArgoCD, Nexus, and SonarQube
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
The `devapp` hostname and catalog entry are published here, but its Deployment,
Ingress, Jenkins pipeline, and Argo CD application remain owned by the separate
`devapp` repository.

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
`user-app.swirlit.internal`, `order-app.swirlit.internal`, and
`devapp.swirlit.internal` into the `devapp` namespace, and
`longhorn.swirlit.internal` into `longhorn-system`.

The zone is cluster-only: it is not published by Cloudflare and is not expected
to resolve on the public Internet or from ordinary host tools. K3s/containerd
uses `nexus.swirlit.internal:5000` through its node-local registry mirror,
whose endpoint is the Nexus ClusterIP. Kubernetes API endpoints retain their
canonical `kubernetes.default.svc` identity because that name is covered by the
API server certificate.

The catalog, icons, Kubernetes read-only status integration, Deployment,
Service, and Ingress are defined together in `deployments/homepage.yaml`. Both
the interactive installer and `ansible/deploy.yml` apply it automatically.

## Quick start

Requirements:

- Ubuntu 22.04 or newer
- 8 or more CPUs, 16 GB or more RAM, and 100 GB or more disk
- A sudo-capable non-root user
- A domain registered for public deployments
- SSH keys and passwordless `sudo` from the control plane to every worker

For a new cluster, run the guided installer on the future control-plane host:

```bash
./install-control-plane.sh
```

It asks which features to install and, when workers are selected, starts the
vRack or Tailscale prerequisite wizard before any UFW change. Each wizard shows
the exact account page, pauses while you complete the manual account step,
collects secrets with hidden input, checks the account read-only, and resumes.
Nothing is persisted. `./install-control-plane.sh --yes` is the non-interactive
path and therefore requires all selected transport secrets and settings as
environment variables.

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

## Initial credentials

Retrieve bootstrap credentials from the cluster rather than storing them in the
repository:

| Service | Username | Password or token command |
|---|---|---|
| ArgoCD | `admin` | `kubectl -n infra get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| DBGate | Secret value | `kubectl get secret -n infra dbgate-auth-secret -o go-template='{{printf "%s:%s" (index .data "LOGIN" \| base64decode) (index .data "PASSWORD" \| base64decode)}}'` |
| GitLab | `root` | `kubectl exec -n infra deployment/gitlab -- awk '/Password:/ {print $2}' /etc/gitlab/initial_root_password` |
| Grafana | `admin` | `kubectl get secret -n infra grafana-admin-secret -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' \| base64 -d` |
| Jenkins | `admin` | `kubectl exec -n infra deployment/jenkins -- cat /var/jenkins_home/secrets/initialAdminPassword` |
| Kafka UI | Secret value | `kubectl get secret -n infra kafka-ui-auth-secret -o go-template='{{printf "%s:%s" (index .data "SPRING_SECURITY_USER_NAME" \| base64decode) (index .data "SPRING_SECURITY_USER_PASSWORD" \| base64decode)}}'` |
| Keycloak | Secret value | `kubectl get secret -n infra keycloak-admin-secret -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' \| base64 -d` |
| Nexus | `admin` | `kubectl exec -n infra deployment/nexus -- cat /nexus-data/admin.password` |
| Odoo | `admin` | `kubectl get secret -n infra odoo-secret -o jsonpath='{.data.ODOO_ADMIN_PASSWORD}' \| base64 -d` |
| Portainer | `admin` | `kubectl get secret -n infra portainer-auth-secret -o jsonpath='{.data.ADMIN_PASSWORD}' \| base64 -d` |
| SonarQube | `admin` | Initial password: `admin` |
| Vault | Token login | `sudo cat /var/lib/bm-cluster/vault-bootstrap-token` |

Change bootstrap credentials immediately after onboarding.

## Operations

Inspect the platform:

```bash
kubectl get pods -A
kubectl get ingress -A
kubectl get pvc -A
```

Applications opt into metrics from their own repository by adding
`prometheus.io/scrape`, `prometheus.io/path`, and `prometheus.io/port` pod
annotations. Application Grafana dashboards remain application-owned: publish a
ConfigMap labeled `grafana_dashboard: "1"` containing dashboard JSON. Kubernetes
logs are collected automatically into `kubernetes-logs-*` and can be filtered in
Kibana by `kubernetes.namespace_name` and `kubernetes.labels.app`. The logging
bootstrap applies a seven-day Elasticsearch lifecycle policy to bound disk use.

Trigger the Descheduler manually:

```bash
kubectl create -f deployments/descheduler-run-job.yaml
kubectl get jobs -n infra -l app=descheduler -w
```

K3s creates a consistent root-only recovery archive every day and retains the
latest seven under `/var/backups/bm-cluster/k3s`. Run one immediately with
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
ansible-playbook -i ansible/inventory ansible/deploy.yml
ansible-playbook -i ansible/inventory ansible/deploy.yml -e server_exposure=local
ansible-playbook -i ansible/inventory ansible/deploy.yml -e install_odoo=false
```

Ansible uses the same release versions, ordered manifest inventories,
dependencies, and readiness checks as the interactive installer. It reconciles
all feature groups by default except Cloudflare. Feature switches are
`install_longhorn`, `install_ingress`, `install_vault_stack`,
`deploy_data_stores`, `deploy_platform_services`, `install_odoo`,
`install_descheduler`, and `install_argocd`. Dependencies are enabled
automatically: platform services and Odoo require data stores; data stores
require Vault and External Secrets; Cloudflare requires ingress.

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

The same checks run on every pull request and push to `main`. EditorConfig and
Git attributes keep text formatting portable, while Dependabot proposes updates
to the workflow's immutable action pins.

## Repository layout

| Path | Purpose |
|---|---|
| `config/platform.env` | Shared release, internal-DNS, manifest, readiness, public-host, and private-transport contract |
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
| `scripts/configure-k3s-registry-mirror.sh` | Reconcile the node runtime mirror for `nexus.swirlit.internal` |
| `scripts/configure-nexus-registry.sh` | Private image registry, roles, accounts, and Vault credentials |
| `scripts/configure-node-security.sh` | Host firewall and intrusion-prevention setup |
| `scripts/lib/network.sh` | Shared RFC1918, Tailscale, CIDR, and interface validation |
| `scripts/lib/transport-guide.sh` | Shared guided vRack/Tailscale account prerequisites and verification |
| `scripts/validate-repository.sh` | Consistency checks and optional live server dry-run |
| `deployments/coredns-custom.yaml` | Cluster-only `swirlit.internal` service aliases imported by K3s CoreDNS |
| `deployments/` | Remaining Kubernetes resources |
| `ansible/` | Ansible deployment entry point |

## Security notes

- Keep PostgreSQL, MongoDB, Redis, Kafka, Elasticsearch, and Prometheus internal.
- Keep `swirlit.internal` in CoreDNS only; never publish it through Cloudflare or public DNS.
- Keep administrative UI hostnames behind Cloudflare Access.
- Revoke short-lived setup tokens after use and rotate bootstrap credentials.
- Keep only required public ports open and update Kubernetes workloads regularly.
- Workers accept no public traffic: never publish, forward, or load-balance traffic to them.
- Worker UFW permits SSH only from the control plane and private K3s peer traffic; outbound access remains available.
- Local-only nodes omit Fail2ban and CrowdSec; local control planes retain Lynis.

## License

GNU General Public License v3.0. See `LICENSE`.
