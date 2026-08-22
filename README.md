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

Worker enrollment is built into `install-control-plane.sh`; no separate setup
step is required during the initial installation. Answer **yes** to “Add or
reconcile K3s worker nodes over SSH.” It accepts any number of workers and asks
for the SSH settings and each worker's explicit private IPv4 address, unique
node name, labels, and taints. The control plane remains the only server, so
adding workers increases workload capacity but does not make the Kubernetes
control plane highly available.

Worker requirements:

- Debian or Ubuntu, a unique hostname, and an explicitly entered RFC1918 IPv4
  address (`10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`) or Tailscale
  IPv4 address (`100.64.0.0/10`)
- No public IPv4 or public IPv6 interface; IPv6 ULA is permitted, and enrollment
  aborts before making changes when a public address is detected
- No router port-forward, public DNS record, public load balancer, or direct
  internet ingress to a worker
- SSH key authentication from the control plane as root or a user with
  passwordless `sudo`; after enrollment, UFW accepts the worker SSH port only
  from the exact private control-plane source address
- A trusted private node CIDR containing the control-plane K3s address, the
  control-plane SSH source, and every worker address
- TCP 6443 from workers to the server, UDP 8472 between nodes, and TCP 10250
  from the server to workers, restricted to the private node network
- Longhorn's TCP peer ports (2049, 3260, 8000, 8002, 8500-8504, 9500-9503,
  and 10000-31000), restricted to the same private network and interface
- Enough CPU, memory, and disk for the workloads assigned to the node

### Private node network

Set up the private node transport before running either installer. The control
plane and every worker must use the same transport; do not mix vRack/LAN and
Tailscale node addresses in one enrollment run.

#### OVH vRack — recommended for the current cluster

Use vRack for OVH-hosted nodes because it keeps cluster and storage traffic on
OVH's private network without an overlay dependency. OVH's
[dedicated-server vRack guide](https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/vrack-configuring-on-dedicated-server)
is the authority for the current Control Panel and operating-system steps.

1. Confirm that every chosen OVH server supports vRack. In the OVHcloud Control
   Panel, order/activate vRack under **Network → vRack private network**.
2. Open that vRack, add the control plane and every worker, and wait until all
   services show as attached.
3. On each server, identify the secondary/private NIC with `ip -br link` and
   `ip -br address`. Never replace the public NIC configuration on the control
   plane.
4. Assign a unique RFC1918 address to the vRack NIC. For Ubuntu/netplan, create
   or merge the following structure, substituting the actual interface and a
   unique address on every host:

   ```yaml
   network:
     version: 2
     ethernets:
       eno2:
         dhcp4: false
         addresses:
           - 10.50.0.10/24 # control plane; use .11, .12, ... on workers
   ```

   Validate safely with `sudo netplan try`, then apply with
   `sudo netplan apply`. OVH dedicated servers use untagged VLAN 0 by default;
   configure an 802.1Q VLAN only when you deliberately created one. The
   [OVH mixed Public Cloud/dedicated guide](https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/configuring-the-vrack-between-the-public-cloud-and-a-dedicated-server)
   covers that tagged case.
5. Verify private routing in both directions with `ping` and SSH using only the
   chosen vRack IPs. Use `10.50.0.0/24` as `K3S_NODE_NETWORK_CIDR` in this
   example.
6. Workers must not retain public addressing. Before removing their public
   network configuration, verify vRack access through the control plane and
   arrange controlled outbound egress/NAT for updates and image pulls. Keep an
   OVH IPMI/KVM recovery path available while changing network configuration.

#### Tailscale — cross-provider alternative

