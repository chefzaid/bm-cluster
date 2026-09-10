# Installation

Run commands from this repository on the first control-plane host as a non-root
user with sudo access. Use an Ubuntu host and size CPU, memory, and disk for the
selected services' [resource and volume requests](../k8s/), including headroom
for builds, snapshots, and backups.
Remote enrollment requires unique node names, SSH keys and passwordless sudo
from the first control plane to every new Debian/Ubuntu host.

## Choose an entry point

| Command | Purpose |
| --- | --- |
| `./install-control-plane.sh` | Guided cluster installation, including planned nodes and platform services |
| `./add-node.sh` | Add control planes or workers to an existing cluster |
| `./replicate-repo.sh` | Import GitHub repositories into GitLab, configure two-way sync and select deployments |
| `ansible/install.yml` | Run the full installer unattended through Ansible |
| `ansible/deploy.yml` | Reconcile an installed platform through Ansible |

For a new cluster:

```bash
./install-control-plane.sh
```

The assistant collects the domain, node identity, installation scope, topology,
platform components, recovery destination, public access and administrator
credentials. The recommended bundle installs the shared platform; declining it
lets you select components individually. `infra + apps` adds centrally managed
Odoo in `corp`. External applications remain in their own repositories and
are onboarded through [repository replication](repository-replication.md).

Prepare a domain for public deployment and an accessible GitOps repository URL.
For multiple nodes, choose one [private transport](networking.md#private-node-network)
and complete its account prerequisites. Interactive setup guides these steps
before changing the firewall. Unattended runs require them to be complete.
The administrator password follows the [identity policy](security.md).

## Topology and scheduling

Choose an odd final control-plane count (`1`, `3`, `5`, …) and a total node count
that includes control planes and workers. For three control planes and four
workers, enter `3` and `7`. Multiple control planes use embedded etcd; additional
servers join sequentially over the private network.

`CONTROL_PLANE_SCHEDULABLE=true` allows workloads on every control plane.
`false` applies the control-plane `NoSchedule` taint after workers are Ready.
Clusters without workers must permit control-plane workloads. Node enrollment
also reconciles [Longhorn placement and replicas](node-enrollment.md#scheduling-and-storage).

An etcd majority must remain available. The default public entry point remains
the first host after node enrollment. For replicated public ingress, shared
data services and application profiles, follow the separate
[HA migration](high-availability.md) after enrolling sufficient hosts.
Administrative API access uses a reachable control plane's private address;
no floating API address is installed. See the
[K3s embedded-etcd guide](https://docs.k3s.io/datastore/ha-embedded).

## Unattended installation

`--yes` chooses the recommended component bundle and defaults to `INSTALL_SCOPE=apps`.
This example installs a single node with local exposure. Replace the domain,
node name and GitOps URL with your own values:

```bash
export PLATFORM_DOMAIN=example.com
export CONTROL_PLANE_NODE_NAME=control-plane-01
export SERVER_EXPOSURE=local
export INSTALL_SCOPE=apps
export CONTROL_PLANE_COUNT=1 CLUSTER_NODE_COUNT=1
export CONTROL_PLANE_SCHEDULABLE=true
export GITOPS_REPOSITORY_URL=https://github.com/example/bm-cluster.git
export KEYCLOAK_SSO_BOOTSTRAP_USERNAME=platform-admin
read -rsp 'Platform administrator password: ' KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
echo
export KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
./install-control-plane.sh --yes
unset KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
```

| Input | Meaning |
| --- | --- |
| `INSTALL_SCOPE=infra` | Omit Odoo; keep shared infrastructure |
| `SERVER_EXPOSURE=internet` | Enable the public host security policy; unattended installation enables Cloudflare by default |
| `INTERNAL_DNS_ZONE` | Optional override for `internal.<PLATFORM_DOMAIN>` |
| `CLOUDFLARE_NODE_DNS_LABEL` | Public administration hostname label, independent of the Kubernetes node name; defaults to `node-01` |
| `CLOUDFLARE_PUBLISH_APEX` | Defaults to `false`; explicitly opt in only if the platform should manage apex DNS |
| `CONTROL_PLANE_COUNT`, `CLUSTER_NODE_COUNT` | Desired final counts, including already registered nodes |
| `K3S_NODE_TRANSPORT` | `vrack` or `tailscale` for multi-node enrollment |
| `K3S_CONTROL_PLANE_IPS`, `K3S_WORKER_IPS` | Comma-separated prepared vRack addresses; exclude the first host |
| `K3S_CONTROL_PLANE_HOSTS`, `K3S_WORKER_HOSTS` | Comma-separated Tailscale bootstrap SSH targets such as `admin@host`; private addresses are discovered |
| `K3S_CONTROL_PLANE_SSH_USER`, `K3S_WORKER_SSH_USER` | SSH users for address-based enrollment |

For example, after supplying the identity and
[Tailscale inputs](networking.md#tailscale):

```bash
CONTROL_PLANE_COUNT=3 CLUSTER_NODE_COUNT=5 CONTROL_PLANE_SCHEDULABLE=false \
K3S_NODE_TRANSPORT=tailscale \
K3S_CONTROL_PLANE_HOSTS='admin@cp-02,admin@cp-03' \
K3S_WORKER_HOSTS='admin@worker-01,admin@worker-02' \
  ./install-control-plane.sh --yes
```

When rerunning with only a partial list of new hosts, set both final counts
explicitly. Registered nodes count even when NotReady; completion requires the
planned nodes to be Ready. Reruns preserve an existing K3s installation by
default; they are not a K3s upgrade procedure. Use
[node enrollment](node-enrollment.md) for later expansion.

## Optional integrations

- **Public DNS, TLS and Access:** use the [Cloudflare setup](networking.md#cloudflare).
  For unattended internet exposure, supply `CLOUDFLARE_API_TOKEN` and
  `CLOUDFLARE_ACCESS_ALLOWED_EMAILS`; set `CLOUDFLARE_ACCESS_TEAM_NAME` to your
  existing Zero Trust team label. `CONFIGURE_CLOUDFLARE=false` uses local TLS
  certificates while preserving existing TLS secrets; public DNS/TLS then
  needs separate configuration.
- **Encrypted offsite backups:** set `CONFIGURE_OFFSITE_BACKUPS=true` with
  `BACKUP_S3_ENDPOINT`, `BACKUP_S3_BUCKET`, `BACKUP_S3_REGION`,
  `BACKUP_S3_ACCESS_KEY`, `BACKUP_S3_SECRET_KEY` and `BACKUP_REPOSITORY_PASSWORD`.
  Keep the repository password outside the cluster for recovery.
- **Repository import and deployment:** set `CONFIGURE_REPOSITORY_SYNC=true`
  with the inputs in [repository replication](repository-replication.md).
  This runs after the platform and Argo CD are ready.

Supply secrets through hidden prompts, process environment or encrypted
[Ansible variables](ansible.md#complete-installation). Never commit credentials
or generated cluster values.

## Verify the result

```bash
kubectl get nodes
kubectl get applications -n infra
./scripts/validate-repository.sh --live
```

The installer waits for selected components and reports their endpoints. Open
`https://dashboard.<your-domain>` for the service catalog. See
[Ansible](ansible.md) for repeatable platform reconciliation and
[Argo CD](delivery.md#argo-cd-operations) for ongoing GitOps ownership.
