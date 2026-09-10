# Ansible installation and reconciliation

Both playbooks run locally from this checkout on a control-plane host, as a
non-root user with passwordless sudo. Bootstrap and default-mode reconciliation
use the first control plane; an HA platform can be reconciled from a surviving
control plane. The supplied inventory uses `localhost`; node enrollment reaches
other hosts over SSH. Adding inventory hosts does not distribute installation.

| Playbook | Starting state | Purpose |
| --- | --- | --- |
| `ansible/install.yml` | Ubuntu host with Git, Python, Ansible and passwordless sudo | Full unattended installation through `install-control-plane.sh --yes` |
| `ansible/deploy.yml` | Installed eligible K3s control plane, matching kubeconfig, kubectl, Helm, jq, OpenSSL, Git, Python and Ansible | Reconcile shared platform services and optional host/network integrations |

Both paths use the shared [platform configuration](../config/platform.env),
manifest inventories and provisioning helpers. Node roles, private networking,
security, dependencies and readiness checks follow the same installation
contract. [Installation](installation.md) documents the shared choices and inputs.

## Complete installation

Install Ansible on the first host:

```bash
sudo apt-get update
sudo apt-get install -y ansible git python3
```

Export the [unattended installer inputs](installation.md#unattended-installation),
including topology and secrets, then invoke:

```bash
ansible-playbook -i ansible/inventory ansible/install.yml
```

Complete [transport and Cloudflare prerequisites](networking.md) before an
unattended run. All installer options also apply here, including offsite backups
and [repository onboarding](repository-replication.md).

An optional `installer_environment` mapping overrides selected environment
inputs for the installation task. For example, an encrypted extra-vars file can
supply cluster identity while the remaining inputs come from the process:

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

Store credentials in Ansible Vault or the process environment; never commit
plaintext values. The installation task uses `no_log` because its nested commands
handle secrets. Failures stop the play. For interactive diagnostics, run the
shared installer with the same inputs.

Reruns preserve an installed K3s server by default; this is not a K3s upgrade
mechanism. Use [add-node.sh](node-enrollment.md) for later node enrollment.

## Platform reconciliation

Preflight verifies the local K3s service, control-plane role and kubeconfig
before host changes. Workers are rejected; additional private control planes
are accepted when HA is requested or already recorded in the cluster. Set
`CONTROL_PLANE_NODE_NAME` to the local registered node name if it differs from
the hostname.

```bash
export PLATFORM_DOMAIN=example.com
export CONTROL_PLANE_NODE_NAME=control-plane-01
export GITOPS_REPOSITORY_URL=https://github.com/example/bm-cluster.git
export KEYCLOAK_SSO_BOOTSTRAP_USERNAME=platform-admin
read -rsp 'Platform administrator password: ' KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
echo
export KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
ansible-playbook -i ansible/inventory ansible/deploy.yml
unset KEYCLOAK_SSO_BOOTSTRAP_PASSWORD
```

Use `-e server_exposure=local` for a locally exposed bootstrap host; the default
is internet exposure. Set `CLOUDFLARE_ACCESS_TEAM_NAME` when using an existing
Zero Trust team. The internal DNS zone and public node label use the same
defaults as the installer.

[Control-plane SSH access](node-enrollment.md#remote-enrollment) is reconciled
from registered control-plane private addresses on multi-node installations.
The playbook preserves control-plane scheduling by default and retains private
exposure on joined servers. Set `CONTROL_PLANE_SCHEDULABLE=true|false` only to
change the policy deliberately. Longhorn uses the shared
[storage placement rule](node-enrollment.md#scheduling-and-storage).

For HA, complete the explicit PostgreSQL, Kafka and Vault workflows in
[high availability](high-availability.md#activate-in-order) before reconciling
with `HIGH_AVAILABILITY_ENABLED=true` and `PLATFORM_HA_VALUES_FILE`. The playbook
uses the same verified profile as the shell installer, preserves recorded HA
on later runs, and refuses unfinished migrations or implicit downgrades.
Include `-e configure_cloudflare=true` for the public Tunnel/DNS cutover.

Feature switches select reconciliation tasks:

| Switch | Default |
| --- | --- |
| `install_longhorn`, `install_ingress`, `install_vault_stack` | `true` |
| `deploy_data_stores`, `deploy_platform_services` | `true` |
| `install_apps`, `install_odoo` | `true` |
| `install_descheduler`, `install_argocd`, `manage_host_security` | `true` |
| `configure_cloudflare`, `manage_private_transport` | `false` |

For example, `-e install_apps=false` omits Odoo. Dependencies are enabled as
needed: Odoo requires platform services, platform services require data stores,
data stores require Vault/External Secrets, and Cloudflare requires ingress.
Disabling a switch does not uninstall an existing component; Argo CD continues
reconciling its configured scope. App-owned deployments stay in their repositories.
The shared `apps` namespace, baseline networking, credentials and TLS foundation
remain available when `install_apps=false`; this switch controls Odoo/`corp`.

### Optional host and account changes

Private transport reconciliation is opt-in and runs before K3s network binding
and UFW. Export the [transport inputs](networking.md#private-node-network), then
choose the existing transport:

```bash
# Already attached and addressed vRack:
ansible-playbook -i ansible/inventory ansible/deploy.yml \
  -e manage_private_transport=true -e k3s_node_transport=vrack

# Tailscale, with its API token supplied in the environment:
ansible-playbook -i ansible/inventory ansible/deploy.yml \
  -e manage_private_transport=true -e k3s_node_transport=tailscale
```

For API-managed vRack attachment, also set `-e ovh_vrack_automate_account=true`
with the OVH account inputs. Without transport reconciliation, provide
`K3S_NODE_NETWORK_CIDR` when host security must trust node traffic.

Cloudflare reconciliation requires its documented environment inputs and
`-e configure_cloudflare=true`. Offsite recovery and repository imports use the
[optional installer inputs](installation.md#optional-integrations).
Unattended repository onboarding requires `DEPLOY_REPOSITORIES=all`, `none`, or
selected comma-separated names; the playbook invokes `add-repos.sh --yes` after
Argo CD. Export `REPOSITORY_INPUTS_FILE` for per-repository JSON choices,
`REPOSITORY_STATE_DIR` for private resumable journals, and `ONBOARDING_TIMEOUT`
when the default delivery wait is insufficient. These are the same inputs used
by the shell entrypoint. The task uses `no_log` and waits for required app jobs
and deployment readiness; a failed setup stops the play. Run `add-repos.sh` with
the same inputs/state directory for visible diagnostics and recovery.

Local infrastructure password alignment is also explicit:

```bash
read -rsp 'Local administrator password: ' LOCAL_ADMIN_PASSWORD
echo
export LOCAL_ADMIN_PASSWORD ROTATE_LOCAL_ADMIN_PASSWORDS=true
ansible-playbook -i ansible/inventory ansible/deploy.yml
unset LOCAL_ADMIN_PASSWORD ROTATE_LOCAL_ADMIN_PASSWORDS
```

The rotation helper receives the secret through stdin and the task uses
`no_log`. It does not change SSO identities or application users. See
[credentials and security](security.md) for the identity boundaries.

## Validation

```bash
ansible-playbook -i ansible/inventory --syntax-check ansible/install.yml
ansible-playbook -i ansible/inventory --syntax-check ansible/deploy.yml
python3 scripts/test-ansible.py
./scripts/validate-repository.sh --live
```

Behavioral tests run the playbooks with isolated host and cluster substitutes.
The live validator uses Kubernetes server-side dry-run without mutation.
`install.yml --check` skips installation; `deploy.yml` rejects check mode because
later tasks depend on command results. These checks do not replace a fresh
installation on disposable hosts. See Ansible's
[command module check-mode support](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/command_module.html#attributes).