Use Tailscale when nodes span providers or no common private network is
available. Install and authenticate it on the control plane and every worker
before enrollment, following the official
[Linux installation guide](https://tailscale.com/docs/install/linux):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh=false
tailscale ip -4
tailscale status
```

For repeatable server provisioning, Tailscale recommends tagged nodes and auth
keys; create a restricted `tag:k3s-node` in the tailnet policy, generate an auth
key for that tag, and follow the
[server provisioning guide](https://tailscale.com/kb/1245/set-up-servers).
Do not enable Tailscale SSH: the host's regular sshd and UFW enforce the exact
control-plane source rule. When Tailscale addresses are selected, the security
script automatically selects `nodivert` netfilter mode so UFW remains
authoritative; see the official
[netfilter-mode reference](https://tailscale.com/docs/reference/netfilter-modes).

Use the control plane's `tailscale ip -4` result as `K3S_PRIVATE_ADDRESS`, each
worker's result as its worker IP, and `100.64.0.0/10` as
`K3S_NODE_NETWORK_CIDR`. No address is hard-coded in this repository.

To add workers later, run the unified worker assistant from either the control
plane or the new worker:

```bash
./install-worker.sh
```

It first asks where it is running. **Control-plane mode** asks how many workers
to add and for their SSH addresses, reads the local token without printing it,
copies the installer to every worker, and waits for each node to become Ready.
**Worker mode** joins the current machine and asks for the control-plane address
and token. It displays these commands to run on the control plane; the second
creates an optional short-lived token:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
sudo k3s token create --ttl 1h --description worker-join
```

Workers are always private-only; there is no internet-facing worker mode. Both
paths validate the explicitly supplied RFC1918 or Tailscale addresses before
changing the machine, apply a default-deny inbound UFW policy before K3s
enrollment, allow SSH only from the control plane, and retain only the selected
private-interface K3s peer rules. Fail2ban and CrowdSec are removed from workers
because public SSH is impossible; Lynis is never installed persistently there.
Outbound traffic remains allowed for updates, image pulls, and workloads. Token
input is hidden and is never placed in command-line arguments or copied to disk.

For repeatable enrollment through the control-plane installer:

```bash
K3S_WORKER_IPS=10.0.0.12,10.0.0.13 \
K3S_WORKER_IDENTITY_FILE="$HOME/.ssh/id_ed25519" \
K3S_PRIVATE_ADDRESS=10.0.0.10 \
K3S_NODE_NETWORK_CIDR=10.0.0.0/24 \
./install-control-plane.sh --yes
```

Optional common settings are `K3S_SERVER_URL`, `K3S_WORKER_SSH_USER`,
`K3S_WORKER_SSH_PORT`, `K3S_WORKER_LABELS`, and `K3S_WORKER_TAINTS`. The K3s
server URL and every worker address must be RFC1918 or Tailscale IPv4 literals.
`K3S_PRIVATE_ADDRESS`, `K3S_PRIVATE_INTERFACE`, and `K3S_PUBLIC_ADDRESS` can
override control-plane network detection. The installer persists the private
node IP, public ExternalIP, API certificate SAN, and Flannel interface in a K3s
configuration drop-in before enrolling workers. New DaemonSet
workloads, including node metrics and log collection, automatically run on
eligible workers. The control plane alone receives K3s' LoadBalancer allowlist
label, and ingress is pinned there. The installer sets Longhorn's default
replica count for new volumes to the number of Ready nodes, capped at three; it
does not relocate or change existing volumes.

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
| `config/platform.env` | Shared release, manifest, readiness, and public-host contract |
| `install-control-plane.sh` | Install or reconcile the K3s control plane and platform services |
| `install-worker.sh` | Unified worker assistant for control-plane SSH enrollment or local self-join |
| `scripts/add-k3s-workers.sh` | Internal multi-worker SSH enrollment implementation |
| `scripts/install-k3s-worker.sh` | Internal local worker installation implementation |
| `scripts/audit-cluster-nodes.sh` | Control-plane Lynis runner for local and transient remote audits |
| `scripts/configure-cloudflare.sh` | Cloudflare DNS, edge security, TLS, and Access reconciliation |
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
- Workers are permanently local-only: never assign or forward public traffic to them.
- Worker UFW permits SSH only from the control plane and private K3s peer traffic; outbound access remains available.
- Local-only nodes omit Fail2ban and CrowdSec; local control planes retain Lynis.

## License

GPL 3.0
