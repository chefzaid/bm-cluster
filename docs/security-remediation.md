# Trivy remediation — 2026-09-08

The target is zero vulnerabilities, exposed secrets, and unsafe configurations
at **every severity**, including Low and Unknown. The platform has not reached
that target. All eight distinct application runtime images currently scan clean;
shared platform images still have findings. No severity filters, ignore rules,
or vulnerability suppressions were added to obtain these results.

## Evidence and scope

A checksum-verified Trivy 0.74.0 client scanned all 59 active image references
against the cluster's Trivy server, including init containers and standalone
Longhorn pods. Some references resolve to the same image. Both old and candidate
images were scanned against the same database; the figures below count package
occurrences, not distinct CVEs. Retired ReplicaSet reports are not a reliable
measure of the running cluster.

[The sanitized scan summary](security-scan-summary.json) records the image pins,
all five severity counts, and secret counts. Raw reports and operational
credentials are retained outside Git. Image scan results are a dated snapshot;
the Grafana dashboard and reports for the current workload digest provide the
ongoing view.

DevApp's user, order and web images, Indezy's server and web images, Thoughty's
server/worker and web images, and Website's image each report **zero
vulnerabilities and zero exposed secrets**. The current PostgreSQL client,
Redis, Homepage, NGINX authentication helper, curl helpers, and new Node and
dashboard-sidecar images also scan clean.

## Platform image changes

Counts below are **Critical / High / Medium / Low / Unknown**.

| Component | Before | Patched image |
| --- | ---: | ---: |
| Trivy | 0 / 3 / 10 / 12 / 13 | 0 / 0 / 0 / 0 / 1 |
| Trivy Operator | 0 / 3 / 6 / 12 / 3 | 0 / 0 / 0 / 0 / 1 |
| OAuth2 Proxy | 0 / 1 / 0 / 0 / 3 | 0 / 0 / 0 / 0 / 1 |
| MongoDB | 9 / 263 / 184 / 33 / 33 | 8 / 66 / 16 / 16 / 24 |
| PostgreSQL | 16 / 92 / 185 / 155 / 14 | 15 / 71 / 164 / 153 / 8 |
| DBGate | 5 / 62 / 99 / 117 / 5 | 4 / 52 / 92 / 116 / 0 |
| Grafana | 3 / 159 / 32 / 13 / 36 | 3 / 157 / 26 / 1 / 16 |
| Dashboard sidecar | 0 / 8 / 10 / 12 / 0 | 0 / 0 / 0 / 0 / 0 |
| Vault | 1 / 12 / 6 / 12 / 3 | 1 / 10 / 0 / 0 / 3 |
| GitLab | 25 / 384 / 217 / 46 / 72 | 25 / 384 / 122 / 31 / 72 |
| Elasticsearch | 0 / 40 / 114 / 60 / 0 | 0 / 34 / 52 / 0 / 0 |
| Kibana | 0 / 9 / 135 / 86 / 0 | 0 / 5 / 15 / 4 / 0 |
| Logstash | 0 / 15 / 85 / 65 / 0 | 0 / 7 / 15 / 1 / 0 |

Across these thirteen images, findings decrease from 2,998 to 1,792. This is an
image comparison, not a sum of Kubernetes reports or a statement that all
remaining findings are exploitable.

The maintained build recipes are under `images/security/`. They pin their
upstream sources and runtime bases. Go services use Go 1.26.7 and patched
compatible dependencies. MongoDB retains 7.0.40 and GitLab retains Omnibus
19.3.1 while updating available OS packages. PostgreSQL retains its major
version, Debian/glibc, ICU, and volume ownership to preserve existing collation
and extension behavior. Elastic uses the official 9.4.6 Wolfi variants.

DBGate retains its supported Node 22 runtime and npm because plugin installation
uses npm. Its npm dependencies are updated. The dashboard sidecar and Node
helpers do not install packages at runtime, so unused package installers and
bundled installer archives are removed. The Node image is used by Sonar app
discovery and Kibana account synchronization.

