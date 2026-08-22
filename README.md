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
services and are not published through DNS.

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

The catalog, icons, Kubernetes read-only status integration, Deployment,
Service, and Ingress are defined together in `deployments/homepage.yaml`. Both
the interactive installer and `ansible/deploy.yml` apply it automatically.

## Quick start

Requirements:

- Ubuntu 22.04 or newer
- 8 or more CPUs, 16 GB or more RAM, and 100 GB or more disk
- A sudo-capable non-root user
- A domain registered for public deployments

Run the interactive control-plane installer:

```bash
chmod +x install-control-plane.sh install-worker.sh scripts/*.sh
./install-control-plane.sh
```

The installer asks which feature groups to deploy. For an internet-exposed
installation, its optional Cloudflare step prompts for a **Cloudflare User API
Token** and does not persist it. The script is the source of truth for all edge
configuration; no manual Cloudflare procedure is required.

Use `./install-control-plane.sh --yes` for default feature choices. Secret
prompts still require input unless their documented environment variable is
provided.

## Adding worker nodes

Worker enrollment is built into `install-control-plane.sh`. Answer **yes** to
adding workers, choose **OVH vRack/private LAN** or **Tailscale**, then enter any
number of workers. Use one transport consistently for the control plane and all
workers in an enrollment run. Adding workers increases workload capacity; it
does not make the single K3s control plane highly available.

Worker requirements:

- Debian or Ubuntu, a unique hostname, and sufficient CPU, memory, and disk
- SSH key authentication from the control plane as root or a user with
  passwordless `sudo`
- No public DNS, port-forward, load balancer, or application ingress targeting a
  worker
- vRack workers must have only RFC1918/ULA addressing and controlled outbound
  egress; Tailscale workers may retain a provider interface for outbound traffic
  and initial SSH bootstrap, but receive no inbound UFW rule on that interface

### Private node network

#### OVH vRack — recommended for the current cluster

Use vRack when all nodes are on OVH because it keeps cluster and Longhorn
traffic on the provider network. Before running the installer, use OVH's
[dedicated-server vRack guide](https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/vrack-configuring-on-dedicated-server)
to create the vRack, attach every server, assign unique RFC1918 addresses to the
private NICs, and verify bidirectional SSH/ping. Keep the control plane's public
NIC intact. Verify access and an IPMI/KVM recovery path before removing worker
public addressing, and provide workers controlled NAT/egress for updates and
image pulls. The installer asks for the control-plane IP, node CIDR, and each
worker vRack IP and validates them before changing K3s or UFW.

#### Tailscale — cross-provider alternative

Use Tailscale when nodes span providers, regions, or unrelated private
networks. The only account preparation is:

