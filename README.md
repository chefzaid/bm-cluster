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
- UFW on every node, Fail2ban and CrowdSec on internet-facing nodes, and control-plane Lynis audits

## Architecture

Public HTTPS traffic enters through the NGINX LoadBalancer and is routed by
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

## Service dashboard

Open `https://dashboard.swirlit.dev` for the complete categorized service
catalog. Cloudflare Access protects the dashboard, DBGate, Grafana, Kafka UI,
Kibana, Longhorn, Portainer, and Vault with an email one-time PIN and a 24-hour
session. Machine- and application-facing hostnames retain their native
authentication so CLIs, webhooks, CI agents, scanners, and application users
continue to work.

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
for the SSH settings and each worker's address, unique node name, optional
private IP, labels, and taints. The control plane remains the only server, so
adding workers increases workload capacity but does not make the Kubernetes
control plane highly available.

Worker requirements:

- Debian or Ubuntu, a unique hostname, and network access to the control plane
- SSH key authentication as root or a user with passwordless `sudo`; workers
  marked internet-facing require the non-root option because that policy disables
  root SSH login
- A trusted private node CIDR so UFW can allow only required cluster traffic
- TCP 6443 from workers to the server, UDP 8472 between nodes, and TCP 10250
  from the server to workers, restricted to the private node network
- Enough CPU, memory, and disk for the workloads assigned to the node

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

Both modes ask whether the worker is internet-facing or local/private. UFW is
configured on every worker. Fail2ban, CrowdSec, and additional SSH hardening are
installed only on internet-facing workers. Lynis is never installed persistently
on workers. Token input is hidden and is never placed in command-line arguments
or copied to disk.

For repeatable enrollment through the control-plane installer:

```bash
K3S_WORKER_HOSTS=ubuntu@10.0.0.12,ubuntu@10.0.0.13 \
K3S_WORKER_IDENTITY_FILE="$HOME/.ssh/id_ed25519" \
K3S_WORKER_EXPOSURE=local \
K3S_NODE_NETWORK_CIDR=10.0.0.0/24 \
./install-control-plane.sh --yes
```

Optional common settings are `K3S_SERVER_URL`, `K3S_WORKER_SSH_USER`,
`K3S_WORKER_SSH_PORT`, `K3S_WORKER_EXPOSURE`, `K3S_WORKER_LABELS`, and
`K3S_WORKER_TAINTS`. Worker exposure defaults to `local`; set it to `internet`
only when the worker itself accepts traffic from the public internet. New
DaemonSet workloads, including node metrics and log collection, automatically
run on eligible workers. The installer sets Longhorn's default replica count for
new volumes to the number of Ready nodes, capped at three; it does not relocate
or change existing volumes.

## Host security policy

| Node | Local/private | Internet-facing |
|---|---|---|
| Control plane | UFW and Lynis | UFW, Fail2ban, CrowdSec, SSH hardening, and Lynis |
| Worker | UFW | UFW, Fail2ban, CrowdSec, and SSH hardening |

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
ansible-playbook ansible/deploy.yml -e k3s_node_network_cidr=10.0.0.0/24
```

The Ansible playbook deploys platform resources to the cluster in the active
kubeconfig; worker operating-system provisioning is handled by the scripts
above, not by the Ansible inventory.

## Repository layout

| Path | Purpose |
|---|---|
| `install-control-plane.sh` | Install or reconcile the K3s control plane and platform services |
| `install-worker.sh` | Unified worker assistant for control-plane SSH enrollment or local self-join |
| `scripts/add-k3s-workers.sh` | Internal multi-worker SSH enrollment implementation |
| `scripts/install-k3s-worker.sh` | Internal local worker installation implementation |
| `scripts/audit-cluster-nodes.sh` | Control-plane Lynis runner for local and transient remote audits |
| `scripts/configure-cloudflare.sh` | Cloudflare DNS, edge security, TLS, and Access reconciliation |
| `scripts/configure-vault.sh` | Vault initialization, policies, and secret seeding |
| `scripts/configure-k3s-backups.sh` | Daily K3s/Vault recovery archives and retention |
| `scripts/configure-k3s-apparmor.sh` | Enforced runtime-default profile with Ubuntu stacking compatibility |
| `scripts/configure-nexus-registry.sh` | Private image registry, roles, accounts, and Vault credentials |
| `scripts/configure-node-security.sh` | Host firewall and intrusion-prevention setup |
| `deployments/` | Kubernetes resources |
| `ansible/` | Ansible deployment entry point |

## Security notes

- Keep PostgreSQL, MongoDB, Redis, Kafka, Elasticsearch, and Prometheus internal.
- Keep administrative UI hostnames behind Cloudflare Access.
- Revoke short-lived setup tokens after use and rotate bootstrap credentials.
- Keep only required public ports open and update Kubernetes workloads regularly.
- Local-only nodes keep UFW but omit Fail2ban and CrowdSec; local control planes retain Lynis.

## License

GPL 3.0
