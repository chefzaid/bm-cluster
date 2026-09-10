# Add control-plane or worker nodes

Run the node assistant from a registered control plane:

```bash
./add-node.sh
```

Choose the new node's **role** (control plane or worker), then the **execution
location** (remote enrollment from the existing control plane or a local join
on the new host). Remote enrollment manages readiness, quorum planning,
scheduling and storage placement together.

Use the existing cluster's [private transport](networking.md#private-node-network).
New hosts need Debian/Ubuntu, unique names and addresses, SSH keys, and root or
passwordless sudo access. Enrollment proves private SSH before applying the
[host exposure policy](networking.md#exposure-boundaries).

## Role-specific installation

| Setting | Additional control plane | Worker |
| --- | --- | --- |
| K3s service | `k3s` server with embedded etcd | `k3s-agent` |
| Join credential | Existing server token | Node/agent-compatible token |
| K3s version | Exact bootstrap server version required | Remote joins inherit it; supply it for local joins |
| Scheduling | Inherit or explicitly select the cluster policy | Workload node |
| Private inbound ports | API TCP 6443 and etcd TCP 2379–2380, plus node peers | Node peers; no inbound API or etcd |
| Persistent host controls | UFW and Lynis | UFW |

Both roles configure AppArmor, the Registry mirror, iSCSI/NFS and Longhorn host
prerequisites. Added nodes have no public ingress advertisement and do not
install shared platform services, Fail2ban or CrowdSec. Conflicting existing
roles or node identities are rejected instead of converted.

When the [HA profile](high-availability.md) is already active, its DaemonSet
automatically adds an ingress/Tunnel pair on each new control plane. Enrollment
inherits the stored storage policy and distributes Vault recovery material to
verified control planes. Update any enabled [fencing inventory](node-fencing.md)
for the new membership before relying on automatic host recovery.

The assistant manages a consistent K3s server configuration. If a cluster has
custom critical flags, align them before adding servers: K3s requires matching
network, component and secrets-encryption settings across control planes. See
[embedded-etcd requirements](https://docs.k3s.io/datastore/ha-embedded).

## Remote enrollment

Run these commands on a registered control plane with its local K3s kubeconfig:

```bash
# Expand one control plane to three:
./add-node.sh --role control-plane --mode remote --count 2

# Add two workers:
./add-node.sh --role worker --mode remote --count 2
```

`--count` means additional nodes and retains interactive per-node prompts.
The final control-plane count must be odd. The plan is checked before any
datastore conversion; each new server joins sequentially and must become Ready.

When adding control planes to a SQLite cluster, the assistant saves an
integrity-checked database backup and server credentials/configuration under
`/var/backups/bm-cluster/k3s/pre-etcd-<timestamp>`, restricted to root. It then
restarts the bootstrap K3s server with embedded etcd and waits for readiness.
Existing embedded-etcd membership is reused; external or unknown datastores
are rejected. Adding workers does not convert the datastore.

For unattended enrollment, supply the role, mode, transport and targets:

```bash
# These vRack addresses must already be configured:
./add-node.sh --role control-plane --mode remote --transport vrack \
  --ips 10.40.0.12,10.40.0.13 --server-url https://10.40.0.10:6443 \
  --node-network-cidr 10.40.0.0/24 --ssh-user admin \
  --control-plane-schedulable preserve --non-interactive

./add-node.sh --role worker --mode remote --transport vrack \
  --ips 10.40.0.20 --server-url https://10.40.0.10:6443 \
  --node-network-cidr 10.40.0.0/24 --ssh-user admin \
  --control-plane-schedulable preserve --non-interactive
```

For Tailscale, use `--transport tailscale` and replace `--ips` with
`--hosts admin@host-02,admin@host-03`. Supply the existing cluster's
[Tailscale inputs](networking.md#tailscale); the assistant discovers private
addresses and assigns tags by role. `--ips` and `--hosts` imply unattended mode;
`--non-interactive` and `--yes` also disable prompts.

List-based retries may include already joined control planes. Identities are
verified and only new members count toward the plan. Complete a failed batch
with the same target list; do not reset etcd or reinstall registered servers.

## Control-plane administration

After enrollment, private nodes allow SSH from the registered control planes'
private InternalIPs. Worker addresses are excluded. The current SSH source is
verified before changing rules, and later runs preserve the managed allowlist.
New nodes record their SSH account so future reconciliation can reuse it.
To refresh existing private nodes after control-plane membership changes:

```bash
./scripts/reconcile-control-plane-access.sh \
  --node-network-cidr 10.40.0.0/24 --control-plane-ip 10.40.0.12 \
  --ssh-user admin
```

Run this from a surviving control plane using its own private source address.
`--ssh-port` and `--identity-file` select the SSH connection settings. The helper
changes only its managed SSH rules, preserves unrelated firewall rules, and
fails if a private node cannot be reached. It does not restart K3s.

`--server-url` may point to another registered control plane's private IP;
`--control-plane-ip` identifies the enrollment host's actual SSH source. Both
are checked against control-plane membership. Existing K3s agents learn all API
server addresses through their built-in client load balancer. External kubectl
clients still select a reachable server; no floating API endpoint is installed.

## Scheduling and storage

New control planes inherit the cluster scheduling policy. Select it explicitly
with `--control-plane-schedulable true|false|preserve`. When adding workers to a
schedulable cluster, interactive enrollment offers controller-only mode after
workers are Ready; unattended enrollment requires an explicit choice. Clusters
without workers must keep control planes schedulable.

The final topology reconciliation updates control-plane taints and Longhorn's
setting, Helm values, default StorageClass and existing volumes. Set
`HIGH_AVAILABILITY_ENABLED=true` when enabling an HA cluster. Later reconciliation
inherits an omitted value from `infra/bm-cluster-topology`; a cluster without a
stored mode defaults to `false`. An explicit `false` cannot turn off stored HA
unless accompanied by `--allow-ha-disable`. That override is for a separately
planned migration: it does not migrate applications or shrink volume replicas.

| Storage topology | Longhorn default replicas |
| --- | ---: |
| HA: at least three control planes and three storage-eligible nodes | 3 |
| Non-HA: no workers, regardless of control-plane count | 1 |
| Non-HA: one or more registered workers | Registered worker count |

In HA mode, schedulable control planes participate in storage alongside workers.
Controller-only control planes are excluded, so that mode needs at least three
registered workers. Invalid HA topology fails before taints, labels, Helm values
or Longhorn resources are changed. The eligibility check uses registered node
roles and the selected scheduling policy; it does not establish that disks have
enough free space or that replica rebuilding has completed.

In non-HA mode, workers exclude all control planes from storage scheduling.
Existing control-plane replicas are evicted toward worker storage while a
worker is Ready. Extra control planes alone do not add volume replicas in this
mode.

Temporary NotReady nodes do not lower the default replica count. Existing volumes
are only increased to the target: larger counts are preserved even after node
removal or a mode change, and PVC capacities remain unchanged. Reducing existing
replication requires a separate, deliberate storage operation. Longhorn must have
sufficient independent disks and free space to build the requested replicas;
verify actual healthy replicas before testing node failure. Storage replication
supports volume recovery, not concurrent database writers or automatic safe
fencing of a failed host.

HA also disables Longhorn's replica soft anti-affinity in the setting/Helm
defaults and removes existing volume overrides that permit copies on the same
host. This requests distinct-host placement; it does not prove that old copies
have finished rebuilding. Check each volume's actual healthy replicas and
their node IDs before declaring storage redundant.

For a three-control-plane cluster whose control planes run workloads:

```bash
HIGH_AVAILABILITY_ENABLED=true ./scripts/reconcile-cluster-topology.sh \
  --control-plane-schedulable true --update-longhorn-helm
```

## Local joins

Local mode joins only the machine running the command. Connect to it over
private SSH from the bootstrap control plane so the SSH source check succeeds:

```bash
./add-node.sh --role worker --mode local
./add-node.sh --role control-plane --mode local
```

On the existing control plane, obtain the appropriate credential:

```bash
# Additional control plane:
sudo cat /var/lib/rancher/k3s/server/token

# Worker:
sudo cat /var/lib/rancher/k3s/server/node-token
```

Paste the token into the hidden prompt or use `--token-stdin`; do not pass it
as a command-line argument. Control-plane joins also require the exact K3s
version and scheduling policy. The existing cluster must already use embedded
etcd and permit private API/etcd traffic.

Local mode cannot prepare another host's datastore or validate final membership.
Finish the planned batch, then reconcile from the original control plane:

```bash
kubectl wait --for=condition=Ready node --all --timeout=5m
./scripts/reconcile-cluster-topology.sh \
  --control-plane-schedulable preserve --update-longhorn-helm
```

Run `./add-node.sh --help`, or append `--help` after both role and mode for the
complete options. For initial multi-node planning see [installation](installation.md);
[Ansible installation](ansible.md#complete-installation) uses the same enrollment
workflow. `ansible/deploy.yml` reconciles the installed platform and does not
add nodes.