PostgreSQL's unused snakeoil private key and GitLab's three image-baked SSH
host keys are removed from all published image layers. The final filesystems
are copied into new images with their original runtime metadata preserved.
GitLab generates installation-specific SSH keys on its persistent configuration
volume. PostgreSQL now reports zero secrets; GitLab decreases from 25 to 22.
The remaining GitLab matches are vendor examples/test fixtures and stay visible.
No production credentials were copied into these images.

## Configuration and reporting fixes

- A validating admission policy rejects Pods using `gitRepo` volumes, including
  volumes referencing local repositories. An empty volume list and ordinary
  `emptyDir` volumes remain allowed. This mitigates
  [CVE-2025-1767](https://github.com/kubernetes/kubernetes/issues/130786); the
  Kubernetes version-based vulnerability report can still list the CVE.
- Trivy Operator loads the configured trusted-registry policy data. A hash of
  both policy code and mounted policy data invalidates outdated configuration
  reports when the policy changes. Tests cover real ConfigMap projected-volume
  symlinks, trusted and untrusted registries, and missing policy data.
- Reports preserve Trivy's resolved severity instead of reclassifying rated
  advisories as Unknown. Actual Unknown findings remain Unknown. The detailed
  vulnerability table displays all severities.
- Automatic workload coverage includes standalone Pods, which covers workloads
  created by custom controllers such as Longhorn. Pods already covered by
  built-in workload owners are skipped to avoid duplicate scans.
- Stateless discovery and logging helpers use UID/GID 10001. The Logstash
  index-configuration helper has a read-only root filesystem. Existing database
  and persistent-volume owner IDs are preserved.
- Vault and ingress resource budgets are defined in their shared Helm values;
  both the installer and Ansible use those values. Vault image selection now
  uses the same rendering path as the platform's GitOps manifests.

The existing scanner memory allocation, immediate cleanup of completed scan
jobs, 24-hour report retention, RBAC assessment, infrastructure assessment,
secret scanning, and cluster compliance scans remain enabled. Obsolete reports
may be expired only after checking their owner has zero replicas, no live pods,
and a healthy replacement. Current findings must not be deleted to improve a
score.

## Installation, Ansible, and registry bootstrap

Patched platform images are hosted in GitLab's private registry. GitLab cannot
bootstrap by pulling its own image from a registry that has not started yet.
The renderer therefore supports two explicit profiles:

| Profile | Use |
| --- | --- |
| `bootstrap` | A fresh cluster uses pinned public upstream images until GitLab, Vault, registry authentication, and the patched images are available. Upstream findings remain visible. |
| `patched` | An existing cluster uses the tested private image digests and `platform-registry-auth`. |

`SECURITY_IMAGES_ENABLED=auto` is the default for
`scripts/render-cluster-config.sh` and the installer. It preserves the matching
existing Argo CD application's profile. A fresh installation or a different
domain selects bootstrap. Unexpected API failures stop rendering instead of
silently changing an existing cluster's profile. Explicit `true` or `false`
selects patched or bootstrap mode without cluster detection.

The Argo CD application carries its selected
`profiles/security-images-*.values` file and scanner registry parameters.
`k8s/security-images.json` supplies the public fallback pins and the patched
Vault pin. The renderer also creates `config/vault-values.yaml` in its private
output directory. Ansible reconciliation uses that generated file unless an
operator explicitly supplies a different `vault_values_file`.

For a fresh installation, publish the images described in the security build
recipes to the new registry and provision `platform-registry-auth` before
selecting the patched profile. For example, build from the recipe directory:

```sh
docker build -f images/security/node.Dockerfile \
  -t registry.example.com/swirlit/bm-cluster/security/node:RELEASE images/security
```

Scan each image and pin the resulting registry digest before enabling it. The
recorded digests describe the published artifacts; a later rebuild can produce
a different digest as package repositories receive updates. For GitOps,
select `profiles/security-images-patched.values` and set both
`trivy-operator.image.registry` and `trivy-operator.trivy.image.registry` to
`registry.<public-domain>`. Set those same parameters to `docker.io` when using
the bootstrap profile. Keep this selection in the root Application source.

`SECURITY_IMAGES_ENABLED=true ./install-control-plane.sh` enables the patched
profile through the shared installer. `ansible/deploy.yml` accepts `-e security_images_enabled=true` or the same
environment variable. The installer installs Python/YAML prerequisites before
rendering. Ansible does not implement a separate image-selection policy.

GitLab's cache DaemonSet keeps its exact image in use on eligible Linux/amd64
nodes using an idle, non-root container with no service-account token, writable
root filesystem, host mounts, or network listener. Argo CD waits for this cache
at wave -4 and updates GitLab at wave 1, after the other platform services.
The installer and Ansible call `scripts/cache-gitlab-image.sh` before applying
platform updates. This prevents image garbage collection from removing a
preloaded GitLab image while its registry is stopped. Cache and server image
pins must be updated together. Trivy still scans this workload; duplicate
reports for its shared GitLab image must not be mistaken for distinct images.

The initial rollout exposed this garbage-collection failure after a successful
pre-pull. GitLab was recovered with the original published digest, and the cache
workload was added to prevent recurrence. For manual recovery, an imported image
can additionally be labelled `io.cri-containerd.pinned=pinned`; verify that the
CRI reports it as pinned before restarting the registry. This label controls
[kubelet garbage collection](https://github.com/containerd/containerd/discussions/12156),
not an administrator's explicit image-deletion commands.

For recovery when the private registry is unavailable, preload the pinned
images into each K3s node's containerd image store from a protected offline
archive, or explicitly render the public bootstrap profile. Switching to public
images restores a compatible bootstrap path but restores their vendor findings
as well; switch back after registry recovery. Existing cached images use
`IfNotPresent` where configured.

## Findings that prevent zero

Trivy, Trivy Operator and OAuth2 Proxy each still report the module-level
Unknown advisory [GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932). It affects
the deprecated `golang.org/x/crypto/openpgp` package. Dependency inspection of
all three built commands confirms that none imports that package. Trivy and
the operator use the maintained ProtonMail implementation; OAuth2 Proxy
imports neither OpenPGP implementation. The module scanner still flags the
parent `x/crypto` module. This evidence supports treating these occurrences as
false positives, but the reports are retained without an ignore rule.

Many vendor images still bundle affected Go, Java, Ruby, Node, or OS packages.
Some have no fixed version in their supported distribution. A package-level
fixed version does not establish that a compatible fixed vendor image exists.
GitLab, PostgreSQL, MongoDB, DBGate, Grafana, Elastic, Argo CD, ingress NGINX,
SonarQube, GitLab Runner, Odoo, Longhorn/CSI, and other infrastructure retain
findings. Further supported upgrades or maintained rebuilds with integration
testing are required. Moving PostgreSQL between distributions also requires a
collation/extension migration plan; changing Longhorn's generated CSI sidecars
requires storage compatibility testing.

Generic hardening checks also report required host access, privileged storage
and networking operations, low persistent-volume owner IDs, and controller
RBAC. Removing those permissions blindly would disable cluster functions.
These findings remain visible and require component-specific changes or a
recorded, reviewed exception; they are not a basis for claiming zero.

## Validation

- Fresh scans of all active application images and all replacement images,
  including Low/Unknown findings and secret scanning.
- PostgreSQL and MongoDB initialization, writes, dump, restore, and readback in
  isolated containers; final flattened PostgreSQL image retested.
- DBGate and Grafana HTTP startup checks with non-root, read-only containers;
  DBGate npm registry download, dependency resolution, and extraction.
- Dashboard sidecar reads a ConfigMap from a test Kubernetes API and writes its
  dashboard file as a non-root user without package installers.
- OAuth2 Proxy readiness and forged identity rejection; encryption, cookie,
  session, and provider tests. Vault startup and health check.
- Elasticsearch index/write/read checks; Kibana integration and Logstash event
  processing checks for their official Wolfi images.
- Operator severity and policy regression tests, exact-source patch checks,
  both Helm profiles, installation/reconciliation profile tests, Ansible
  behavioral tests, and Kubernetes server-side dry-run.
- Admission tests accept ordinary Pods and reject `gitRepo` volumes. A recovery
  archive containing Kubernetes state, Vault, PostgreSQL, and MongoDB backups
  was verified before stateful rollouts.

Run `python3 scripts/test-security-images.py` and
`./scripts/validate-repository.sh --live` for the repository checks. Verification
of a running rollout must additionally compare its actual image digest with
its current Trivy report and confirm workload and Argo CD health.
