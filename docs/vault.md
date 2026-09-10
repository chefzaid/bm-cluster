# Vault operations

Vault stores platform credentials in integrated Raft storage. Installer and
Ansible render [the shared Helm values](../config/vault-values.yaml), including
the selected [image profile](security-images.md). Changes to those values need
a Helm reconciliation to update an existing release. External Secrets reads
Vault through Kubernetes authentication; its store and secret mappings are in
[vault.yaml](../k8s/platform/vault.yaml).

## Storage and audit

The server has a read-only root filesystem and a bounded memory-backed `/tmp`
for the chart's generated startup configuration. Its writable home, Raft data
and audit logs have separate mounts. Preserve the deployed file-owner identity
when updating the image: changing only its UID/GID can prevent Vault from
opening existing Raft and audit files.

Keep both audit devices enabled. Stdout reaches Fluent Bit; the file device
writes to the dedicated node-local `vault-audit` PVC, avoiding a Longhorn
dependency during startup. The unprivileged rotator shares Vault's process
namespace to rename the active file and send `SIGHUP`, then compresses closed
files. It receives no Vault token. Limits and retained archive counts live in
[the Helm values](../config/vault-values.yaml). Monitor audit-write failures and
volume pressure separately from ordinary application-log retention.

## Three-peer availability

The default remains one Vault server. Opting into `HIGH_AVAILABILITY_ENABLED=true`
uses [the HA overlay](../config/vault-ha-values.yaml): three Raft voters on three
different control planes, a disruption budget permitting one unavailable peer,
and a separate 5 GiB node-local audit claim for each pod. Data remains on Longhorn.
Three Ready, uncordoned control planes and working storage are prerequisites.
The profile tolerates the managed control-plane taint, so controller-only
control planes are supported. Adding replicas to one host does not provide
host-failure protection.

The chart uses `OnDelete`, so a Helm reconciliation does not restart existing
peers automatically. Roll out image/configuration changes one peer at a time,
checking quorum before and after each replacement:

```sh
./scripts/configure-vault-ha.sh --verify
```

This checks three Ready peers on different nodes, three voters and healthy Raft
Autopilot state. Two surviving peers can continue serving during one host outage.
Each node-local audit claim stays attached to its original host: permanent host
replacement requires an explicit audit-volume recovery plan, alongside recovery
of that member's data. Keep both audit devices and off-host log collection enabled.

### Migrating an existing singleton

Use [the shared configurator](../scripts/configure-vault-ha.sh), rather than
applying the overlay directly: Kubernetes cannot add a StatefulSet claim template
in place. Schedule one maintenance operation from one control plane, verify a
restoration backup, and select the existing compatible image profile first. Set
`VAULT_VALUES_FILE` to that profile's rendered `config/vault-values.yaml`.

```sh
VAULT_HA_MIGRATE_EXISTING=true ./scripts/configure-vault-ha.sh \
  --namespace infra --values "$VAULT_VALUES_FILE"
HIGH_AVAILABILITY_ENABLED=true ./scripts/configure-vault.sh infra
```

The explicit flag is also required when the installer or Ansible encounters the
singleton layout. The helper saves a fresh Raft snapshot, checks its checksum,
and archives the current Helm values and StatefulSet under the root-only
`/var/lib/bm-cluster/backups/` directory. It then orphans the existing controller,
retaining the running `vault-0`, and recreates the controller with per-pod audit
claims. It replaces `vault-0` only after both new peers are unsealed and all three
are healthy voters. Deletions check object identity; no PVC is deleted.

The original `data-vault-0` remains in use. The original `vault-audit` is retained
as an audit archive after `audit-vault-0` takes over. If joining fails, leave the
original pod and retained PVCs in place, diagnose the failed peers, then rerun
the gated helper. If controller creation itself failed, restore the archived
controller before retrying. Do not scale a live three-voter cluster back to one
by changing only the Helm replica count.

## Upgrade and recovery

Test the candidate against the deployed image with disposable Docker data:

```sh
python3 scripts/test-vault-image.py "$CANDIDATE_IMAGE" \
  --previous-image "$CURRENT_IMAGE" --logs "$PRIVATE_LOG_DIRECTORY"
```

The fixture checks existing-volume upgrade, stored secrets, access controls,
authentication, transit decryption, UI assets, audit rotation and restart. It
also restores a snapshot into a separate volume using the previous image.

Before a production Helm update, save a fresh Raft snapshot and verify its
archive checksums. Test restoration into an isolated, network-disabled instance
with the original unseal key and bootstrap token; compare secret hashes,
policies, authentication methods and audit devices against a private inventory.
Keep snapshots, keys, tokens, inventories and fixture logs outside Git. A
successful snapshot command alone does not establish recoverability.

After rollout, verify readiness, unsealed status, stored data, mounts and auth
methods, both audit devices, and every ExternalSecret's Ready condition. Check
the host unseal service and fresh reports for the running image digest. Retain
the verified backup and previous image for recovery; do not start an older
binary directly against upgraded Raft data.

## Host unseal service

The root-owned `bm-vault-unseal.service` is scheduled by
[bm-vault-unseal.timer](../config/systemd/bm-vault-unseal.timer). Its
[helper](../scripts/vault-unseal.sh) discovers running Vault server pods, checks
seal status and reads
`/var/lib/bm-cluster/vault-unseal-key` only when unsealing is needed. Keep that
file root-owned with mode `0600`, outside Git and diagnostic output.

An initialized peer is unsealed with the existing key. An empty replacement
joins an unsealed surviving member before receiving that key; the timer never
initializes a cluster. Configuration also refuses initialization when host
recovery material exists but no initialized peer is reachable. Existing runtime
maintenance commands and backups select an unsealed peer, preferring the leader.

In HA mode, distribute the same recovery files and install the timer on every
verified control plane after initial Vault configuration and future enrollment:

```sh
./scripts/sync-vault-recovery.sh --all-control-planes \
  --node-network-cidr "$K3S_NODE_NETWORK_CIDR" \
  --control-plane-ip "$K3S_PRIVATE_ADDRESS" --ssh-user "$K3S_NODE_SSH_USER"
```

This requires private SSH access and passwordless sudo using
[the control-plane administration policy](node-enrollment.md#control-plane-administration).
The helper verifies Kubernetes control-plane roles, private addresses and the
actual SSH endpoints. Only those hosts receive the unseal key and bootstrap
token, as root-owned `0600` files in a `0700` directory. Values travel through
encrypted SSH stdin; differing existing recovery material is never overwritten.
Workers receive neither file. Control-plane root access therefore includes Vault
recovery authority. The original single-host timer remains the default until
this explicit distribution is requested.

The anonymous `sys/unseal` request carries the key as JSON over
`kubectl exec -i` stdin, keeping it out of process arguments and Kubernetes exec
metadata. Preserve this handling when changing the helper or initial installer
configuration. [The regression test](../scripts/test-vault-unseal.py) verifies
stdin handling and error propagation; a real recovery fixture verifies actual
unsealing. [HA tests](../scripts/test-vault-ha.py) cover survivor selection,
join/unseal ordering, quorum gates and recovery-file target validation.

Check scheduling and the last result without displaying credentials:

```sh
sudo systemctl show bm-vault-unseal.timer \
  -p ActiveState -p SubState -p UnitFileState -p LastTriggerUSec
sudo systemctl show bm-vault-unseal.service \
  -p Result -p ExecMainStatus -p ExecMainExitTimestamp
```

A check on an already unsealed server verifies the status path. Exercise actual
unsealing in an isolated recovery test, without sealing the live cluster.
See [security and access](security.md#recovery-credentials) for credential lookup.
