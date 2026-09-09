# Trivy remediation — updated 2026-09-09

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
| MongoDB | 9 / 263 / 184 / 33 / 33 | 0 / 0 / 0 / 0 / 8 |
| PostgreSQL | 16 / 92 / 185 / 155 / 14 | 15 / 71 / 164 / 153 / 8 |
| DBGate | 5 / 62 / 99 / 117 / 5 | 0 / 0 / 0 / 0 / 0 |
| Grafana | 3 / 159 / 32 / 13 / 36 | 3 / 157 / 26 / 1 / 16 |
| Dashboard sidecar | 0 / 8 / 10 / 12 / 0 | 0 / 0 / 0 / 0 / 0 |
| Vault | 1 / 12 / 6 / 12 / 3 | 1 / 10 / 0 / 0 / 3 |
| GitLab | 25 / 384 / 217 / 46 / 72 | 25 / 384 / 122 / 31 / 72 |
| Elasticsearch | 0 / 40 / 114 / 60 / 0 | 0 / 34 / 52 / 0 / 0 |
| Kibana | 0 / 9 / 135 / 86 / 0 | 0 / 5 / 15 / 4 / 0 |
| Logstash | 0 / 15 / 85 / 65 / 0 | 0 / 7 / 15 / 1 / 0 |

Across these thirteen images, findings decrease from 2,998 to 1,406. This is an
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

### Controller rebuilds and storage verification

The September 9 controller batch uses the same upstream application releases,
Go 1.26.7 and compatible dependency patches. Counts include every severity:

| Component | Previous findings | Rebuilt findings |
| --- | ---: | ---: |
| Ingress NGINX 1.15.1 | 284 | 0 |
| CSI provisioner 5.3.0 | 66 | 0 |
| CSI attacher 4.12.0 | 41 | 1 Unknown |
| CSI snapshotter 8.6.0 | 28 | 1 Unknown |
| CSI resizer 2.2.1 | 23 | 1 Unknown |
| CSI node registrar 2.17.0 | 23 | 0 |
| CSI liveness probe 2.19.0 | 23 | 0 |
| Metrics Server 0.9.0 | 18 | 1 Unknown |
| Local Path Provisioner 0.0.37 | 8 | 0 |
| Kube State Metrics 2.20.0 | 7 | 1 Unknown |

All ten candidates report zero exposed secrets. Source tests, restricted CLI
startup and registry digest verification precede deployment. Ingress was tested
with a separate controller class and Service selector: HTTPS served the backend
and HTTP redirected to HTTPS. After the CSI rollout, a disposable Longhorn
volume passed provision, write, unmount, remount, readback and deletion. The
registrar successfully registered with kubelet without privileged mode.

