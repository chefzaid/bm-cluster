# Trivy remediation — updated 2026-09-10

The target is zero vulnerabilities, exposed secrets, and unsafe configurations
at **every severity**, including Low and Unknown. The platform has not reached
that target. All eight distinct application runtime images scanned clean in the
September 9 baseline. The September 10 recheck found eight new findings in
Thoughty's server image and two in Homepage; follow-up fixes are underway.
Shared platform images still have findings. No severity filters, ignore rules,
or vulnerability suppressions were added to obtain these results.

## Evidence and scope

A checksum-verified Trivy 0.74.0 client scanned all 59 active image references
against the cluster's Trivy server, including init containers and standalone
Longhorn pods. Some references resolve to the same image. Each batch compares
old and candidate images using the cluster Trivy server; the figures below
count package occurrences, not distinct CVEs. Database updates
can change counts between batches. Retired ReplicaSet reports are not a reliable
measure of the running cluster.

[The sanitized scan summary](security-scan-summary.json) records the image pins,
all five severity counts, and secret counts. Raw reports and operational
credentials are retained outside Git. Image scan results are a dated snapshot;
the Grafana dashboard and reports for the current workload digest provide the
ongoing view.

DevApp's user, order and web images, Indezy's server and web images, Thoughty's
server/worker and web images, and Website's image each reported **zero
vulnerabilities and zero exposed secrets** in that baseline. The current PostgreSQL client,
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
| GitLab | 25 / 405 / 151 / 31 / 72 | 3 / 19 / 35 / 11 / 20 |
| Elasticsearch | 0 / 40 / 114 / 60 / 0 | 0 / 34 / 52 / 0 / 0 |
| Kibana | 0 / 9 / 135 / 86 / 0 | 0 / 5 / 15 / 4 / 0 |
| Logstash | 0 / 15 / 85 / 65 / 0 | 0 / 7 / 15 / 1 / 0 |

Across these thirteen images, findings decrease from 2,938 to 860. This is an
image comparison, not a sum of Kubernetes reports or a statement that all
remaining findings are exploitable.

The maintained build recipes are under `images/security/`. They pin their
upstream sources and runtime bases. Go services use Go 1.26.7 and patched
compatible dependencies. MongoDB retains 7.0.40 and GitLab upgrades Omnibus
from 19.3.0 to 19.3.1 while updating available OS packages. PostgreSQL retains its major
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

### SonarQube runtime and libraries

SonarQube keeps Community Build **26.8.0.126808** and its database schema. Its
Wolfi/OpenJDK 25 runtime and verified dependency updates reduce the image from
268 vulnerabilities (25 High, 197 Medium, 46 Low) to **zero at every severity**,
with zero exposed secrets. The application, embedded Elasticsearch, scanner
engine and language analyzers remain included. The full JDK is required by
Elasticsearch's entitlement module; a JRE-only runtime does not start correctly.

`images/security/sonarqube.Dockerfile` uses the pinned vendor image and applies
`sonarqube-libraries.py` before copying the payload into the final runtime.
`sonarqube-maven-lock.json` pins both original and replacement Maven artifacts
by SHA-256. The patcher verifies original class bytes, replaces the corresponding
implementation and metadata together, preserves merged service providers, and
updates Elasticsearch's nested-library listing. It refuses modified or relocated
classes and signed aggregate jars. It never rewrites a version without updating
the library implementation.

Updates cover Jackson, Netty/Reactor, PostgreSQL JDBC, HTTP components, logging,
mail, LZ4 and Apache SSHD. SSHD uses the existing Bouncy Castle Ed25519 provider
instead of the optional, unmaintained `net.i2p.crypto:eddsa` implementation.
The regression fixture checks valid signatures, rejection of a non-canonical
signature, SSH authentication, host-key verification and an SSH command through
the scanner's unchanged SVNKit client.

The patched image and theme initializer use UID/GID/fsGroup 10001 with a
read-only root and dropped capabilities. Public bootstrap retains UID/GID 1000
because the vendor payload's directory permissions require its original owner.
Both Helm and the shared installer/Ansible renderer select the matching profile.
Existing volume files keep their UID; kubelet updates group access through
`fsGroup`. The disposable-volume test verifies a restart with files owned by
UID 1000 and confirms the saved analysis remains readable.

