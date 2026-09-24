# Installation

Run commands from this checkout on the first control-plane host as a non-root
user with sudo access. Use Ubuntu and size CPU, memory, and disk for the
selected services' [resource and volume requests](../k8s/), with headroom for
builds, snapshots, and backups. Unattended runs require passwordless sudo.

Prepare your public domain, an accessible GitOps repository, and the
[administrator credentials](security.md#administrator-sign-in). For multiple
nodes, complete the [private transport prerequisites](networking.md#private-node-network)
and [remote enrollment requirements](node-enrollment.md#remote-enrollment).
Interactive setup guides account configuration before changing the firewall;
unattended runs require it to be ready.

## Choose an entry point

| Task | Entry point |
| --- | --- |
| Guided installation | `./install-control-plane.sh` |
| Unattended installation | [`./install-control-plane.sh --yes`](#unattended-installation) or [Ansible installation](#ansible-installation) |
| Reconcile an installed platform | [Ansible reconciliation](#platform-reconciliation) |
| Add control planes or workers | [`./add-node.sh`](node-enrollment.md) |
| Create an application environment on another machine | [Application deployment clusters](#application-deployment-clusters) |
| Import, synchronize and deploy applications | [`./add-repos.sh`](repository-onboarding.md) |

For a new cluster, run:

```bash
./install-control-plane.sh
```

The assistant collects identity, installation scope, topology, components,
recovery destination, public access and administrator credentials. Accept the
recommended shared-platform bundle or select components individually.
`INSTALL_SCOPE=apps` also installs Odoo in `corp`; `infra` omits it. Both scopes
provide the `apps` namespace and its networking, credentials and TLS foundation
for [application-owned deployments](repository-onboarding.md).

Existing ingress-nginx or private-image installations must first follow the
[platform migration](platform-migration.md). Ordinary reconciliation stops at a
read-only migration check; `platform_migration_approved=true` is reserved for a
prepared Ansible maintenance run. Retired image-profile inputs are rejected.
New installations use public upstream images and a separate Traefik release.

## Application deployment clusters

Install the shared platform once. Dedicated `int`, `uat` and `prod` machines run
application workloads; they use the same GitLab, Argo CD, Vault, registry,
Keycloak and data services. The platform installer and `INSTALL_SCOPE` do not
create these targets.

Copy [`deployment-environments.example.yaml`](../config/deployment-environments.example.yaml)
to your installation configuration and supply all three target entries. Shared
service addresses belong under `platform`; each environment supplies its own
cluster/API address, node allocation, ingress address and application domain.

| Environment | Application domain | Example DevApp hostname |
| --- | --- | --- |
| `int` | `int.example.com` | `devapp.int.example.com` |
| `uat` | `uat.example.com` | `devapp.uat.example.com` |
| `prod` | `example.com` | `devapp.example.com` |

Prepare a Tailscale connection between the platform and target hosts. Use
distinct role tags and explicit tailnet grants: platform Argo/Vault nodes need
the target API on TCP 6443; application nodes need the shared gateway ports
declared in the inventory. Target clusters have disjoint node CIDRs. Pod/service
CIDRs may repeat only while pod networks are not routed between clusters. Never
reuse another cluster's bootstrap token or recovery destination.

The managed gateway uses the platform node's Tailscale address. If Kubernetes
advertises another private address, set `platform.gateway.nodeName` to the
registered node name; verification checks that its `tailscale0` owns the given
address. PostgreSQL, Redis, each Kafka broker, Vault and the registry have
separate gateway ports. A small shared TCP proxy keeps internal service
addresses private and admits only configured Tailscale node CIDRs. Authentication
remains mandatory; plain vRack transport alone does not meet this contract.
The gateway currently has one declared node, so its availability is a separate
limit from datastore replication.

Before opening the gateway, enable the guarded shared-data authentication
profile described in [application data access](application-onboarding.md#shared-application-data).
Existing anonymous Redis clients must migrate first. Registration runs
`configure-application-data.py --check` and stops if Redis/Kafka authentication
or broker endpoints have not converged.

On each prepared Ubuntu target, install `python3-yaml`, `curl`, `jq`, `openssl`,
`nftables`, and Tailscale, then run as a sudo-capable user:

```bash
./scripts/install-application-cluster.sh \
  --config /secure/deployment-environments.yaml --environment int
```

Repeat with the matching environment on its own host. Bootstrap installs pinned
K3s, the explicit shared-registry mirror, AppArmor policy and a persistent guard
for private K3s control/overlay ports. It binds the API and kubelet to Tailscale,
keeps credentials in a separate `~/.kube/<clusterName>.yaml`, and refuses to
convert an existing unrelated cluster. It installs no platform services or
default persistent storage. Preserve the host's existing SSH access policy.

Transfer the generated target administrator kubeconfig securely to your
administration host. From the platform checkout, register one target:

```bash
python3 scripts/configure-deployment-environments.py \
  --config /secure/deployment-environments.yaml --environment int \
  --platform-kubeconfig /secure/platform.yaml \
  --target-kubeconfig /secure/apps-int.yaml \
  --vault-token-file /secure/platform-vault-admin-token
```

Both kubeconfigs must verify their API certificates. The Vault token is used
only through the central kubeconfig and is never copied to an application
cluster. Supply `CLOUDFLARE_API_TOKEN` through the environment for an environment
origin certificate, or provide `--tls-cert` and `--tls-key` for an existing
certificate chain covering the environment domain and its wildcard. For a
private HTTPS Vault endpoint, set `vault.caSecretName` and supply `--vault-ca`.
The example uses HTTP Vault inside the verified encrypted Tailscale path.

Registration installs Traefik and External Secrets, then checks actual node
routes, API access, shared dependencies, Vault authentication and ingress TLS.
It grants central Argo access only to `apps` in the selected cluster through
`applications-<environment>`. Central Vault uses a separate
`kubernetes-<environment>` auth mount with short-lived client tokens; policies
can read that environment's application credentials and shared application
registry credentials, never platform administrator secrets.

Only a successful registration publishes the selected target into
`infra/deployment-environments`. [Repository onboarding](repository-onboarding.md)
and CI use that verified inventory; merely adding a YAML entry does not enable
deployment. Reruns preserve the cluster identity and reject another environment's
CA/UID. `--rotate-argocd-token` verifies a replacement scoped Argo credential
before replacing the central registration and revoking the old credential.
Keep administrator kubeconfigs and Vault recovery material outside Git.

Cloudflare publishing additionally requires an active edge certificate for the
exact application hostname: the usual `*.example.com` certificate does not cover
`devapp.int.example.com`. The [application DNS helper](../scripts/configure-application-dns.py)
checks coverage before changing DNS. For a new nested hostname, pre-issue an
Advanced or Custom edge certificate: enabling Total TLS alone cannot pass this
guard because Total TLS needs the DNS record before issuing coverage. Valid
publicly trusted custom origin certificates remain externally managed; the helper
refuses to replace an invalid custom certificate. Certificate preparation does not move
existing production DNS. Do not cut over an existing production app until its
data and application readiness have been verified.

Argo CD tracks these applications centrally. Target metrics/log forwarding and
target persistent storage are not installed by this minimal foundation; central
Prometheus's local namespace discovery does not monitor another cluster. See
[delivery](delivery.md) for environment promotion and verification, and
[application node enrollment](node-enrollment.md#application-cluster-nodes) before
expanding a target.

### Prepare application CI before targets exist

Version 2 onboarding configures the [scoped project runners](delivery.md#application-delivery)
automatically. For an existing GitLab project whose target machines are not ready,
protect its default branch, finish any active jobs, and prepare CI independently:

```bash
python3 scripts/configure-application-delivery.py \
  --application devapp --project team/devapp --checkout /path/to/devapp
```

Run from the shared platform administration host. The command acquires and revokes
a temporary GitLab administrator token, or uses `GITLAB_ADMIN_TOKEN` if supplied.
It discovers registered targets from the platform; with none registered, jobs can
build but have no Application write permissions. Runner credentials stay in a
central Kubernetes Secret, and job caches are ephemeral. Rerun application
onboarding after registering targets to provision data, DNS and deployment access.

## Topology and scheduling

Choose an odd final control-plane count (`1`, `3`, `5`, …) and a total count that
includes workers. Control planes must remain schedulable when there are no
workers. See the [topology and exposure model](networking.md#node-topology) and
[scheduling and storage rules](node-enrollment.md#scheduling-and-storage).
Additional hosts alone do not activate the [HA profile](high-availability.md).

## Organization and installation identity

The installer renders URLs, registry paths, authentication issuers, discovery
settings and branding from your inputs; the source checkout stays generic.
The required company display name gives the intranet its `<company name> Cloud`
title and cluster label. Keycloak's realm display name and Odoo's main company
use the company name without the suffix.

| Environment input | Helm value | Default or requirement |
|---|---|---|
| `ORGANIZATION_NAME` | `organizationName` | Required company display name, including spaces and punctuation; the intranet appends ` Cloud`. |
| `ORGANIZATION_SLUG` | `organizationSlug` | First label of the public domain; a lowercase DNS label. |
| `PLATFORM_DOMAIN` | `publicDomain` | Required public base domain, such as `example.com`. |
| `INTERNAL_DNS_ZONE` | `internalDnsZone` | `internal.<PLATFORM_DOMAIN>`; must differ from the public domain. |
| `GITLAB_GROUP_PATH` | `gitlabGroupPath` | Organization slug; the installer provisions a top-level group. |
| `GITLAB_GROUP_NAME` | `gitlabGroupName` | Organization display name. |
| `GITLAB_PROJECT_NAME` | `gitlabProjectName` | `bm-cluster`; platform GitLab integrations follow this choice. |
| `KEYCLOAK_REALM` | `keycloakRealm` | Organization slug; `master` is reserved for Keycloak administration. |
| `TLS_SECRET_NAME` | `tlsSecretName` | Public domain with dots replaced by hyphens, plus `-tls`; shared by ingress and certificate provisioning. `CLOUDFLARE_TLS_SECRET_NAME` is an alias. |
| `SONAR_ALM_SETTING` | `sonarAlmSetting` | `<organization-slug>-gitlab`; the managed Sonar GitLab integration. |
| `CLOUDFLARE_ACCESS_IDP_NAME` | `cloudflareAccessIdpName` | `<organization-name> Keycloak`; identifies the managed Access identity provider. |
| `CLOUDFLARE_ACCESS_TEAM_NAME` | `cloudflareAccessTeamName` | Existing Zero Trust team label, or `bm-cluster-<domain-with-hyphens>` for a new team. |
| `GITOPS_REPOSITORY_URL` | `gitopsRepositoryURL` | Accessible HTTP(S) `.git` URL; interactive setup suggests the checkout's remote. |

The generated Argo CD Application carries these settings into subsequent Helm
reconciliation. The public `infra/bm-cluster-identity` ConfigMap records installed
choices for installer reruns, Ansible, and provisioning helpers. Explicit
environment inputs override stored choices. Credentials stay in the
[secret-management flow](security.md#recovery-credentials).

To rebrand an existing installation, update `organizationName` in the installed
`bm-cluster` Argo CD Application's Helm parameters and reconcile the platform.
Use the same `ORGANIZATION_NAME` for installer or Ansible overrides. Display
settings such as `GITLAB_GROUP_NAME` and `CLOUDFLARE_ACCESS_IDP_NAME` are stored
separately; update them explicitly when their labels also need to change.
Keep the domain, organization slug, SSO realm and repository paths unchanged
when changing display names.

For an existing installation created before this identity contract, preserve its
current realm, GitLab group/project, TLS secret, organization name, and integration
names as explicit Helm parameters on the installed `bm-cluster` Application
**before syncing the generalized chart**. Supply the same values to a first
installer/Ansible rerun. This records the existing identity; changing a realm,
domain, or repository path is a separate migration of accounts and resources.

## Unattended installation

`--yes` selects the recommended component bundle and defaults to
`INSTALL_SCOPE=apps`. This example uses local exposure; replace the identity,
node name and GitOps URL with your own values:

```bash
export ORGANIZATION_NAME='Example Company'
export ORGANIZATION_SLUG=example
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

Identity inputs and defaults are listed [above](#organization-and-installation-identity).
Other installation inputs are:

| Input | Meaning |
| --- | --- |
| `INSTALL_SCOPE` | `apps` includes Odoo; `infra` omits it. |
| `SERVER_EXPOSURE` | `local` or `internet`; internet exposure enables the public host policy and defaults to Cloudflare configuration. |
| `CONTROL_PLANE_NODE_NAME` | Local Kubernetes node name; defaults to the lowercase host name. |
| `CONTROL_PLANE_COUNT`, `CLUSTER_NODE_COUNT` | Desired final counts, including registered nodes; the control-plane count must be odd. |
| `CONTROL_PLANE_SCHEDULABLE` | `true` permits workloads on all control planes; `false` applies `NoSchedule` after workers are Ready. Defaults to `true` without workers, otherwise `false`. |
| `K3S_NODE_TRANSPORT` | `vrack` or `tailscale` for multi-node enrollment. |
| `K3S_CONTROL_PLANE_IPS`, `K3S_WORKER_IPS` | Comma-separated prepared vRack addresses; exclude the first host. |
| `K3S_CONTROL_PLANE_HOSTS`, `K3S_WORKER_HOSTS` | Comma-separated Tailscale bootstrap SSH targets such as `admin@host`; private addresses are discovered. |
| `K3S_CONTROL_PLANE_SSH_USER`, `K3S_WORKER_SSH_USER` | SSH users for address-based enrollment. |
| `CLOUDFLARE_NODE_DNS_LABEL` | Public administration label, independent of the Kubernetes node name; defaults to `node-01`. |
| `CLOUDFLARE_PUBLISH_APEX` | `false`; opt in only if the platform should manage apex DNS. |

For example, after supplying identity, credentials and the
[Tailscale inputs](networking.md#tailscale):

```bash
CONTROL_PLANE_COUNT=3 CLUSTER_NODE_COUNT=5 CONTROL_PLANE_SCHEDULABLE=false \
K3S_NODE_TRANSPORT=tailscale \
K3S_CONTROL_PLANE_HOSTS='admin@cp-02,admin@cp-03' \
K3S_WORKER_HOSTS='admin@worker-01,admin@worker-02' \
  ./install-control-plane.sh --yes
```

On retries with a partial list of new hosts, set both final counts explicitly.
Registered nodes count even when NotReady; completion requires the planned nodes
to be Ready. Reruns preserve installed K3s by default and do not upgrade it.
Use [node enrollment](node-enrollment.md) for later expansion.

### Optional integrations

Use the same integration credentials with either entry point. Keep secrets in
hidden prompts, the process environment or Ansible Vault; never commit
credentials or generated cluster configuration.

- **Public DNS, TLS and Access:** follow [Cloudflare setup](networking.md#cloudflare)
  for tokens, allowed emails, the existing Zero Trust team and account
  prerequisites. In the shell installer, `CONFIGURE_CLOUDFLARE=false` uses local
  TLS while preserving existing TLS secrets; public DNS/TLS then needs separate
  configuration.
- **Encrypted offsite backups:** set `CONFIGURE_OFFSITE_BACKUPS=true`,
  `BACKUP_S3_ENDPOINT`, `BACKUP_S3_BUCKET`, `BACKUP_S3_REGION`,
  `BACKUP_S3_ACCESS_KEY`, `BACKUP_S3_SECRET_KEY` and `BACKUP_REPOSITORY_PASSWORD`.
  Keep the password outside the cluster; see
  [backup and recovery](operations.md#backups-and-recovery).
- **Repository import and deployment:** set `CONFIGURE_REPOSITORY_SYNC=true`
  and supply the [onboarding automation inputs](repository-onboarding.md#automation-and-reruns).
  The installer calls `add-repos.sh` after platform and Argo CD readiness,
  forwarding `--yes` for unattended runs. Selecting deployment authorizes the
  app configuration commits and service changes described in that guide.

## Ansible

Both playbooks run locally from this checkout using the supplied `localhost`
inventory. Adding inventory hosts does not distribute installation; node
enrollment uses SSH. Bootstrap and default-mode reconciliation run on the first
control plane; an HA platform can be reconciled from a surviving control plane.

The playbooks share [platform defaults](../config/platform.env), manifest
inventories and provisioning helpers with the shell installer. Longhorn, Vault,
External Secrets and Argo CD releases use
[`reconcile-platform-release.sh`](../scripts/reconcile-platform-release.sh)
for chart options and readiness; each entry point controls selection and order.
Vault readiness follows resource application and precedes secrets bootstrap.

### Ansible installation

Install the prerequisites on the first Ubuntu host:

```bash
sudo apt-get update
sudo apt-get install -y ansible git python3
```

Export the [unattended inputs](#unattended-installation), then run the full
installer through Ansible:

```bash
ansible-playbook -i ansible/inventory ansible/install.yml
```

An optional `installer_environment` mapping overrides selected process inputs.
For example, store this mapping in an Ansible Vault encrypted extra-vars file:

```yaml
installer_environment:
  ORGANIZATION_NAME: Example Company
  ORGANIZATION_SLUG: example
  PLATFORM_DOMAIN: example.com
  CONTROL_PLANE_NODE_NAME: control-plane-01
  SERVER_EXPOSURE: local
```

```bash
ansible-playbook -i ansible/inventory ansible/install.yml \
  -e @/secure/cluster-install.yml --ask-vault-pass
```

The installation task uses `no_log` because nested commands handle secrets.
Failures stop the play; run the shared installer with the same inputs for visible
diagnostics.

### Platform reconciliation

Use `ansible/deploy.yml` on an installed control plane with its matching
kubeconfig, kubectl, Helm, jq, OpenSSL, Git, Python and Ansible. Preflight verifies
the local K3s service, control-plane role and kubeconfig before host changes.
Workers are rejected; joined private control planes are accepted when HA is
requested or already recorded.

Supply `KEYCLOAK_SSO_BOOTSTRAP_USERNAME` and `KEYCLOAK_SSO_BOOTSTRAP_PASSWORD`
through the secret environment when reconciling platform services, then run:

```bash
ansible-playbook -i ansible/inventory ansible/deploy.yml
```

Installed [identity settings](#organization-and-installation-identity) are reused
unless explicitly overridden. Set `CONTROL_PLANE_NODE_NAME` if the registered
name differs from the local hostname. Exposure defaults to `internet`; use
`-e server_exposure=local` for a locally exposed bootstrap host. Joined servers
retain their private exposure.

The playbook preserves control-plane scheduling unless
`CONTROL_PLANE_SCHEDULABLE=true|false` explicitly changes it, reconciles
[private SSH access](node-enrollment.md#control-plane-administration) from
registered control-plane addresses, and applies the shared
[storage placement rules](node-enrollment.md#scheduling-and-storage).

Before activating HA, complete the PostgreSQL, Kafka and Vault migrations in
[activation order](high-availability.md#activate-in-order). Reconcile with
`HIGH_AVAILABILITY_ENABLED=true` and `PLATFORM_HA_VALUES_FILE`, including
`-e configure_cloudflare=true` for the public Tunnel/DNS cutover. The playbook
preserves recorded HA on later runs and rejects unfinished migrations or
implicit downgrades.

Feature switches select tasks and automatically include their dependencies:
Odoo needs platform services, those services need data stores, data stores need
Vault/External Secrets, and Cloudflare needs ingress.

| Switch | Default |
| --- | --- |
| `install_longhorn`, `install_ingress`, `install_vault_stack` | `true` |
| `deploy_data_stores`, `deploy_platform_services` | `true` |
| `install_apps`, `install_odoo` | `true` |
| `install_descheduler`, `install_argocd`, `manage_host_security` | `true` |
| `configure_cloudflare`, `manage_private_transport` | `false` |

`-e install_apps=false` omits Odoo while retaining the shared `apps` foundation.
Disabling a switch does not uninstall components; Argo CD continues reconciling
its configured scope. Application deployments remain owned by their repositories.

### Optional host and account changes

Private transport reconciliation is opt-in and runs before K3s network binding
and UFW. Export the [transport inputs](networking.md#private-node-network) and
choose the existing transport:

```bash
# Already attached and addressed vRack:
ansible-playbook -i ansible/inventory ansible/deploy.yml \
  -e manage_private_transport=true -e k3s_node_transport=vrack

# Tailscale, with its API token supplied in the environment:
ansible-playbook -i ansible/inventory ansible/deploy.yml \
  -e manage_private_transport=true -e k3s_node_transport=tailscale
```

For API-managed vRack attachment, add `-e ovh_vrack_automate_account=true`
and the OVH account inputs. Without transport reconciliation, supply
`K3S_NODE_NETWORK_CIDR` when host security must trust node traffic.

Cloudflare requires its [integration inputs](#optional-integrations) and
`-e configure_cloudflare=true`. Offsite recovery and repository import use the
same optional inputs as installation. Repository setup uses `no_log`, waits for
required app jobs and readiness, and stops the play on failure. Run `add-repos.sh`
with the same inputs and state directory for visible diagnostics and recovery.

To request [local administrator password alignment](security.md#rotate-local-administrator-passwords):

```bash
read -rsp 'Local administrator password: ' LOCAL_ADMIN_PASSWORD
echo
export LOCAL_ADMIN_PASSWORD ROTATE_LOCAL_ADMIN_PASSWORDS=true
ansible-playbook -i ansible/inventory ansible/deploy.yml
unset LOCAL_ADMIN_PASSWORD ROTATE_LOCAL_ADMIN_PASSWORDS
```

The task passes the secret through stdin with `no_log`; it does not change SSO
identities or application users.

## Verify the result

The installer waits for selected components and reports their endpoints. Check
cluster and GitOps status, then open `https://intranet.<your-domain>`:

```bash
kubectl get nodes
kubectl get applications -n infra
./scripts/validate-repository.sh --live
```

For source changes and Ansible syntax checks:

```bash
ansible-playbook -i ansible/inventory --syntax-check ansible/install.yml
ansible-playbook -i ansible/inventory --syntax-check ansible/deploy.yml
./scripts/validate-repository.sh
```

The live validator uses Kubernetes server-side dry-run without mutation.
`install.yml --check` skips installation; `deploy.yml` rejects check mode because
its tasks depend on command results. Validation does not replace a fresh
installation on disposable hosts. See [validation coverage](operations.md#validation)
and [Argo CD operations](delivery.md#argo-cd-operations) for ongoing maintenance.
