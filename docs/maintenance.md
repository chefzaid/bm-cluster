# Platform maintenance

Use this guide to update container images and UI themes. For an installation
still using ingress-nginx or private platform images, complete the separate
[platform migration](platform-migration.md) first. For routine health, storage
and backups, see [operations](operations.md).

## Image updates

Platform images are pinned by digest in their owning manifests and Helm values.
K3s and Longhorn use their pinned release images; two CSI sidecar pins live in
[system workload policy](../k8s/base/system-workload-hardening.yaml).
Application repositories own their images and pull credentials. There is no
platform image build pipeline, central image catalog or private registry dependency.

1. Review the upstream release's compatibility, architecture, runtime identity,
   writable paths and data format. Update the digest in the owning source;
   update app-owned database helpers in their repositories when needed.
2. Compare scanner reports across all severities, including exposed secrets.
   Check startup, readiness, authentication and service behavior with disposable
   data. For stateful services, restore a backup from the actual previous image
   and verify its data in the candidate.
3. Run [repository validation](operations.md#validation). Reconcile separately
   installed Helm releases through their shared helpers as well as GitOps
   resources. Keep a verified backup and the exact recovery image before rollout.
4. Verify the running digest, readiness, application behavior and fresh scanner
   reports. An upstream pin does not imply zero vulnerabilities; review unfixed
   advisories and scanner limitations in [observability](observability.md).

Keep experiments, downloaded images, reports and recovery archives outside Git.
The [validation policy](structure.md#validation-policy) defines which permanent
tests belong in this repository.

## Runtime and recovery constraints

| Component | Check before changing its image |
| --- | --- |
| PostgreSQL and its helpers | Keep the same upstream Bookworm release. Restore globals and databases in isolation; check ownership, libc/ICU collation versions, locales and extensions. A matching major version alone is insufficient. |
| Vault | Preserve its UID, Raft data and audit mounts. Follow [Vault upgrade and recovery](vault.md#upgrade-and-recovery) for snapshots, unseal material and rollout. |
| GitLab | Retain the matching GitLab version, configuration and secrets with its [native backup](operations.md#backups-and-recovery). |
| Keycloak | Preserve UID 1000 and writable augmentation paths. |
| SonarQube | Preserve UID 1000/GID 0 and group access to bundled files. |
| PostgreSQL / MongoDB | Preserve UID 999 and check existing volume ownership. Never recursively change ownership on active database volumes. |
| Storage components | Preserve host access and image-specific writable paths. [System hardening](../scripts/reconcile-system-hardening.sh) is independent of image selection. |

Keep a protected off-host archive of the exact recovery images and credentials.
During a registry outage, import pinned images into each node's containerd before
recovery. Retain legacy private artifacts and credentials until their installed
consumers and rollback window have both been retired. The old image-profile
files and retired inputs are handled by the [migration procedure](platform-migration.md).

## UI themes

SonarQube and Vault default to dark mode; their bottom-right **Dark / Light**
buttons save a browser preference. Odoo's **Dark Mode** user-menu switch saves an
account preference;
bootstrap enables it once for the managed administrator. Preferences survive
application restarts.

### SonarQube and Vault

Both use vendored Dark Reader assets, with license, provenance and integrity
annotations in the owning manifests. An external style-proxy script preserves
the application's Content Security Policy; asset requests remain on the same origin.

- [SonarQube](../k8s/platform/sonarqube.yaml) copies its HTML entry point in an
  init container and mounts the themed files read-only. Application bundles and
  scanner APIs are unchanged.
- [Vault](../k8s/platform/vault-ui-theme.yaml) serves only `/ui` through a separate
  NGINX helper. API traffic goes directly to Vault. The helper accepts UI GET/HEAD,
  strips forwarded credentials, has no Vault token, caches no responses, writes
  no access logs and is restricted by network policy.

When updating assets, bump the pod revision and HTML asset query versions.
After a theme or application upgrade, check authenticated navigation, console/CSP
errors, both toggle states and reload persistence. Also verify Vault's direct API
health and that the theme helper rejects API paths.

To remove Sonar's theme, remove its ConfigMap, init container, volumes and mounts
together. Removing Vault's theme Ingress restores its original `/ui` route;
retire the helper resources in the same change. Authentication and data do not
need to change.

### Odoo

[Odoo](../k8s/corp/odoo.yaml) vendors OCA's `web_dark_mode` module with source,
translations, tests and AGPL license. Bootstrap and the application mount it
read-only at `/mnt/extra-addons`; startup needs no download.

Check Odoo compatibility, update provenance and the Deployment revision, then
validate and test an authenticated `/odoo` page. Confirm that dark CSS loads and
the switch works both ways. Users can select dark mode, light mode or their device
preference. Uninstall the module in Odoo before removing its files.
