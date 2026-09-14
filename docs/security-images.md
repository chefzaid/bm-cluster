# Container image maintenance

Platform workloads use digest-pinned public upstream images. Their owning
manifests and Helm values are the source of truth; K3s and Longhorn use the
component images from their pinned releases. There is no downstream image
build pipeline, central image catalog, private platform registry dependency or
runtime image substitution policy. Application images and their pull
credentials remain application-owned.

Existing installations must follow [the platform migration](platform-migration.md)
before adopting these sources. The two files in `k8s/profiles/` deliberately fail
rendering for old root Applications; they contain no image selection. Remove
those references from the installed Application during the prepared migration.
`SECURITY_IMAGES_ENABLED` and `security_images_enabled` are retired inputs.

## Image updates

1. Select a compatible upstream release and review its upgrade requirements,
   architecture, runtime identity, writable paths and persistent-data format.
   Pin its digest in the owning manifest or Helm values. Update app-owned
   database helpers in the application repositories when their version changes.
2. Compare current and candidate scanner reports, including all severities and
   exposed secrets. Check startup, readiness, authentication and service behavior
   with disposable data. For stateful services, restore a backup from the actual
   previous image and verify data before accepting a replacement.
3. Run [repository validation](operations.md#validation). Reconcile separately
   installed Helm releases through their shared helpers as well as GitOps
   resources. Keep a verified backup and recovery image before a stateful rollout.
4. Verify the running digest, readiness, application behavior and fresh reports
   after promotion. A public upstream pin is not a claim of zero vulnerabilities.
   Investigate unfixed advisories and scanner limitations without hiding findings.

Experiments, downloaded images, scan reports and recovery archives belong outside
Git. Keep only checks that guard an otherwise untested deployment or recovery
failure; do not recreate a per-image test framework here.

## Runtime and recovery constraints

- PostgreSQL and its helpers use the same upstream Bookworm release. Verify
  database ownership, libc/ICU collation versions, locale and extensions when
  replacing a differently built image. Restore globals and databases into an
  isolated candidate; a matching major version alone is insufficient.
- Vault uses upstream Raft storage and its existing UID. Follow [Vault recovery](vault.md)
  for snapshots, unseal material and audit storage. GitLab backups also require
  the matching GitLab version and its separately protected configuration/secrets.
- Keycloak uses the vendor's UID 1000 and writable augmentation paths; SonarQube
  uses UID 1000/GID 0 with group access to its bundled files. PostgreSQL and
  MongoDB use UID 999. Check existing volume ownership before changing images;
  do not recursively change ownership on active database volumes.
- Preserve storage components' host access and image-specific writable paths.
  [System workload hardening](../k8s/base/system-workload-hardening.yaml) and
  [its reconciler](../scripts/reconcile-system-hardening.sh) remain independent
  of image selection.

Maintain a protected off-host archive of the exact recovery images and credentials.
During a registry outage, import the pinned public images into each node's
containerd before recovery. The old GitLab self-registry image cache is unnecessary
because GitLab itself now comes from the public vendor registry. Retain legacy
private artifacts and credentials outside this source tree until installed
consumers and the rollback window have both been retired.
