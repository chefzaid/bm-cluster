# Repository structure

Use this map when changing platform source. The [README](../README.md) explains
platform boundaries and links operator workflows. Keep runtime resources in their
owning application repository; this repository centrally owns Odoo.

## Directory map

| Directory | Responsibility |
| --- | --- |
| `.github/workflows/` | GitHub/GitLab source synchronization. |
| `ansible/` | Inventory and the installation/reconciliation playbooks. |
| `config/` | Shared version and service inventories in `platform.env`; Helm release values and the public origin CA certificate. |
| `config/application-cluster/` | Target firewall policy and temporary route/dependency probes used during registration. |
| `config/host/` | AppArmor, Longhorn multipath settings, and systemd backup/unseal units copied onto hosts. |
| `docs/` | Task guides; the root README is the guide index. |
| `k8s/` | The GitOps Helm chart, shared values. Argo CD continues to use `path: k8s`. |
| `k8s/base/` | Namespaces, cluster identity, DNS and baseline admission/network/host policy. |
| `k8s/datastores/` | Shared PostgreSQL, MongoDB, Redis and Kafka resources. |
| `k8s/platform/` | Delivery, identity, observability, ingress and other shared services, including support for application namespaces. |
| `k8s/corp/` | Centrally owned Odoo, gated by `appsEnabled`. External applications do not belong here. |
| `k8s/addons/` | The root Argo CD Application and optional/manual Descheduler resources. Keep manual Job creation separate from ordinary reconciliation. |
| `k8s/files/` | Runtime programs embedded in chart ConfigMaps: Kafka startup and node fencing. |
| `k8s/templates/` | Helm rendering and opt-in HA resources. |
| `k8s/charts/` | Pinned, vendored dependency charts used for offline rendering and bootstrap. |
| `k8s/profiles/` | Two small migration guards for installed root Applications that still reference retired image profiles. |
| `scripts/` | Installation, configuration, rendering, maintenance and validation commands. |
| `scripts/lib/` | Shared shell/Python libraries used by those commands. |
| `tests/` | The small set of deployment safety exceptions listed below. |

Keep this layout shallow. Use the existing responsibility before adding a new
directory; group related Kubernetes resources in a service manifest. The chart
retains Helm's [standard chart structure](https://helm.sh/docs/topics/charts/#the-chart-file-structure).
The ownership boundaries and declarative source follow Kubernetes'
[configuration guidance](https://kubernetes.io/blog/2025/11/25/configuration-good-practices/).

## Change the owning source

- **Defaults and installed Helm releases:** edit `config/platform.env` and the
  relevant values file. `scripts/reconcile-platform-release.sh` owns shared Helm
  operations; `scripts/configure-ingress.sh` owns ingress. Both installation
  entry points call these helpers. Keep ordered inventories in `platform.env`.
- **Platform workloads:** edit the appropriate `k8s/` manifest or template.
  Shared application services remain present when Odoo is disabled. Installer
  and GitOps rendering must agree on resource identity and configuration.
- **Host setup:** change a helper in `scripts/` and its inputs in `config/host/`.
  Update remote enrollment transfers when changing files copied to new nodes.
- **Repository onboarding:** `add-repos.sh` collects operator inputs and calls
  `scripts/onboard-repositories.py`; `scripts/lib/` implements the app contract.
  `scripts/lib/application_delivery.py` reconciles project runners and their
  Kubernetes permissions from the registered environment inventory.
  `configure-repository-sync.sh` configures ongoing synchronization for one
  repository and remains a separate internal step.
- **Image versions:** update the owning manifest and Helm values;
  follow [image updates](maintenance.md#image-updates) when replacing a
  service with a compatible upstream release. No private platform image
  registry or profile selection is needed.

Render into a new or empty private temporary directory outside the checkout;
the renderer rejects reused output to prevent stale manifests. Its `k8s/ha/`
directory is generated output for installer-only HA resource delivery, not a
source directory. Credentials, recovery state, scans, logs and build output stay
outside Git. Do not add another copy of generated manifests or upstream source.

## Validation policy

Run `./scripts/validate-repository.sh` before submitting changes. It checks actual
source inputs and rendered deployment output, then runs only these safety suites:

| Retained suite | Failure it guards against |
| --- | --- |
| `test-k3s-backups.sh` | Unrestorable archives, stale SQLite backups after etcd migration, and missing recovery tokens. |
| `test-postgres-ha.py` | Data or role loss, unverified cutover, and restarting an obsolete writer. Includes an optional isolated SQL restore drill. |
| `test-kafka-ha.py` | Migration before preparation, incomplete replication and unsafe quorum changes. |
| `test-vault-unseal.py` | Recovery keys leaking into process arguments and false unseal success. |
| `test-vault-ha.py` | Unsafe peer replacement, loss of recovery access and distributing keys to the wrong host. |
| `test-node-fencing.py` | Powering off a healthy/wrong host or recovering storage before confirmed fencing. |
| `test-application-clusters.py` | Wrong cluster/namespace identity, unsafe shared-cluster ingress, and unverified remote gateway access. |
| `test-application-data.py` | Cross-environment data access, anonymous remote cache access and unsafe database adoption; optional disposable datastore checks. |
| `test-environment-onboarding.py` | Wrong-target publication, runner privilege crossover, credential leakage and accepting a certificate that does not cover an environment hostname. |

Do not restore broad application, UI, source-text assertion or per-image test
frameworks here. New tests need a concrete deployment or recovery failure that
syntax, manifest policy and rendering cannot detect. Image promotion still
requires isolated runtime and recovery checks; cluster availability still
requires the documented host-failure drills. See [validation](operations.md#validation) for commands and coverage, and
[maintenance](maintenance.md#image-updates) for image promotion.

## Documentation ownership

The README is the entry point; each guide owns one workflow or reference.
Put a procedure or input table in that guide and link to its heading from other
pages. Keep prerequisites beside the step that needs them. Link configuration
values to their source rather than copying inventories into several guides.
Historical audits, execution receipts and generated output stay outside Git.