Only the registrar and liveness sidecars lose privileged mode, gain a read-only
root, RuntimeDefault seccomp, dropped capabilities and resource budgets. They
retain root to access the existing root-owned Unix sockets. The main CSI driver,
its host mounts and mount propagation remain intact. This follows the registrar's
[documented socket permissions](https://github.com/kubernetes-csi/node-driver-registrar/blob/v2.17.0/README.md).

Ingress also uses UID/GID 10001, a read-only root filesystem, RuntimeDefault
seccomp and no capabilities in the patched profile. A restricted init container
copies the shipped NGINX configuration and directory structure into writable
volumes. Its image follows the controller digest, including Argo profile changes.
The rebuilt image removes inherited file capabilities from NGINX and `dumb-init`.
The public bootstrap image requires `NET_BIND_SERVICE` for those executables;
bootstrap rendering retains that capability. Both profiles passed an isolated
HTTPS/redirect test with the same directories and UID.

The shared renderer now produces `config/ingress-nginx-values.yaml` for both
`install-control-plane.sh` and `ansible/deploy.yml`. Container listeners use
8080/8444; the public LoadBalancer Service retains 80/443 and the admission
webhook retains 8443. Apply the rendered values in an ingress Helm upgrade when
reconciling an existing cluster; the platform image policy keeps both controller
and initializer pins consistent afterward.

Build recipes pin each source commit and record its actual release tag in Go
build metadata. Ingress uses the upstream `controller-v1.15.1` release; a local
`v1.15.1` tag at that same commit lets Go record its version accurately. This is
not a vulnerability exception or an application version upgrade.

### September 9 follow-up

The next image batch replaces DBGate's Debian runtime with Wolfi while retaining
Node 22 and the application's native drivers. Its fresh image scan reports
**0 / 0 / 0 / 0 / 0**, down from 264 package findings. SQLite writes, DuckDB
queries, Oracle/SSH/libSQL module loading, and non-root, read-only HTTP startup
were verified. The image starts the API directly; Kubernetes manages `/etc/hosts`.

Alertmanager 0.34.0, Node Exporter 1.12.1, and CoreDNS 1.14.7 are rebuilt from
pinned upstream commits using Go 1.26.7 and compatible patched dependencies.
Their candidate scans decrease from 64, 12, and 32 findings to **2, 1, and 1
Unknown** findings respectively, all the module-level OpenPGP advisory discussed
below. Alertmanager retains its embedded UI and `amtool`; its readiness/UI,
Node Exporter metrics, and a CoreDNS UDP answer were tested with restricted
runtime permissions. Source tests and dependency patches accompany each recipe.

These are image comparisons against the same Trivy database, not a claim that
the entire cluster is clean. Verify the running digest and its current report
after every rollout.

Longhorn UI 1.12.1 retains the upstream static assets and manager proxy behavior
on an updated NGINX Alpine runtime. Its live vulnerability and configuration
reports both show zero findings. The public bootstrap image and patched image
were tested with the same non-root UID/GID 10001, read-only root, dropped
capabilities and writable NGINX directories. The UI does not mount a Kubernetes
service-account token. Its deployment is protected by the same foundation and
image-override mechanism as the system controllers.
The separate driver deployer and its readiness init container also run as
UID/GID 10001 with bounded resources, seccomp, dropped capabilities and a
read-only root. Their Kubernetes credential remains enabled because the
deployer creates the CSI controllers. Engines and host-facing CSI plugins
retain their required storage permissions.

MongoDB retains server 7.0.40, shell 2.10.0 and database tools 100.18.0, with a
Wolfi runtime, patched YAML helper and rebuilt Go tools. Kerberos/GSSAPI and PIE
builds are preserved. The candidate scan falls from 130 findings to eight
Unknown OpenPGP module advisories, with zero exposed secrets. Tests cover an
existing volume created by the old image, authenticated writes, all eight
tool commands, and dump/restore with readback. A live archive is taken before
deployment.

MongoDB keeps UID/GID 999. An isolated test showed that changing only the UID
and volume group prevents WiredTiger from opening its existing files. An owner
migration needs a separate tested data-migration procedure; the remaining owner
ID checks are not resolved by granting extra capabilities to the database.

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
- Narrowly scoped admission policies harden the stored Deployment templates
  for K3s CoreDNS, Metrics Server and Local Path Provisioner, and Longhorn's
  four CSI controller sidecars. This also covers replacements generated by
  their upstream controllers. K3s stateless services run as UID/GID 65534;
  all seven use seccomp, dropped capabilities, read-only roots, writable `/tmp`
  where needed, and bounded CPU/memory. Existing explicit budgets are preserved.
  The first rollout removed 88 configuration findings from fresh reports.
- CSI controllers retain root identity to connect to Longhorn's root-owned
  Unix socket; engines, instance managers and CSI node plugins are outside
  these policies. A disposable Longhorn volume passed provisioning, writing,
  unmounting, remounting, reading and deletion after the controller rollouts.

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

Both entry points apply `k8s/base/system-workload-hardening.yaml` with the
foundation and run `scripts/reconcile-system-hardening.sh`. The helper waits
for admission to produce the expected template in a server-side dry run,
then reconciles existing controllers sequentially and waits for readiness.
It fails if admission or a rollout fails. New/recreated controllers receive
the same policy automatically.

The system image overrides are installed separately with platform resources,
after External Secrets. Vault supplies `platform-registry-auth` in `kube-system`
and `longhorn-system` as well as the existing platform namespaces. The helper
waits for pull credentials and verifies every selected container digest in a
server-side dry run. This covers CoreDNS, Metrics Server, Local Path Provisioner,
the four CSI controllers, both CSI sidecars, Longhorn UI and ingress NGINX.
Kube State Metrics is pinned directly in the monitoring manifest. Bootstrap mode
uses public pins; patched mode uses private rebuilds. Narrow admission policies
preserve these selections when K3s, Longhorn or Helm recreates a controller.
Both the installer and Ansible reconcile Deployments and the CSI DaemonSet
through the same helper; no separate live-only image overrides are required.
Keep this image cached on each node for recovery when the registry is down.

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
GitLab, PostgreSQL, MongoDB, Grafana, Elastic, Argo CD, ingress NGINX,
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
