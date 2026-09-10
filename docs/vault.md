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
[helper](../scripts/vault-unseal.sh) checks seal status and reads
`/var/lib/bm-cluster/vault-unseal-key` only when unsealing is needed. Keep that
file root-owned with mode `0600`, outside Git and diagnostic output.

The anonymous `sys/unseal` request carries the key as JSON over
`kubectl exec -i` stdin, keeping it out of process arguments and Kubernetes exec
metadata. Preserve this handling when changing the helper or initial installer
configuration. [The regression test](../scripts/test-vault-unseal.py) verifies
stdin handling and error propagation; a real recovery fixture verifies actual
unsealing.

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
