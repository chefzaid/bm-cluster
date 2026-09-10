# Security images

The platform uses pinned upstream images for bootstrap and selected custom
images where upstream releases still need dependency, runtime or scanner fixes.
The custom recipes are in `images/security/`. Their patches and lockfiles are
build inputs for those selected versions, not permanent platform requirements.

Prefer a supported upstream image once it includes the required fixes and passes
the relevant runtime checks. After replacing its last custom image reference,
remove that component's unused recipe, patches and helpers together. Keep shared
helpers until no remaining build uses them. Git history preserves retired
versions and experiments; the maintained tree does not need abandoned candidates
or dated scan exports.

## What needs to remain

- Dependency patches and library locks record the checked versions and checksums
  used by the selected rebuild. A newer release may make them unnecessary, but
  a release number alone does not establish that its image contains every fix.
- Some patches change behavior: Trivy Operator's policy-data refresh, severity
  reporting and standalone-Pod coverage are examples. A replacement must retain
  that behavior as well as updated dependencies.
- Admission, registry authentication, network restrictions, host hardening and
  ongoing Trivy reporting are platform configuration. They remain useful when
  an image no longer needs a custom dependency patch.
- Tests for deployed custom images protect actual behavior: database restore,
  authentication, DNS, embedded UI assets and native libraries. They are run
  when changing the relevant image; they are not all part of routine CI.

## Bootstrap and patched profiles

| Profile | Purpose |
| --- | --- |
| `bootstrap` | Public upstream digests for a new cluster or registry recovery. |
| `patched` | Tested private digests, with `platform-registry-auth` available. |

`SECURITY_IMAGES_ENABLED=auto` is the installer/renderer default. It preserves
the matching existing Argo CD application's choice and selects bootstrap for a
new cluster or a different domain. Unexpected API failures stop rendering.
Explicit `true` or `false` selects a profile without detection.

`k8s/security-images.json` supplies public fallbacks and the patched Vault pin.
Other private pins live in workload manifests, Helm values and image profiles.
The shared renderer
selects compatible runtime settings and renders Helm values for Vault and
ingress NGINX. Both installation paths use those outputs:

```sh
SECURITY_IMAGES_ENABLED=true ./install-control-plane.sh
ansible-playbook -i ansible/inventory ansible/deploy.yml \
  -e security_images_enabled=true
```

For GitOps, select `profiles/security-images-patched.values` in the root
Application and set both `trivy-operator.image.registry` and
`trivy-operator.trivy.image.registry` to `registry.<public-domain>`. Bootstrap
uses `profiles/security-images-bootstrap.values` and `docker.io` for both.
Publish the required images and provision pull credentials before enabling the
patched profile on a new cluster. See [Ansible operations](ansible.md) for the
shared installation and reconciliation inputs.

Argo CD's bundled Redis is an existing exception: `config/argocd-values.yaml`
still selects its custom Redis image in both profiles. Make that exact image
available on the target nodes, with pull credentials where needed, before
installing Argo CD. Selecting bootstrap alone does not remove this dependency.

## Build, test and replace an image

1. Check the upstream release and compatibility requirements. Preserve needed
   feature support, runtime identity and persistent-data formats.
2. Build only the component being changed. Use the pinned sources, toolchain,
   dependency locks and runtime base in its recipe:

   ```sh
   scripts/build-security-image.sh COMPONENT IMAGE_REFERENCE "$PRIVATE_OUTPUT"
   ```

   `COMPONENT` is the Dockerfile name without `.Dockerfile`. The helper bounds
   local build resources; large provider builds need sufficient host capacity.
   Set `TRIVY_EXECUTABLE` and `TRIVY_SERVER` to write a vulnerability/secret scan
   against the cluster's current database. The optional `SECURITY_IMAGE` GitLab
   pipeline variable invokes the same recipe and scan path.
3. Compare upstream/current and candidate images against the same Trivy database,
   including Critical, High, Medium, Low, Unknown and secrets. Check the actual
   application and dependency versions detected by the scanner. A blank or
   incorrect application version limits what the scan establishes.
4. Run the relevant source tests and isolated runtime checks below. Keep logs,
   fixture credentials and backups outside Git. An image assembled from a host
   binary does not by itself verify the complete Docker build recipe.
5. Publish the tested image and update all affected references to its immutable
   registry digest. Keep database backups and a recovery image before a stateful
   rollout. Update shared Helm inputs when the component is Helm-managed.