1. Create or sign in to a tailnet.
2. Open [Tailscale Admin Console → Settings → Keys](https://login.tailscale.com/admin/settings/keys)
   and choose **Generate access token**. This must be a personal API access token beginning with
   `tskey-api-`, not a node auth key beginning with `tskey-auth-`. Use an
   Owner/Admin/Network-admin account, choose a short expiry, and revoke
   the access token after provisioning if it is no longer needed.
3. Run `./install-control-plane.sh` or `./install-worker.sh`, select Tailscale,
   and follow the inventory prompts.

No manual Tailscale node, tag, policy, auth-key, address, or firewall setup is
required. The automation installs Tailscale, validates and ETag-merges the
current account policy, derives separate control-plane/worker tags from the
chosen mesh name, creates least-privilege grants, replaces only an untouched
default allow-all policy, and preserves unrelated existing policy. It creates a
one-use, pre-approved,
short-lived tagged key per node, disables node-key expiry for the resulting
tagged servers, removes its temporary secret material, disables Tailscale SSH,
selects `nodivert` so UFW remains authoritative, and configures
`100.64.0.0/10` as the node network.

The assistant asks for the tailnet, a unique mesh/cluster name, control-plane
Tailscale hostname, one-use key lifetime, and API token. It then asks how many
servers to enroll and collects each server's existing SSH IP/DNS name, SSH
user, port, private key, desired Tailscale hostname, and Kubernetes settings
independently. Providers do not need to match. The existing address is only a
temporary bootstrap route; Tailscale assigns the persistent overlay IP used by
K3s after enrollment. No list of public peer IPs is placed in tailnet policy.
Tailscale installation, authentication, address assignment, and `tailscale0`
routing are verified before worker UFW is changed. The firewall hardener refuses
to close public ingress if that preflight is incomplete, preventing SSH lockout
during cross-provider bootstrap.

To provision only the provider-neutral Tailscale mesh (without installing K3s
workers), run:

```bash
./scripts/configure-tailscale.sh --fleet
```

This fleet assistant gathers the same per-server inventory, accepts
control-plane or worker roles, configures every SSH-reachable Debian/Ubuntu
server, and prints the resulting Tailscale IP map.

To add workers later, run the unified worker assistant from either the control
plane or the new worker:

```bash
./install-worker.sh
```

It asks where it is running and which transport to use. Control-plane mode can
enroll any number of remote workers and waits for each to become Ready. Worker
mode joins the current machine and shows the commands used to obtain its K3s
join token:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
sudo k3s token create --ttl 1h --description worker-join
```

Workers have no internet-facing mode. UFW is default-deny inbound and permits
SSH only from the exact control-plane address plus required K3s/Longhorn peer
ports on the chosen private interface. Fail2ban, CrowdSec, and persistent Lynis
are absent from workers. Secret input is hidden and is never stored in the
repository or placed in command-line arguments.

For non-interactive vRack enrollment:

```bash
K3S_NODE_TRANSPORT=vrack \
K3S_WORKER_IPS=10.0.0.12,10.0.0.13 \
K3S_WORKER_IDENTITY_FILE="$HOME/.ssh/id_ed25519" \
K3S_PRIVATE_ADDRESS=10.0.0.10 \
K3S_NODE_NETWORK_CIDR=10.0.0.0/24 \
./install-control-plane.sh --yes
```

Optional settings are `K3S_SERVER_URL`, `K3S_WORKER_SSH_USER`,
`K3S_WORKER_SSH_PORT`, `K3S_WORKER_LABELS`, and `K3S_WORKER_TAINTS`.
Non-interactive Tailscale enrollment uses `K3S_NODE_TRANSPORT=tailscale`,
`K3S_WORKER_HOSTS`, `TAILSCALE_TAILNET`, `TAILSCALE_MESH_NAME`, and a transient
`TAILSCALE_API_TOKEN`; common SSH defaults remain available through the worker
variables above. Interactive hidden input is preferred when servers have
different SSH settings. New metrics/logging DaemonSets automatically run on
eligible workers. Ingress remains pinned to the control plane, and Longhorn's
default for new volumes follows the Ready-node count, capped at three.

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
and retains approximately three months of authentication logs for review.

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

Ansible remains available for repeatable local deployments:

```bash
ansible-playbook ansible/deploy.yml
ansible-playbook ansible/deploy.yml -e server_exposure=local
ansible-playbook ansible/deploy.yml -e install_odoo=false
ansible-playbook ansible/deploy.yml -e deploy_platform_services=false
ansible-playbook ansible/deploy.yml -e k3s_node_network_cidr=10.0.0.0/24
```

Ansible uses the same release versions, ordered manifest inventories,
dependencies, and readiness checks as the interactive installer. It reconciles
all feature groups by default except Cloudflare. Feature switches are
`install_longhorn`, `install_ingress`, `install_vault_stack`,
`deploy_data_stores`, `deploy_platform_services`, `install_odoo`,
`install_descheduler`, and `install_argocd`. Dependencies are enabled
automatically: platform services and Odoo require data stores; data stores
require Vault and External Secrets; Cloudflare requires ingress.

To run the same non-interactive Cloudflare reconciliation from Ansible, export
the secret inputs and opt in explicitly:

```bash
export CLOUDFLARE_API_TOKEN='your Cloudflare User API Token (cfut_... type)'
export CLOUDFLARE_ACCESS_ALLOWED_EMAILS='admin@example.com'
ansible-playbook ansible/deploy.yml -e configure_cloudflare=true
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

## Repository layout

| Path | Purpose |
|---|---|
| `config/platform.env` | Shared release, manifest, readiness, public-host, and private-transport contract |
| `install-control-plane.sh` | Install or reconcile the K3s control plane and platform services |
| `install-worker.sh` | Unified worker assistant for control-plane SSH enrollment or local self-join |
| `scripts/add-k3s-workers.sh` | Internal multi-worker SSH enrollment implementation |
| `scripts/install-k3s-worker.sh` | Internal local worker installation implementation |
| `scripts/audit-cluster-nodes.sh` | Control-plane Lynis runner for local and transient remote audits |
| `scripts/configure-cloudflare.sh` | Cloudflare DNS, edge security, TLS, and Access reconciliation |
| `scripts/configure-tailscale.sh` | Provider-neutral tailnet policy, fleet inventory, role tags, one-use keys, and node reconciliation |
| `scripts/configure-vault.sh` | Vault initialization, policies, and secret seeding |
| `scripts/configure-k3s-backups.sh` | Daily K3s/Vault recovery archives and retention |
| `scripts/configure-k3s-apparmor.sh` | Enforced runtime-default profile with Ubuntu stacking compatibility |
| `scripts/configure-k3s-control-plane-network.sh` | Persist private cluster and public ingress addresses for the K3s control plane |
| `scripts/configure-nexus-registry.sh` | Private image registry, roles, accounts, and Vault credentials |
| `scripts/configure-node-security.sh` | Host firewall and intrusion-prevention setup |
| `scripts/lib/network.sh` | Shared RFC1918, Tailscale, CIDR, and interface validation |
| `scripts/validate-repository.sh` | Consistency checks and optional live server dry-run |
| `deployments/` | Kubernetes resources |
| `ansible/` | Ansible deployment entry point |

## Security notes

- Keep PostgreSQL, MongoDB, Redis, Kafka, Elasticsearch, and Prometheus internal.
- Keep administrative UI hostnames behind Cloudflare Access.
- Revoke short-lived setup tokens after use and rotate bootstrap credentials.
- Keep only required public ports open and update Kubernetes workloads regularly.
- Workers accept no public traffic: never publish, forward, or load-balance traffic to them.
- Worker UFW permits SSH only from the control plane and private K3s peer traffic; outbound access remains available.
- Local-only nodes omit Fail2ban and CrowdSec; local control planes retain Lynis.

## License

GPL 3.0
