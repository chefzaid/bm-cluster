# Ansible Installation And Reconciliation

Run these playbooks from the repository checkout on the first control-plane
host, as the same non-root sudo user used by the guided installer. The supplied
inventory uses a local connection. Adding inventory hosts does not distribute
platform installation: the shared enrollment workflow joins other hosts over
SSH and assigns their control-plane or worker role.

| Entry point | Starting state | Scope |
|---|---|---|
| `ansible/install.yml` | Supported Ubuntu/Debian host with Git, Python, Ansible and passwordless sudo | Complete installation: host prerequisites, K3s, planned control planes/workers, private networking, host security, storage, platform services, recovery and optional repository replication |
| `ansible/deploy.yml` | Installed bootstrap control plane with a working local K3s service, matching kubeconfig, kubectl, Helm, jq, OpenSSL, Git, Python and passwordless sudo | Reconcile shared platform services and optionally their host transport/security and repository replication |

## Complete Installation

`install.yml` invokes `install-control-plane.sh --yes` using Ansible's command
module. It deliberately shares the installer implementation: K3s version pins,
SQLite-to-etcd preparation, odd control-plane counts, sequential server/worker
joins, readiness checks, role-specific networking/UFW, AppArmor, Registry
configuration, Lynis and backups follow the same path. It also deploys the same
platform bundle and calls `replicate-repo.sh` after Argo CD when requested.

Install Ansible before starting, then supply the installer's environment inputs:

```bash
sudo apt-get update
sudo apt-get install -y ansible git python3
export PLATFORM_DOMAIN=example.com
export CONTROL_PLANE_NODE_NAME=control-plane-01
export SERVER_EXPOSURE=local
export INSTALL_SCOPE=apps
export CONTROL_PLANE_COUNT=1
export CLUSTER_NODE_COUNT=1
export CONTROL_PLANE_SCHEDULABLE=true
export GITOPS_REPOSITORY_URL=https://github.com/example/bm-cluster.git
export KEYCLOAK_SSO_BOOTSTRAP_USERNAME=platform-admin
read -rsp 'Platform administrator password: ' KEYCLOAK_SSO_BOOTSTRAP_PASSWORD; echo
export KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
ansible-playbook -i ansible/inventory ansible/install.yml
unset KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
```

The password must meet the shared administrator policy. `INSTALL_SCOPE=infra`
omits the centrally owned Odoo application; the default `apps` includes it.
The unattended installer selects the recommended platform bundle. Use the
feature switches below with `deploy.yml` for selective reconciliation.

For internet exposure, set `SERVER_EXPOSURE=internet`. Cloudflare is enabled by
default for this unattended install and requires `CLOUDFLARE_API_TOKEN`; supply
`CLOUDFLARE_ACCESS_ALLOWED_EMAILS` and `CLOUDFLARE_ACCESS_TEAM_NAME` for Access.
Complete registrar nameserver/DNSSEC prerequisites first. Alternatively set
`CONFIGURE_CLOUDFLARE=false` to create local TLS certificates and configure
public DNS/TLS separately. Existing TLS secrets are preserved.

For multiple nodes, set `CONTROL_PLANE_COUNT` to the final odd server count and
`CLUSTER_NODE_COUNT` to the final total, including the first host. Supply
`K3S_CONTROL_PLANE_IPS` / `K3S_WORKER_IPS` for prepared vRack addresses, or
`K3S_CONTROL_PLANE_HOSTS` / `K3S_WORKER_HOSTS` for Tailscale bootstrap SSH targets.
Use the transport, SSH, scheduling and account inputs described in
[node enrollment](node-enrollment.md). The installer calls `add-node.sh` with
the appropriate role; joined control planes and workers remain private.

For example, three control planes and one worker on a prepared vRack:

```bash
export CONTROL_PLANE_COUNT=3 CLUSTER_NODE_COUNT=4
export CONTROL_PLANE_SCHEDULABLE=false
export K3S_NODE_TRANSPORT=vrack
export K3S_PRIVATE_ADDRESS=10.40.0.10
export K3S_PRIVATE_INTERFACE=eno2
export K3S_NODE_NETWORK_CIDR=10.40.0.0/24
export K3S_CONTROL_PLANE_IPS=10.40.0.11,10.40.0.12
export K3S_WORKER_IPS=10.40.0.20
export K3S_CONTROL_PLANE_SSH_USER=admin K3S_WORKER_SSH_USER=admin
ansible-playbook -i ansible/inventory ansible/install.yml
```

An optional `installer_environment` mapping in an extra-vars file overrides
individual environment inputs for the installation task. It uses the same
uppercase names shown above. Store secret values in an Ansible Vault encrypted
file or export them only for the process; never commit plaintext credentials:

```yaml
installer_environment:
  PLATFORM_DOMAIN: example.com
  CONTROL_PLANE_NODE_NAME: control-plane-01
  SERVER_EXPOSURE: local
```

```bash
ansible-playbook -i ansible/inventory ansible/install.yml \
  -e @/secure/cluster-install.yml --ask-vault-pass
```

The installation task uses `no_log` because nested bootstrap commands handle
secrets. Failures still stop the play. For detailed interactive diagnostics, run
the shared installer directly with the same inputs. Reruns preserve an existing
K3s installation by default and reconcile the requested topology and platform;
they are not a K3s upgrade mechanism. Use `add-node.sh` for later role-aware
node enrollment without reinstalling platform services.

