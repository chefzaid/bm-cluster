# Automatic application dashboards

Every workload deployed in `apps` is discovered automatically. Grafana gets an
**Applications / <application>** dashboard in the **Applications** folder;
Kibana gets **Applications / <application> / Logs**. The Grafana dashboard links
to its Kibana counterpart. No application-name inventory or dashboard manifest
is required in the application repository.

The discovery sidecar in Grafana lists workloads on startup and every 60 seconds.
Grafana loads changed dashboard files within its 30-second provisioning interval.
Kibana saved objects are imported immediately for new or changed applications
and reconciled every five minutes. Discovery retries API failures; Kibana
outages do not prevent Grafana dashboard generation.

## Application identity

Discovery follows Pod, ReplicaSet and Job controller ownership back to
Deployments, StatefulSets, DaemonSets, CronJobs and standalone Jobs or Pods.
Scaled-to-zero controllers are included. Only resources in `apps` are read;
`infra`, `corp` and other environments are outside this discovery scope.

Components are grouped by the first available identity:

1. A valid Argo CD tracking annotation belonging to that resource.
2. `app.kubernetes.io/part-of`.
3. `app.kubernetes.io/instance`.
4. `app.kubernetes.io/name`.
5. `app`.
6. The controller kind/name, or the standalone Pod kind/name.

Both controller metadata and pod-template labels are supported. Standard
controllers use pod-name patterns that cover rolling updates and future Jobs;
custom-controller or orphaned pods use their observed names. Namespace and pod
filters scope every panel to the discovered application. Different identity
sources with the same display name have separate stable dashboard IDs.
For components installed without Argo CD, use the same `app.kubernetes.io/part-of`
label when they should share a dashboard.

## Metrics and logs

CPU, memory, network traffic, pod readiness and container restarts come from
the existing cAdvisor and kube-state-metrics collection. They work without an
application metrics endpoint or an `app` label.

Prometheus already discovers application metrics from pod annotations:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/path: /metrics
    prometheus.io/port: "8080"
```

These belong on the **pod template**, and the application must actually expose
the selected endpoint and permit Prometheus to reach it. The generated dashboard
shows endpoint health and scrape duration. An absent endpoint produces **No data**
in those panels. Discovery cannot infer business metrics or instrument an
application; app-owned dashboards can add HTTP, JVM or other detailed metrics.
Existing `grafana_dashboard: "1"` ConfigMaps remain supported independently.

Fluent Bit already collects stdout/stderr with Kubernetes namespace, pod and
container metadata. The generated Kibana data view uses `kubernetes-logs-v2-*`,
with application filters on the saved search and both visualizations as well as
the dashboard. It shows log volume, logs by container, and searchable messages
even without an application label or structured severity. Existing ingestion
and retention policies still apply. Dashboard filters organize data; they do
not replace service access controls.

## Ownership and retention

The platform manages the generated dashboards. Clone one before customizing it:
Kibana reconciliation overwrites managed saved objects, and Grafana loads its
managed dashboards from files. Stable IDs survive pod rollouts and restarts.
Removing an application does not delete its dashboards or historical logs;
Grafana provisioning disables deletion for this provider, and discovery does
not delete Kibana objects. A returning application with the same identity gets
its dashboards updated in place.

The sidecar has read-only workload-list permissions in `apps`, uses Grafana's
existing shared dashboard volume, and receives the existing Vault-backed
`kibana-bootstrap-credentials` Secret for saved-object administration. It does
not read application Secrets, change workloads, or require a Grafana API token.

## Operation and validation

```sh
kubectl -n infra logs deployment/grafana -c application-discovery --tail=30
kubectl -n infra exec deployment/grafana -c application-discovery -- \
  node /application-discovery/discovery.mjs --once
./scripts/validate-repository.sh --live
```

The one-shot command reports failures through its exit status. The normal loop
logs application counts and errors and retries automatically. After changing
the JavaScript ConfigMap, restart the Grafana Deployment to load the new module;
ordinary workload changes need no restart.

[application-observability.yaml](../k8s/platform/application-observability.yaml)
owns discovery and its namespaced RBAC. [monitoring.yaml](../k8s/platform/monitoring.yaml)
owns the sidecar and Grafana provider. After a discovery change, use a disposable
application to verify namespace/ownership boundaries, dashboard links and an
idempotent second pass. Repository validation checks the manifests and embedded
script syntax.

The implementation uses Grafana's [file provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
and Kibana's [saved-object import API](https://www.elastic.co/docs/api/doc/kibana/operation/operation-importsavedobjectsdefault).