6. Verify rollout readiness, application behavior and fresh reports for the
   exact running digest. When a verified upstream image replaces a custom one,
   remove the now-unused build inputs and update its profile selection together.

Existing canaries use Docker with disposable data and require Python 3. Run
`python3 scripts/test-COMPONENT-image.py --help` for the full interface and
component-specific prerequisites. They can consume substantial memory and time;
run the one needed for the image being changed.

| Component | Retained check | Additional inputs |
| --- | --- | --- |
| CoreDNS | Plugins, UDP/TCP records, readiness, reload and restart | `--previous-image` |
| GitLab | Existing repositories/data, API, clone/push, registry and restart | `--previous-image`, `--expected-version` |
| Homepage | Configuration refresh, allowed hosts and native image processing | None |
| Keycloak | Existing realm, login, token/JWKS behavior and native/JVM libraries | `--previous-image`, `--postgres-image` |
| PostgreSQL | Runtime/extension parity, collations, indexes, authentication and restore | `--previous-image` |
| Prometheus | Existing WAL/history, targets, queries, rules and restart | `--previous-image` |
| SonarQube | Volume permissions, source analysis, authentication and libraries | `--scanner` |
| Vault | Raft upgrade/restore, stored secrets, auth, UI and audit behavior | `--previous-image` |

Every canary takes `IMAGE --logs PRIVATE_DIRECTORY`. Java fixtures, Ruby tests
and `test-vault-ui.py` support the corresponding active rebuilds. Keep them with
the library locks and extraction helpers they verify. Build-stage tests alone
do not establish final-image compatibility.

GitLab's Go build also emits three native Gitaly test binaries under
`/build/gitaly-tests` in the `gitlab-go-build` stage. Run them in the pinned
vendor runtime, with its native Git and libraries, before promoting a rebuild.

## Runtime and recovery constraints

Preserve PostgreSQL's libc/ICU, locale, extension and volume-owner compatibility;
restore every application database and globals into an isolated candidate
before changing them. MongoDB also needs a tested ownership migration before
changing its persistent UID. Follow [Vault's backup and recovery procedure](vault.md)
for Raft and unseal verification. Low UID/GID findings do not justify changing
data ownership without those checks.

Longhorn's CSI controllers require access to root-owned Unix sockets; host-facing
storage components need their storage permissions. The shared system-hardening
policy deliberately scopes which controllers it changes. Ingress and Longhorn
UI also depend on their writable directories, listener ports and capability
settings. Preserve the differences required by public and custom images.

The installer and Ansible apply `k8s/base/system-workload-hardening.yaml` and
run `scripts/reconcile-system-hardening.sh`. The helper checks admission with
server-side dry-run, waits for registry credentials and reconciles selected
controllers sequentially. Image overrides are applied after External Secrets;
they preserve image selections when K3s, Longhorn or Helm recreates controllers.

GitLab's registry cannot supply its own image while GitLab is stopped.
`k8s/platform/gitlab-image-cache.yaml` keeps its exact image in use on eligible
nodes; installer/Ansible call `scripts/cache-gitlab-image.sh` before updates.
Update cache and server pins together. The idle cache container has no API
token, host mounts or network listener. Retain recovery images on each node.

If the private registry is unavailable, preload the pinned images into each
node's containerd from a protected offline archive, or explicitly select the
public bootstrap profile. Bootstrap may restore vendor findings. Verify profile
compatibility and restore the patched selection after registry recovery.

## Current reports and repository validation

Use the Trivy Security Reports dashboard and current workload reports, rather
than committed counts that go stale as databases and images change:

```sh
kubectl get vulnerabilityreports,configauditreports,exposedsecretreports -A
./scripts/validate-repository.sh
./scripts/validate-repository.sh --live
```

Reports for retired ReplicaSets and duplicate reports for a shared image do not
represent additional running images. Keep current findings visible; do not
delete them or suppress severities to improve totals. Unfixed advisories and
scanner limitations require investigation, and the platform is not assumed to
have zero findings.

Repository validation runs shell, YAML, policy and installer/Ansible regression
checks. The image-profile tests run when Helm is installed; the current CI
validation image does not install Helm. Admission checks require `--live` and
use server-side dry-run. The manual image canaries above run separately before
their image is promoted.