Before deployment, run the candidate against disposable Docker volumes and a
verified [SonarScanner CLI](https://docs.sonarsource.com/sonarqube-community-build/analyzing-source-code/scanners/sonarscanner).
The test binds only to loopback, creates temporary credentials, processes Java,
JavaScript and Python analysis, and removes its containers and volumes afterward:

```bash
docker build -f images/security/sonarqube.Dockerfile \
  -t sonarqube-security:review images/security
python3 scripts/test-sonarqube-image.py sonarqube-security:review \
  --scanner /path/to/verified/sonar-scanner-cli.jar \
  --logs /path/to/private/sonarqube-test-logs
```

The test requires Java/javac 21 or newer on the host; the SSH regression runs
inside the candidate's JDK. Take a private PostgreSQL custom-format backup before
the existing cluster's Recreate rollout, validate it with `pg_restore`, and check
the new digest's live vulnerability, secret and configuration reports afterward.
These results apply to SonarQube; the platform as a whole still has findings.

### Keycloak runtime and libraries

Keycloak retains **26.7.3** and its database schema. A fresh comparison reduces
36 vulnerabilities (1 Critical, 2 High, 11 Medium and 22 Low) to **zero at every
severity**, with zero exposed secrets. Its Wolfi/OpenJDK 25 runtime uses a
[supported Java version](https://www.keycloak.org/server/supported-configurations).

The image replaces 21 complete, checksum-verified Maven artifacts: the Netty
4.1 modules move together to 4.1.137.Final, OpenTelemetry's stable API/context/common
modules move to 1.62.0, and the SQL Server JDBC driver moves to 13.4.0.jre11.
Quarkus's application model references the original library paths, so filenames
stay stable while the entire implementation, manifest and Maven metadata are
replaced. `keycloak-maven-lock.json` records both original and replacement
SHA-256 hashes. No version-only edits or scan exclusions are used.

The build regenerates Keycloak's optimized application with PostgreSQL, health,
metrics and the existing `/auth` path enabled. These are build-time settings;
database credentials and realm imports remain runtime Kubernetes Secrets.
Library regression checks verify that CORS preserves existing `Vary` headers,
telemetry baggage obeys size/count limits, and the updated JDBC driver loads.

The patched deployment runs as UID/GID 10001 with a read-only root filesystem.
Bounded temporary volumes provide `/tmp` and `/opt/keycloak/data`; realm imports
remain read-only. Both Helm and the installer/Ansible renderer preserve the public
bootstrap image's original user and writable build behavior, then select the
optimized startup, registry credentials and stricter permissions for the patched
profile. Both profiles have regression coverage.

```bash
scripts/build-security-image.sh keycloak keycloak-security:review
python3 scripts/test-keycloak-image.py keycloak-security:review \
  --previous-image quay.io/keycloak/keycloak@sha256:ff4257d0d64efbe99ed1ddfaf07765cc3c36dc7518bf8324d41961327f441c54 \
  --postgres-image docker.io/library/postgres@sha256:b939b3851e2cccb017dc4497af63b15e34efa57fba036548773c53b2f16a8871 \
  --logs /path/to/private/keycloak-test-logs
```

The test requires Docker, Python and `cryptography`. It initializes a disposable
PostgreSQL database with the vendor image, performs a browser authorization-code
login with PKCE over verified HTTPS, checks the ID-token signature, and upgrades
the same database to the candidate. Existing users, signing keys and refresh
sessions must survive. New logins, invalid-password rejection, restart, health,
metrics and OIDC discovery are checked under the candidate's read-only permissions.
Ports bind only to loopback; fixture containers, volumes and network are removed
on exit. Logs contain fixture credentials and stay outside Git. Promotion also
requires a private, validated backup of the live Keycloak database and live
readiness, discovery, scrape and report checks.

### GitLab application and bundled tools

The latest GitLab image comparison reduces 684 vulnerabilities
(25 Critical, 405 High, 151 Medium, 31 Low, 72 Unknown) to 88
(3 Critical, 19 High, 35 Medium, 11 Low, 20 Unknown). All three remaining
Critical matches identify the bundled VS Code Handlebars extension as the
unrelated npm package. Reports remain unsuppressed. The Ruby portion decreases
from 55 to eight findings; 22 vendor secret examples remain visible.

The expanded `gitlab.Dockerfile` pins the actual Omnibus **19.3.1** release,
retaining PostgreSQL 17 and Ruby 3.3.12. The previous image's `19.3.1-*` tag
contained package `gitlab-ce 19.3.0-ce.0` and Rails revision `2c30df7828b`.
The replacement contains `19.3.1-ce.0` and revision `668508315ee`, verified
against its package inventory, application files and API. Tag names alone are
not version evidence.

This is an application upgrade, including regular and post-deploy database
migrations. [GitLab's 19.3.1 release notes](https://docs.gitlab.com/releases/patches/patch-release-gitlab-19-3-1-released/)
describe the import-processing denial-of-service fix and the required downtime
for a single-node installation. The dependency fixes described below are
retained across the upgrade; Gitaly, KAS, Pages and Workhorse use the source
commits matching the new vendor release.

`gitlab-go/components.json` pins
fourteen source repositories/modules and the build flags and installation paths
for 26 Go executables. Gitaly's four embedded Go helpers are rebuilt too; its
nine native Git executables come from the pinned vendor image. Go 1.26.7 and
compatible dependency patches include the
[gRPC 1.83.2 security fix](https://github.com/grpc/grpc-go/releases/tag/v1.83.2).
Prometheus moves from 3.11.2 to 3.11.3, with its real release recorded in the
Omnibus inventory.

Prometheus's Docker discovery uses the maintained Moby client/API modules.
Devfile's registry client uses ORAS v2, with tests for HTTP/TLS pulls, media-type
selection and path traversal. GitLab Shell's SSH configuration preserves the
`source-address` restriction when authenticating certificates; matching,
nonmatching and malformed CIDRs are covered by real handshake tests.

`gitlab-ruby/` maintains separate patches for Rails and the administration
bundle. Updates cover Rails 7.2.3.2, GraphQL 2.6.9, XML/HTML parsing, mail,
HTTP clients, scheduling and supporting gems. Cinc remains 18.3.0 and InSpec
remains 6.6.0. Both bundles explicitly select Omnibus's existing native FFI
build so libcurl and libarchive resolve from its embedded library directory.
Matching Ruby headers are regenerated from a checksum-verified source archive
only in the build stage, without replacing the interpreter or libruby.

The build rejects dependency downgrades. It preserves all locked gem versions
and dependencies of other installed Omnibus gems when removing complete
superseded installations. It replaces the default Resolv implementation and
specification together after verifying both original and replacement artifacts.
The final image starts with a fresh Ruby directory, preventing Docker's directory
merge behavior from retaining removed versions.

GitLab's Sidekiq Cron patch keeps its polling behavior with 2.4.0. The upstream
change adds a process-count override; tests cover that option, explicit GitLab
and Sidekiq intervals, and scaling when neither is configured. Library tests
also cover native loading, JSON/HTML/GraphQL parsing, PDF rendering and CSS
inlining. The compatible CSS 1.22.0 patch is pinned because CSS 3 would make
Bundler downgrade CarrierWave to satisfy conflicting SSRF-filter requirements.

Builds run source tests and produce three additional Gitaly test executables
under `/build/gitaly-tests` in the `gitlab-go-build` stage. Those native suites
must run with the matching Omnibus Git/shared libraries. Before promotion, run
the complete candidate with disposable volumes:

```bash
scripts/build-security-image.sh gitlab gitlab-security:review
python3 scripts/test-gitlab-image.py gitlab-security:review \
  --previous-image "${GITLAB_PREVIOUS_IMAGE:?Set the currently deployed image reference}" \
  --expected-version 19.3.1 \
  --logs /path/to/private/gitlab-test-logs
```

The integration test needs Docker, Git and OpenSSH on the host. It bounds the
test container to 5 GiB and two CPUs, binds ports only to loopback, and verifies
reconfiguration, password checks, REST/GraphQL, HTTP and SSH repository pushes,
authenticated OCI uploads/downloads, and persisted data after restart. With
`--previous-image`, it initializes all fixture data with the old image and
upgrades the same volumes to the candidate. It verifies existing API credentials,
SSH keys, Git history and registry blobs before writing new data, checks a new
push, and then restarts the candidate. `--expected-version` rejects a mislabeled
application version. Omitting `--previous-image` tests fresh initialization. It
removes its containers and volumes on exit. Keep its logs outside Git because
vendor startup can log generated fixture credentials.

The deployment disables privilege escalation, matching the integration test.
Promotion also requires private, validated backups of all bundled PostgreSQL
databases (including the registry database), roles and configuration,
the existing GitLab image-cache DaemonSet, repository validation, and checks of
the new digest's live reports and delivery pipeline. This work does not make
Omnibus a non-root application. Remaining uploader/authentication/ZIP dependency
constraints, vendor examples, unpatched advisories and image-classification
issues remain visible; do not remove scan coverage or rewrite package versions
to report zero. In particular, Trivy can confuse VS Code extension manifests
with npm packages, as described in the
[upstream report](https://github.com/aquasecurity/trivy/discussions/6112).

### Prometheus runtime

The standalone Prometheus image retains **3.14.0**, its official UI and its
storage format. Rebuilding Prometheus and promtool with Go 1.26.7 and compatible
dependency updates reduces 14 findings (2 Critical, 4 High, 2 Medium and
6 Unknown) to **two Unknown module advisories**, with zero exposed secrets.
The remaining reports identify the unpatched parent `x/crypto` module advisory.

`images/security/prometheus.Dockerfile` pins the source commit, upstream image,
Go builder and official UI archive checksum. Updates include gRPC 1.83.2,
`x/crypto`, `x/net`, `x/text` and the Moby client. The build verifies 47 source
packages covering configuration, models, discovery, web APIs and scraping.
Run source tests inside the build container: the Triton no-server fixture
assumes localhost port 443 is unused, which is false on the cluster host.

The integration test uses UID/GID 65534, dropped capabilities and a read-only
root, matching the deployment. It writes samples with the previous image,
starts the candidate with that same disposable volume, verifies historical
queries, scraping, PromQL, UI assets and configuration reload, then checks
the saved samples again after restart:

```bash
scripts/build-security-image.sh prometheus prometheus-security:review
python3 scripts/test-prometheus-image.py prometheus-security:review \
  --previous-image <current-image-digest> \
  --logs /path/to/private/prometheus-test-logs
```

The test binds only to loopback and removes its containers and volume on exit.
After rollout, verify readiness, active scrape targets, query results and the
new digest's vulnerability, secret and configuration reports.

### GitLab Runner and job helpers

The 19.3.1 Runner rebuild uses the supported Alpine distribution, Go 1.26.7
and patched dependencies. Its image decreases from 258 findings to two Unknown
module advisories. The corresponding job helper has one Unknown advisory;
both images report zero exposed secrets. Manager and helper versions remain
19.3.1 so their job protocol stays aligned.

Docker Machine remains available. Its retired `github.com/docker/docker`
dependency is replaced with the maintained Moby client/API modules, following
the [upstream module split](https://github.com/moby/moby#go-modules). Tests cover
version negotiation, container creation/start and completion or failure of an
image pull. Runner common, helper, Kubernetes executor and network tests pass.

The manager uses UID/GID 10001 with its existing read-only root and disposable
home directory. Both public and patched manager images were tested with these
permissions. A patched helper uploaded and downloaded a ZIP artifact through a
local HTTP fixture and verified its contents. The runner template pins the helper
explicitly, uses registry credentials only in patched mode and schedules these
Linux/amd64 images on matching nodes. Preserve SIGQUIT draining when updating
an existing manager; do not terminate an active job to accelerate deployment.

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
GitLab, PostgreSQL, MongoDB, Grafana, Elastic, Argo CD,
GitLab Runner, Odoo, Longhorn/CSI, and other infrastructure retain
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
