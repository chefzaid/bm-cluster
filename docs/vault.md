# Vault operations

Vault runs with integrated Raft storage. The installer and `ansible/deploy.yml`
both render `config/vault-values.yaml` through the shared configuration renderer
and pass it to the pinned Vault Helm chart. The image renderer selects the
public bootstrap image or the tested private image. Updating these values in
Git requires a Helm reconciliation to change an existing Vault release.

## Writable paths and identity

The server has a read-only root filesystem. The Helm startup command copies its
configuration into `/tmp/storageconfig.hcl` and replaces runtime placeholders
before starting Vault. A dedicated memory-backed `emptyDir` mounts at `/tmp`,
with a 32 MiB size limit. Its contents are disposable and count toward memory
usage. The chart also provides a separate writable home directory; Raft data
and audit logs retain their own persistent volumes.

Vault retains UID 100 and GID 1000 so it can open existing Raft and audit files.
The audit rotator keeps the same identity and shared process namespace to
signal Vault after rotating the audit file. A UID migration requires a separate
tested ownership procedure; changing only the security context can prevent
Vault from reopening existing storage.

After a Helm update, verify that Vault is ready and unsealed, its expected
mounts and authentication methods remain available, and External Secrets can
still read their configured paths. Confirm the server security context has
`readOnlyRootFilesystem: true` and `/tmp` uses the bounded `vault-tmp` volume.
Use the fresh report for the running StatefulSet when assessing configuration
findings.

## Host unseal service

`bm-vault-unseal.timer` runs the root-owned `bm-vault-unseal.service` every
minute, starting shortly after boot. The helper checks the Vault pod and reads
the unseal key from `/var/lib/bm-cluster/vault-unseal-key` only when needed.
Keep the key file root-owned with mode `0600`; never include it in Git or
diagnostic output.

Both the host helper and initial installer configuration send an anonymous
`sys/unseal` API request as JSON through `kubectl exec -i` standard input.
`vault write -format=json sys/unseal -` accepts this input without a terminal;
`vault operator unseal` does not accept a piped key in the supported releases.
The key is kept out of process arguments and Kubernetes exec request metadata.
The helper checks the resulting seal status and fails if Vault remains sealed.
`python3 scripts/test-vault-unseal.py` verifies stdin handling, skipped checks
and error propagation with a mock Kubernetes client. Repository validation and
CI run these checks automatically; real CLI behavior is also exercised by an
isolated old/new image fixture before changing the unseal mechanism.

Check timer activation and the most recent service exit without displaying
credentials:

```sh
sudo systemctl show bm-vault-unseal.timer \
  -p ActiveState -p SubState -p UnitFileState -p LastTriggerUSec
sudo systemctl show bm-vault-unseal.service \
  -p Result -p ExecMainStatus -p ExecMainExitTimestamp
```

A successful check on an already unsealed server verifies scheduling and the
read-only status path. Validate actual unsealing in an isolated recovery test;
do not seal the live cluster merely to test the timer.
