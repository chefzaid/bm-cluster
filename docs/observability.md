# Observability

Use Grafana for metrics, Kibana for logs and audits, and SonarQube for source
analysis. The [service directory](operations.md#services-and-urls) lists their
URLs. Applications own instrumentation and scanner jobs; the platform owns
collection, discovery and shared dashboards on the platform cluster.

## Namespace and discovery

The automatic collection and discovery described here cover workloads on the
platform cluster. Existing version 1 onboarding places those workloads in
**`apps`** and their Argo CD Applications in **`infra`**, targeting that cluster:

```yaml
metadata:
  namespace: infra
spec:
  destination:
    server: https://kubernetes.default.svc
    namespace: apps
```

Set `namespace: apps` in the app's Kustomization or rendered Helm/plain manifests
too. With the shared services configured, discovery includes Deployments,
StatefulSets, DaemonSets, CronJobs and standalone Jobs/Pods, including controllers
scaled to zero. It excludes `infra`, `corp` (including Odoo) and other environments.
No central application inventory is required.

Version 2 onboarding targets separate `int`, `uat` and `prod` application
clusters through central Argo CD. Their minimal foundation does not install
metrics/log collectors or connect remote workloads to central dashboard and
scheduled Sonar discovery. Those integrations need separate configuration;
application CI still submits its Sonar analysis. See
[application deployment clusters](installation.md#application-deployment-clusters).
Until telemetry is connected, use target-cluster logs and the application's
delivery health checks; central dashboards do not establish target health.

| Signal | Automatic result | Application requirement |
|---|---|---|
| Runtime metrics | Grafana **Applications / <application>** | Baseline metrics need no app endpoint; add [scrape annotations](#metrics-and-logs) for endpoint metrics. |
| Container logs | Kibana **Applications / <application> / Logs** | Write logs to stdout/stderr. |
| Source analysis | Sonar project and scheduled analyses | Argo CD tracking must identify a repository in the configured GitLab hosts/group; implement the [scanner contract](#scanner-contract). |

Dashboard identity can fall back to workload labels. Sonar requires the Argo CD
source mapping and deduplicates components from the same repository. Namespace
placement alone cannot instrument an app or configure its scanner.

## Platform health

Prometheus alerts cover capacity, workload health, jobs, storage and scrape
failures. Alertmanager sends firing and resolved events to the infrastructure
project's **Monitor > Alerts** page in GitLab. GitLab and runner metrics appear
in Grafana's **GitLab Delivery** dashboard.

Fluent Bit adds Kubernetes metadata to container logs; records from `apps` carry
`observability_scope=application`. Filebeat sends host Lynis records through
Logstash to Kibana's **Lynis Security Audits** dashboard. See
[storage and retention](operations.md#storage-and-retention) for retention settings.

Trivy Operator scans across namespaces and maintains image/SBOM, configuration,
RBAC, exposed-secret, infrastructure and compliance reports. Review current
reports or Grafana's **Trivy Security Reports** dashboard; secret findings contain
metadata rather than secret values.

```bash
kubectl get vulnerabilityreports,configauditreports,exposedsecretreports -A
```

For private application images, declare credentials through workload or
ServiceAccount `imagePullSecrets` in the application namespace. Trivy uses those
references; the application owns provisioning and rotation. Public platform
images need no fallback credentials. Shared configuration lives in
[monitoring.yaml](../k8s/platform/monitoring.yaml),
[observability-discovery.yaml](../k8s/platform/observability-discovery.yaml),
[trivy.yaml](../k8s/platform/trivy.yaml) and the scanner settings in
[values.yaml](../k8s/values.yaml).

## Application dashboards

The Grafana discovery sidecar refreshes workloads on startup and every minute.
Grafana loads changed files within its 30-second provisioning interval. Kibana
objects are imported when an application changes and reconciled every five
minutes. API failures are retried; a Kibana outage does not block Grafana.

### Application identity

Discovery follows Pod, ReplicaSet and Job ownership to their root controller.
It groups components by the first available identity, using controller metadata
and pod-template labels:

1. A valid Argo CD tracking annotation belonging to that resource.
2. `app.kubernetes.io/part-of`.
3. `app.kubernetes.io/instance`.
4. `app.kubernetes.io/name`.
5. `app`.
6. Controller kind/name, or standalone Pod kind/name.

Use a shared `app.kubernetes.io/part-of` label to group components deployed without
Argo CD. Standard controllers use pod-name patterns covering rollouts and future
Jobs; custom-controller and orphaned pods use observed names. Namespace and pod
filters scope every panel. Different identity sources with the same display name
get separate stable dashboard IDs.

### Metrics and logs

CPU, memory, network traffic, readiness and restarts use cAdvisor and
kube-state-metrics; they need neither an app metrics endpoint nor an `app` label.
For endpoint metrics, annotate the **pod template** and expose a reachable endpoint:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/path: /metrics
    prometheus.io/port: "8080"
```

Generated dashboards show endpoint health and scrape duration. **No data** means
no metric series, not a healthy endpoint. Apps own business, HTTP, JVM and other
detailed instrumentation; additional ConfigMaps labeled
`grafana_dashboard: "1"` remain supported.

Each Grafana dashboard links to its Kibana counterpart. The Kibana data view uses
`kubernetes-logs-v2-*`; the saved search, both visualizations and dashboard all
carry application filters. Log volume, logs by container and searchable messages
work without an app label or structured severity. Filters organize data and do
not replace access controls.

### Ownership and troubleshooting

Clone a generated dashboard before customizing it: Grafana provisions managed
files, and Kibana reconciliation overwrites managed objects. Stable IDs survive
rollouts. Removing a workload retains its dashboards and historical logs under
the normal retention policy; returning applications update the same IDs.

The sidecar has read-only workload access in `apps`, shares Grafana's dashboard
volume and uses the Vault-backed `kibana-bootstrap-credentials` Secret. It needs
no Grafana API token and cannot read app Secrets or change workloads.

```bash
kubectl -n infra logs deployment/grafana -c application-discovery --tail=30
kubectl -n infra exec deployment/grafana -c application-discovery -- \
  node /application-discovery/discovery.mjs --once
```

The one-shot command exits nonzero on failure; the normal loop logs counts/errors
and retries. Restart Grafana after changing the JavaScript ConfigMap, but not for
ordinary workload changes. Discovery/RBAC live in
[application-observability.yaml](../k8s/platform/application-observability.yaml);
the sidecar and provisioning provider live in `monitoring.yaml`.

## Source analysis

Application CI owns compilation, coverage and scanner submission. Discovery
provisions projects, binds them to `SONAR_ALM_SETTING` and creates a protected,
masked project `SONAR_TOKEN` when absent. Non-public GitLab repositories receive
private Sonar projects. Trivy scanning is independent.

| Trigger | Behavior |
|---|---|
| Default-branch CI | The app's quality job runs with its normal pipeline. |
| Discovery, every 15 minutes | Requests analysis when none exists or the latest is over 24 hours old. |
| Manual analysis | Run a default-branch GitLab pipeline with `SONAR_SCAN_ONLY=true`, or use the app's documented manual/local scanner. |

Discovery requests at most one pipeline per pass, defers while a discovered app
has an active default-branch pipeline, and waits six hours after a recent
API-triggered pipeline before retrying. Any successful analysis satisfies the
freshness target; it is not an exact daily schedule.

### Scanner contract

Each application repository must provide:

- `sonar-project.properties` with `sonar.projectKey=<group>:<repository>` (replace
  every GitLab path slash with a colon), all backend/frontend/shared sources,
  required compiled inputs and coverage paths.
- `.sonar-auto.json`, using the actual quality job name:

  ```json
  {"version":1,"job":"sonar","scanOnlyVariable":"SONAR_SCAN_ONLY"}
  ```

- Default-branch CI rules that run only needed compilation, tests/coverage and
  analysis when `SONAR_SCAN_ONLY=true`. Exclude image builds, release packaging,
  publication, deployment and version changes.
- A protected default branch so the quality job receives `SONAR_TOKEN`. Scanner
  submission failures must be visible; quality findings may be non-blocking for
  delivery.

Missing contracts, unmapped workloads and unsupported sources fail the discovery
Job while valid repositories continue. A project can be provisioned without a
working scanner contract. Check its source inventory to confirm backend and
frontend coverage; each app documents its inventory and manual scan commands.

### Credentials and troubleshooting

[configure-sonar-discovery.sh](../scripts/configure-sonar-discovery.sh), called by
`configure-gitlab-ci.sh`, manages a GitLab group Maintainer API token at Vault
`secret/infra/gitlab:sonar_discovery_api_token`. External Secrets projects it into
`infra`; Sonar administration uses its existing Vault-backed admin token. The
configurator also sets the named GitLab integration and import credential using
the private service domain. Rerun it before expiry: valid credentials are reused
and renewed within the script's renewal window. Discovery does not renew them.

The [discovery CronJob](../k8s/platform/sonar-apps-discovery.yaml) can list workloads
in `apps` and Applications in `infra`, but cannot read app Secrets or corporate
workloads. It has no PVC, checkout or build cache; completed Jobs expire according
to their TTL/history limits.

```bash
kubectl -n infra get cronjob sonar-apps-discovery
kubectl -n infra logs -l app=sonar-apps-discovery --prefix
SONAR_JOB_NAME="sonar-apps-manual-$(date +%s)"
kubectl -n infra create job "$SONAR_JOB_NAME" --from=cronjob/sonar-apps-discovery
kubectl -n infra logs -f "job/$SONAR_JOB_NAME"
```

An immediate discovery pass still obeys freshness/retry rules; use the scan-only
pipeline for an explicit analysis. Inspect its quality job and the Sonar analysis
timestamp: scanner submission precedes server processing, and a failed quality
gate differs from submission failure.

## Validating changes

Run [repository validation](operations.md#validation) for manifests and embedded
script syntax. After discovery changes, use a disposable app to check namespace
and ownership boundaries, dashboard links, an idempotent second pass, the selected
Sonar project, its scan-only pipeline and analysis timestamp. App repositories
validate successful submission, scanner failure, missing-token behavior and CI
with both values of `SONAR_SCAN_ONLY`; scan-only runs must never publish or deploy.
