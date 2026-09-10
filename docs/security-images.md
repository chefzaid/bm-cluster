# Container image maintenance

Use supported upstream images where they meet the platform's runtime and security
requirements. Custom images in [images/security](../images/security/) carry build
inputs for the selected releases. When an upstream replacement passes the same
checks, remove the unused recipe, patches and tests after replacing its last
reference. Keep shared helpers while another maintained recipe uses them.

Image digests, dependency versions and checksums belong in the manifests,
[image catalog](../k8s/security-images.json), Helm values and recipes. Keep scan
exports and experiments outside Git; use current reports to assess findings.

## Image profiles

| Profile | Purpose |
| --- | --- |
| `bootstrap` | Public upstream images to start a new cluster or recover the registry. |
| `patched` | Tested private images with `platform-registry-auth` available. |

`SECURITY_IMAGES_ENABLED=auto` preserves the matching existing Argo CD
Application's selection and chooses bootstrap for a new cluster or different
domain. Unexpected API errors stop rendering. Explicit `true` or `false` selects
a profile without detection. The shared renderer also selects compatible runtime
settings and Vault/ingress Helm values for both installation paths:

```sh
SECURITY_IMAGES_ENABLED=true ./install-control-plane.sh
ansible-playbook -i ansible/inventory ansible/deploy.yml \
  -e security_images_enabled=true
```

For GitOps, use the matching file under [k8s/profiles](../k8s/profiles/) in the
root Application. The patched profile uses `registry.<public-domain>` for both
`trivy-operator.image.registry` and `trivy-operator.trivy.image.registry`;
bootstrap uses `docker.io`. Publish images and provision pull credentials before
enabling the patched profile. See [Ansible operations](ansible.md) for
reconciliation inputs.

Argo CD's Redis image in [its Helm values](../config/argocd-values.yaml) is
configured separately and remains private in both profiles. Make that exact
image and its pull credentials available before installing Argo CD; selecting
bootstrap alone does not remove this dependency.

## Build and promote

1. Check upstream compatibility, including features, runtime identity and
   persistent-data formats, before choosing a replacement.
2. Build the selected recipe with the shared helper:

   ```sh
   scripts/build-security-image.sh COMPONENT IMAGE_REFERENCE "$PRIVATE_OUTPUT"
   ```

   `COMPONENT` is the Dockerfile name without `.Dockerfile`. Use an output
   directory outside Git. `TRIVY_EXECUTABLE` and `TRIVY_SERVER` enable a scan
   against the cluster's database. The optional `SECURITY_IMAGE` GitLab pipeline
   variable uses the same build helper.
3. Scan the current and candidate images against the same Trivy database,
   including every severity and exposed secrets. Check that the scanner detects
   the actual application and dependency versions.
4. Run the relevant source tests and isolated final-image checks. Existing
   `scripts/test-COMPONENT-image.py` canaries use disposable Docker data; run
   the selected script with `--help` for inputs. They cover DNS, databases,
   authentication, UI assets and upgrade/recovery behavior as appropriate.
   Build-stage tests alone do not verify the final image.
5. Publish the candidate and update all affected pins to its immutable digest,
   including Helm inputs and any image cache. Retain a verified backup and
   recovery image before changing stateful services.
6. Verify readiness, application behavior and fresh reports for the exact
   running digest. Remove obsolete build inputs when the replacement is proven.

GitLab's Go build emits native Gitaly tests in `/build/gitaly-tests` in the
`gitlab-go-build` stage. Run them with the vendor runtime's Git and libraries
before promoting a rebuild.

## Runtime and recovery constraints

- Preserve database UID/GID, locale, libc/ICU and extension compatibility. Test
  ownership migrations and restore application databases and globals into an
  isolated candidate before changing them. A scanner UID finding alone does not
  justify changing persistent-file ownership. [Vault recovery](vault.md) has
  additional Raft and unseal requirements.
- Preserve storage components' access to host devices and root-owned CSI
  sockets, and each image's writable paths, ports and capabilities. The
  [system hardening policy](../k8s/base/system-workload-hardening.yaml) scopes
  these exceptions. Installer and Ansible use
  [the shared reconciler](../scripts/reconcile-system-hardening.sh), which checks
  admission and updates selected controllers sequentially after credentials
  become available.
- GitLab cannot pull its own image from its registry while it is stopped.
  [The image cache](../k8s/platform/gitlab-image-cache.yaml) keeps that exact
  image in use on eligible nodes; installation and updates also use
  [cache-gitlab-image.sh](../scripts/cache-gitlab-image.sh). Update cache and
  server pins together, and retain a protected offline recovery archive.

During a registry outage, preload pinned images into each node's containerd
from that archive, or explicitly select a compatible bootstrap profile. Restore
the intended profile after recovery and reassess its reports.

## Assess findings

Use [the current Trivy reports](operations.md#observability) and match findings
to running image digests and workloads. Retired ReplicaSets and
shared-image duplicates need context; they do not represent additional running
images. Investigate unfixed advisories and scanner limitations without hiding
severities or deleting active findings. Run the repository checks documented in
[operations](operations.md) as well as the selected image's runtime canary.
