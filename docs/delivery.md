# Delivery and GitOps

The platform supplies GitLab, an instance runner, registries and Argo CD.
Application repositories own their CI, runtime manifests and Applications.
Use [repository onboarding](repository-onboarding.md) to import or deploy an app;
this guide explains the shared delivery path and how to maintain it.

## Ownership and bootstrap

The [root Application](../k8s/addons/bm-cluster-application.yaml) reconciles the
platform chart, including Odoo when enabled. Each external application has its
own Application and deployment guide. Application runtime changes belong in that
repository; the platform has no application repository inventory.

The installer and [Ansible](installation.md) run
[configure-gitlab-ci.sh](../scripts/configure-gitlab-ci.sh) to reconcile the
configured group/project, Dependency Proxy, retention policies, instance runner
and Vault-backed tokens. Setup creates a temporary GitLab administrator token
through `gitlab-rails` on the control plane and revokes it on exit. No manually
created token is required.

## Pipelines and outputs

### Application delivery

DevApp uses one GitLab project and registry for all environments. In **Build →
Pipelines → New pipeline**, select `PIPELINE_MODE=full` and the destination:

- `int`: select any branch to build and deploy a snapshot, including source
  versions ending in `-SNAPSHOT`. All branches share the integration hostname.
- `uat` or `prod`: select the default branch to publish and deploy a stable
  release, or set `RELEASE_VERSION` to promote a finalized release without rebuilding.

Existing releases can also deploy to `int`. Snapshots cannot deploy to `uat` or
`prod`. Older feature branches must first merge or rebase the updated CI helpers.

```mermaid
flowchart LR
    GitLab["One GitLab project and registry"] --> CI["Choose int / uat / prod"]
    CI --> Pin["Commit selected environment and image digests"]
    Pin --> Argo["One central Argo CD"]
    Argo --> Int["int namespace / cluster"]
    Argo --> Uat["uat namespace / cluster"]
    Argo --> Prod["prod namespace / cluster"]
    Int --> Data["Shared PostgreSQL, Redis, Kafka, Vault and Keycloak"]
    Uat --> Data
    Prod --> Data
```

Each Application (`devapp-int`, `devapp-uat`, `devapp-prod`) uses its own restricted
AppProject, registered cluster/namespace pair and immutable runtime configuration commit.
A second commit records that revision in the selected Application. Updating
shared source or deploying integration therefore does not move the production
pointer. CI verifies destination, revision, deployment health, image digests and
public smoke checks; it never patches workloads directly.

The central `infra/deployment-environments` ConfigMap contains only successfully
registered targets. CI reads this public inventory, without access to
administrator credentials. It rejects missing targets and a changed cluster
binding. Register targets and provision each application's scoped services
through [installation](installation.md#application-deployment-clusters) and
[onboarding](repository-onboarding.md#environment-deployment), then select the
destination in CI. Shared GitLab, registry, Argo CD and identity URLs keep the
platform domain; application hosts follow the configured suffix or nested naming style.

Release/version publication shares one lock because it changes the same branch
and version counter. Deployments use a lock per environment and reject a stale
branch before publication. Snapshot GitOps commits live on a dedicated
`gitops/int/<pipeline-id>` branch and leave the source/default branches and stable
version counter unchanged.

Version 2 onboarding gives each application project its own integration and
protected-release runners on the central platform, and disables shared runners
for that project. Branch jobs can update only their integration Application.
Protected release jobs can update their application's registered environments;
Kubernetes admission rules bind those Applications to their assigned destinations.
Existing version 1 applications keep their current runner configuration.

GitHub/GitLab synchronization still connects one repository pair. Existing
applications retain their own delivery contracts until explicitly migrated;
DevApp is the first environment-aware implementation. See the app's deployment
guide for its job details and the [scanner contract](observability.md#source-analysis)
for analysis-only pipelines. Remote metrics/log shipping requires a collector;
central namespace discovery does not automatically extend to another cluster.

### Infrastructure reconciliation and verification

The [platform pipeline](../.gitlab-ci.yml) and Argo CD act independently:

| Path | Responsibility |
| --- | --- |
| Argo CD | Reconcile `main` into platform resources with automatic sync, prune and self-heal. |
| CI | Run [repository validation](operations.md#validation); on the default branch, verify the same commit is Synced/Healthy and check delivery services and Registry push/read. |

CI observes reconciliation; it does not gate the start of Argo's sync.
The separately installed Argo CD Helm release follows the upgrade procedure below.

## Registry and dependencies

Use the [service DNS and registry routing contract](networking.md#service-dns-and-registry-routing)
for public names, internal CI/containerd routes and the Dependency Proxy. These
machine endpoints must remain usable without browser-only authentication or challenges.

The infrastructure pipeline pins its public Alpine image by digest; the runner's
`IfNotPresent` policy reuses the node-local image. The group Dependency Proxy can
accelerate upstream pulls. Maven/npm use their public upstreams and the persistent
[runner cache](../k8s/platform/gitlab-runner.yaml); app builds may use disposable
Kaniko layers. A cold pipeline must still build, test and release successfully.

[Operations](operations.md#gitlab-storage) owns Registry/package retention and
storage cleanup. [Observability](observability.md) covers delivery metrics and logs.

## Argo CD operations


The installer and `ansible/deploy.yml` install Argo CD through Helm using rendered
[`config/argocd-values.yaml`](../config/argocd-values.yaml) and version pins from
[`config/platform.env`](../config/platform.env). The root Application manages
platform resources after bootstrap; it does not upgrade its own Argo CD Helm
release. Reconcile Helm changes through the installer, Ansible, or a Helm upgrade
with those same rendered inputs and pins.

With `HIGH_AVAILABILITY_ENABLED=true`, the installer and Ansible also apply
[`config/argocd-ha-values.yaml`](../config/argocd-ha-values.yaml). API/repository
servers and ApplicationSet controllers run in pairs on separate hosts. The
disposable Redis cache uses three Sentinel peers with authenticated Redis and
Sentinel connections, two HAProxy endpoints, and disruption budgets.

The application controller remains one active process. The overlay enables
upstream [dynamic cluster distribution](https://argo-cd.readthedocs.io/en/stable/operator-manual/dynamic-cluster-distribution/)
to run it as a Deployment, with 30-second not-ready/unreachable tolerations so
Kubernetes can replace it on a surviving host. With one replica it processes
the whole cluster; there is no second controller acting as a standby. GitOps
reconciliation pauses while the replacement starts and rebuilds its cache.
Upstream marks this mechanism alpha, so check its chart behavior during upgrades.
Existing applications continue running during that pause.

The application controller caches cluster resources. Its `GOMEMLIMIT` is kept
below the container memory limit to leave room for non-Go allocations and
transient work. This is a soft Go runtime limit, not a hard process bound. Keep
the values together in `config/argocd-values.yaml`; see the upstream
[Argo CD memory guidance](https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/#mitigating-oomkilled-events-from-memory-spikes).

After a Helm change, wait for the controller rollout and check that Applications
return to `Synced` and `Healthy`. Confirm `go_gc_gomemlimit_bytes` matches the
configured value and observe restarts, working memory, garbage collection, CPU
and reconciliation duration across startup and normal cycles. If memory pressure
persists, inspect the live heap/cache and adjust both budgets within node capacity.
