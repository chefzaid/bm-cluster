# Operations

Run cluster commands from a configured control-plane shell. Start with the
[service directory](../README.md#services-and-urls) for dashboards and
[delivery](delivery.md) for GitOps reconciliation.

## Cluster status

```bash
kubectl get nodes
kubectl get pods -A
kubectl get applications -n infra
kubectl get ingress -A
kubectl get pvc -A
kubectl get externalsecrets -A
```

Investigate unhealthy workloads through their events and logs, then update the
owning repository. Platform resources belong here; application resources belong
to the application repository.

## Observability

The platform discovers workloads without a central application inventory:

| Signal | Application contract | Where to inspect it |
|---|---|---|
| Metrics | Pod annotations `prometheus.io/scrape`, `prometheus.io/path`, and `prometheus.io/port` | Prometheus and Grafana's Applications Namespace Overview |
| Custom dashboards | ConfigMaps labeled `grafana_dashboard: "1"` | Grafana |
| Container logs | Write to stdout/stderr; use a Kubernetes `app` label | Kibana's Applications Namespace Logs |
| Source analysis | App-owned scanner configuration and CI jobs | [Sonar discovery](sonar-discovery.md) |

Fluent Bit collects container logs and adds Kubernetes metadata; records from
`apps` receive `observability_scope=application`. Filebeat ships host Lynis
records through Logstash to the Lynis Security Audits dashboard. Prometheus
alerts cover capacity, workload health, jobs, storage, and scrape failures.
Alertmanager sends firing and resolved events to the infrastructure project's
**Monitor > Alerts** page in GitLab.

Trivy Operator discovers workloads across namespaces and maintains image/SBOM,
configuration, RBAC, exposed-secret, infrastructure, and compliance reports.
Use current reports or Grafana's Trivy Security Reports dashboard when reviewing
findings; committed scan snapshots become stale. Secret findings contain
metadata, not the discovered secret values.

```bash
kubectl get vulnerabilityreports,configauditreports,exposedsecretreports -A
```

App repositories own their metrics endpoints, log format, and detailed
dashboards. Shared discovery and dashboards are maintained in
[monitoring.yaml](../k8s/platform/monitoring.yaml),
[observability-discovery.yaml](../k8s/platform/observability-discovery.yaml), and
[trivy.yaml](../k8s/platform/trivy.yaml); scanner settings live in
[values.yaml](../k8s/values.yaml).

## Storage and retention

Review physical host usage alongside filesystem usage inside each PVC. A
volume's requested capacity is not its physical disk usage. Reducing a capacity
request does not reclaim deleted-file blocks; reclaim unused data and trim the
filesystem through Longhorn.

The recurring trim in
[longhorn-maintenance.yaml](../k8s/platform/longhorn-maintenance.yaml) processes
one volume at a time in the `default` and `bm-cluster` groups. Detached volumes
are skipped while `allow-recurring-job-while-volume-detached` is disabled.
Keep `remove-snapshots-during-filesystem-trim=false` and per-volume
`unmapMarkSnapChainRemoved` set to `ignored` or `disabled` to preserve snapshots.
Delete and purge obsolete snapshots separately through Longhorn, then trim;
never delete replica files directly.

Retention is declared with the component that owns the data:

| Data | Configuration |
|---|---|
| Container and application logs | [logging-agent.yaml](../k8s/platform/logging-agent.yaml), Elasticsearch ILM policy |
| Lynis audit indices | [elk.yaml](../k8s/platform/elk.yaml), separate ILM policy |
| Shared Prometheus metrics | [monitoring.yaml](../k8s/platform/monitoring.yaml), time and size limits |
| GitLab's internal metrics | [gitlab.yaml](../k8s/platform/gitlab.yaml), embedded Prometheus flags |
| Images, packages, and CI artifacts | [Delivery retention](delivery.md#storage-and-retention) |

Read the configured values before changing retention. Update existing ILM
policies in place so already managed indices receive the change. GitLab's
embedded Prometheus expires its own blocks after a normal configuration rollout.
During log maintenance, remove only closed, processed archives outside the
chosen retention window; preserve current logs, unprocessed `.u` files, and
audit records. Use GitLab's supported cleanup paths for registry and artifact
data so references remain consistent.

## Backups and recovery

[configure-k3s-backups.sh](../scripts/configure-k3s-backups.sh) installs the
backup timer and optional off-node storage. The root-only archives under
`/var/backups/bm-cluster/k3s` include a SQLite backup or embedded-etcd snapshot,
server credentials, K3s configuration, and available Vault/shared-database
backups. [backup-k3s.sh](../scripts/backup-k3s.sh) defines the contents and
retention; inspect the archive and service result when verifying coverage.

```bash
sudo systemctl status bm-k3s-backup.timer
sudo systemctl start bm-k3s-backup.service
sudo journalctl -u bm-k3s-backup.service --since today
```

When configured, restic encrypts and uploads archives to S3-compatible storage.
Longhorn backs up enrolled volumes to the same private bucket, and the host
backup enrolls newly created volumes. Credentials are stored root-only in
`/etc/bm-cluster/backup.env` and the Longhorn credential Secret. Keep the recovery
password available off-host; local archives cannot survive loss of the host.

Follow the archive's datastore-specific `RESTORE.txt` and the
[Vault recovery guide](vault.md). Restore SQLite with K3s stopped; embedded-etcd
recovery restores the first server with its original token before other servers
rejoin. Verify application data as well as Kubernetes readiness after a restore.

## Workload rebalancing

The Descheduler can be triggered manually:

```bash
kubectl create -f k8s/addons/descheduler-run-job.yaml
kubectl get jobs -n infra -l app=descheduler -w
```

## Validation

Run from the repository root before changing installation or deployment behavior:

```bash
./scripts/validate-repository.sh
./scripts/validate-repository.sh --live
```

The second command adds Kubernetes server-side dry-runs without changing cluster
resources. Checks cover shared contracts, shell code, Ansible, manifests,
immutable images, and hostname inventories. Behavioral fixtures require Bash,
jq, SQLite's `sqlite3` CLI, and `flock`; CI installs them automatically.
See [delivery](delivery.md) for the additional default-branch deployment checks.
