# Add control-plane or worker nodes

`./add-node.sh` is the node enrollment entry point, alongside
`./install-control-plane.sh` for cluster installation and `./replicate-repo.sh`
for repository onboarding. Run it on the original control plane for guided
remote enrollment:

```bash
./add-node.sh
```

The assistant asks two separate questions:

1. **New node role:** control plane or worker.
2. **Execution location:** an existing control plane enrolling remote machines,
   or a new node joining itself.

It then runs the shared enrollment implementation with the selected role.
Choose the same private transport used by the existing cluster: OVHcloud vRack
for eligible OVHcloud servers, or Tailscale for mixed providers/locations.
Both paths use the existing transport account guides, hidden secret prompts,
network validation, and host security scripts.

For unattended full-cluster installation, [Ansible](ansible.md#complete-installation)
uses the same installer and calls this entry point for each planned role.
`ansible/deploy.yml` reconciles an installed platform; it does not enroll nodes.

## How the role changes installation

| Setting | Additional control plane | Worker |
| --- | --- | --- |
| K3s service | `k3s` server with embedded etcd | `k3s-agent` |
| Join credential | Existing server token | Node/agent-compatible join token |
| K3s version | Exact bootstrap server version is required | Remote enrollment defaults to the bootstrap version; supply it for local joins |
| Server configuration | Traefik disabled, secrets encryption enabled, private advertise address | Agent configuration and private node address |
| Scheduling | Remote joins inherit the cluster mode; explicit `true`/`false` supported | Workload node; remote onboarding offers control-plane scheduling reconciliation |
| Private transport | Control-plane Tailscale tag or vRack NIC/address | Worker Tailscale tag or vRack NIC/address |
| API and datastore ports | Private TCP 6443 and 2379–2380 on the trusted node interface/CIDR | No inbound server API or etcd ports |
| Host security | Private UFW policy and persistent Lynis audits | Private UFW policy; no persistent Lynis |
| Public ingress | Disabled; no public ServiceLB advertisement | No public ingress or forwarding |
| Shared prerequisites | AppArmor, Registry mirror, iSCSI/NFS and Longhorn host configuration | Same shared prerequisites |

Both roles restrict SSH to the specified control-plane private source address.
Private SSH is proven before the provider-facing firewall is closed. Neither
added role installs Fail2ban or CrowdSec; those remain on the internet-facing
bootstrap control plane. The managed topology/exposure labels cannot be
overridden through arbitrary labels. Existing nodes with a conflicting role or
identity are rejected instead of converted.

This assistant adds members to the repository's managed K3s configuration.
For clusters with custom critical server flags, first align those settings with
the managed server configuration. K3s requires matching network/component and
secrets-encryption settings across servers; see the
[embedded-etcd guide](https://docs.k3s.io/datastore/ha-embedded).

## Remote enrollment

Run remote mode on the existing bootstrap control plane with a working
`kubectl` context, SSH keys, and root or passwordless sudo access to new hosts.
Target hosts must run supported Debian/Ubuntu and have unique names/addresses.
The assistant can prepare their private networking through bootstrap SSH,
then switches to the private path before installing K3s and hardening UFW.

```bash
# Interactive expansion, for example from one control plane to three:
./add-node.sh --role control-plane --mode remote --count 2

# Add workers interactively:
./add-node.sh --role worker --mode remote --count 2
```

`--count` means additional nodes. A completed cluster has an odd number of
control planes: 1, 3, 5, and so on. A plan that adds only one control plane to a
single-server cluster is rejected. Counts are validated before datastore
conversion or server joins. Each server joins sequentially and must become
Ready; complete the planned batch to restore the intended odd membership.

If the bootstrap server uses SQLite, control-plane enrollment invokes the shared
`scripts/configure-k3s-ha.sh`. It writes an integrity-checked SQLite backup and
server credential/configuration archive under
`/var/backups/bm-cluster/k3s/pre-etcd-<timestamp>`, initializes embedded etcd, and
waits for readiness before enrolling new servers. Conversion restarts the
bootstrap K3s service. Existing embedded-etcd membership is reused; unknown or
external datastores fail with a diagnostic. Worker enrollment does not convert
the datastore.

New control planes inherit the existing scheduling policy by default. Use
`--control-plane-schedulable true|false|preserve` to select it explicitly.
When adding workers from a schedulable cluster, interactive enrollment asks
whether to make control planes controller-only after the workers are Ready;
automation requires an explicit scheduling choice. The final topology
reconciler applies control-plane taints consistently and updates Longhorn using
the Ready-worker count. Control planes are excluded from Longhorn storage when
workers exist; a cluster without workers keeps control planes schedulable.

For automation, supply role, mode, transport, and node addresses. `--ips` and
`--hosts` imply non-interactive enrollment; `--non-interactive`/`--yes` also
disable prompts. `--count` alone retains interactive per-node questions.

```bash
# vRack must already be configured at these addresses:
./add-node.sh --role control-plane --mode remote --transport vrack \
  --ips 10.40.0.12,10.40.0.13 --server-url https://10.40.0.10:6443 \
  --node-network-cidr 10.40.0.0/24 --ssh-user admin \
  --control-plane-schedulable preserve --non-interactive

./add-node.sh --role worker --mode remote --transport vrack \
  --ips 10.40.0.20 --server-url https://10.40.0.10:6443 \
  --node-network-cidr 10.40.0.0/24 --ssh-user admin \
  --control-plane-schedulable preserve --non-interactive
```

For Tailscale, replace `--ips` with `--hosts admin@host-02,admin@host-03` and use
`--transport tailscale`. Supply `TAILSCALE_API_TOKEN` in the environment or use
`--tailscale-api-token-stdin`, together with the existing cluster's tailnet/mesh
settings. The assistant obtains private IPs, issues one-use keys, and tags each
new node according to its selected role. Existing mesh policy retains separate
control-plane and worker grants, including etcd access only between control
planes. The shared K3s node CIDR is `100.64.0.0/10`.

List-based reruns can include already joined control planes. The assistant
checks their identities, counts only new members in the plan, and verifies the
expected final count. Complete a failed batch using the same target list; do not
reset etcd or reinstall an already registered server to retry enrollment.

## Local joins

Local mode joins only the machine running the command. Use a private SSH
session originating from the bootstrap control plane so the mandatory SSH
source check can succeed:

```bash
./add-node.sh --role worker --mode local
./add-node.sh --role control-plane --mode local
```

The control-plane path asks for the exact existing K3s version and its workload
scheduling mode before validating those required settings. It uses the server
token printed by `sudo cat /var/lib/rancher/k3s/server/token` on the existing
control plane. Worker joins accept the node token printed by
`sudo cat /var/lib/rancher/k3s/server/node-token` or a compatible temporary
agent token. Paste tokens into the hidden prompt, or supply them over stdin.
Tokens are never passed as command-line arguments or committed.

For a local control-plane join, the bootstrap cluster must already use embedded
etcd and permit private API/etcd traffic. Local mode cannot validate the final
cluster membership or prepare a different host's datastore. Use remote mode for
the complete workflow, or finish the planned local joins and run topology
reconciliation on the existing control plane:

```bash
kubectl wait --for=condition=Ready node --all --timeout=5m
./scripts/reconcile-cluster-topology.sh \
  --control-plane-schedulable preserve --update-longhorn-helm
```

Additional control planes stay private and do not install shared platform
services. Public DNS and ingress remain on the original host; adding servers
does not configure public ingress failover.

## CLI options and implementation

Run `./add-node.sh --help` for the general flow. Append `--help` after both role
and mode for the selected implementation's full option list. Generic remote
`--count`, `--ips`, and `--hosts` map to the selected role's options. Existing
`--worker-*` and `--control-plane-*` list/count flags are accepted only with their
matching remote role. Conflicting roles, invalid modes, or missing selectors
with secret stdin fail before invoking any enrollment implementation.

The internal `scripts/add-k3s-workers.sh` and `scripts/install-k3s-worker.sh`
filenames are retained, but both implementations accept a node role. The small
`add-k3s-control-planes.sh` and `install-k3s-server.sh` adapters select server
behavior. The main installer now calls `add-node.sh` for both roles and defers
control-plane topology reconciliation until its planned workers also join.

## Validation

```bash
./scripts/test-add-node.sh
./scripts/test-ha-enrollment.sh
./scripts/test-ha-network.sh
./scripts/validate-repository.sh
```

Tests exercise all four public role/mode combinations, interactive prompts,
automation, argument preservation, and secret stdin handling.
Host/cluster commands are mocked when checking actual server/agent installation,
datastore preparation, role collisions, private exposure, and scheduling.
Network tests cover vRack firewall isolation, private SSH guards, and separate
Tailscale grants for API and etcd traffic. No live hosts are changed by these
tests.