## Platform Reconciliation

The preflight verifies the local K3s service and selected bootstrap node before
changing networking or security. `CONTROL_PLANE_NODE_NAME` defaults to the local
hostname; set it explicitly when K3s uses a different name. A worker or additional
private control plane is rejected. Only the bootstrap node is labeled for
ServiceLB; private joined servers retain their exposure and scheduling policy.
The kubeconfig must belong to this local cluster.

Run Ansible from the control-plane repository checkout with its local inventory:

```bash
export PLATFORM_DOMAIN='example.com'
export INTERNAL_DNS_ZONE='internal.example.com'
export CONTROL_PLANE_NODE_NAME='control-plane-01'
export CLOUDFLARE_NODE_DNS_LABEL='node-01'
export CONTROL_PLANE_SCHEDULABLE='preserve'
export GITOPS_REPOSITORY_URL='https://github.com/example/bm-cluster.git'
export CLOUDFLARE_ACCESS_TEAM_NAME='example-team'
export KEYCLOAK_SSO_BOOTSTRAP_USERNAME='platform-admin'
read -rsp 'Platform administrator password: ' KEYCLOAK_SSO_BOOTSTRAP_PASSWORD; echo
export KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
ansible-playbook -i ansible/inventory ansible/deploy.yml
# Alternative invocations:
# ansible-playbook -i ansible/inventory ansible/deploy.yml -e server_exposure=local
# ansible-playbook -i ansible/inventory ansible/deploy.yml -e install_apps=false
unset KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
```

Platform reconciliation uses the same release versions, ordered manifest inventories,
dependencies, and readiness checks as the interactive installer. It reconciles
all feature groups by default except Cloudflare. Feature switches are
`install_longhorn`, `install_ingress`, `install_vault_stack`,
`deploy_data_stores`, `deploy_platform_services`, `install_apps`, `install_odoo`,
`install_descheduler`, and `install_argocd`. Dependencies are enabled
automatically: `install_apps=false` disables Odoo; Odoo requires platform services
for Keycloak SSO; platform services require data stores, data stores require Vault and External Secrets, and
Cloudflare requires ingress.
Ansible preserves the installer-selected scheduling mode across all control planes by default and
uses the same Ready-worker Longhorn replica rule. Set
`CONTROL_PLANE_SCHEDULABLE=true|false` only when intentionally changing it.
Additional control planes retain their private exposure and disabled public
ServiceLB labels during reconciliation.

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

## Repository Replication And Deployment

Both playbooks support the current standalone replication contract:

```bash
export CONFIGURE_REPOSITORY_SYNC=true
export GITHUB_USERNAME=example
export GITHUB_REPOSITORIES=app-one,app-two
export DEPLOY_REPOSITORIES=all # or none, or selected comma-separated names
read -rsp 'GitHub personal access token: ' GITHUB_ADMIN_TOKEN; echo
export GITHUB_ADMIN_TOKEN
ansible-playbook -i ansible/inventory ansible/deploy.yml
unset GITHUB_ADMIN_TOKEN
```

The GitLab platform configurator first reconciles the group, runner, registries
and Vault credentials. After Argo CD is available, a separate task invokes
`replicate-repo.sh --yes` to wait for imports, configure bidirectional sync,
validate application deployment files and deploy the selected repositories.
`DEPLOY_REPOSITORIES` is mandatory for unattended replication. The old singular
`GITHUB_REPOSITORY` input does not select repositories in this workflow.
See [repository replication](repository-replication.md) for token permissions,
configuration requirements and partial-failure handling.

## Shared Behavior And Validation

Ordered manifests, chart versions and readiness inventories come from
`config/platform.env`. Empty optional inventories are skipped. `deploy.yml`
uses the same TLS helper as the installer when Cloudflare is disabled. Odoo
runs in `corp` and enables its Keycloak, data-store and Vault dependencies;
application-owned deployments remain in their own repositories. Sonar source
discovery is enabled when both applications and platform services are selected.
The guide's feature switches select reconciliation tasks; disabling a switch
does not uninstall an existing component. Argo CD continues reconciling its
configured platform chart and selected apps/Descheduler scope.

```bash
ansible-playbook -i ansible/inventory --syntax-check ansible/install.yml
ansible-playbook -i ansible/inventory --syntax-check ansible/deploy.yml
python3 scripts/test-ansible.py
./scripts/validate-repository.sh
./scripts/validate-repository.sh --live
```

The Ansible behavioral tests execute both real playbooks with isolated host,
Helm, Kubernetes and provisioning substitutes. They cover default and reduced
scope, dependency activation, both private transports, Cloudflare Access,
replication order, bootstrap input forwarding, secret masking and failure
propagation. The TLS helper generates real certificates in the fixtures and is
checked for domain coverage, reuse, private-key permissions and cleanup.

`--syntax-check` checks playbook syntax. `install.yml --check` skips installation;
it does not validate a future cluster. `deploy.yml` rejects check mode because
later tasks depend on command results. Use `validate-repository.sh --live` for
Kubernetes server-side dry-run against the active cluster without mutation.
These checks do not substitute for a fresh installation on disposable hosts.

The command-based integration follows the
[Ansible command module](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/command_module.html)
contract, including its limited check-mode support.
