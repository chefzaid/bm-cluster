# Operations

Run cluster commands from a configured control-plane shell. Start with the
[service directory](#services-and-urls) for dashboards and
[delivery](delivery.md) for GitOps reconciliation.

## Services and URLs

Homepage at `https://intranet.<your-domain>` is the service directory, including
internal components and application-owned entries. Replace `<your-domain>`
below with the domain supplied during installation. Administrative UIs
use the access controls described in [security and identity](security.md).

| Service | URL | Purpose |
|---|---|---|
| Odoo | `https://odoo.<your-domain>` | ERP and CRM |
| Homepage | `https://intranet.<your-domain>` | Service catalog and cluster status |
| GitLab | `https://gitlab.<your-domain>` | Source, CI, artifacts, and packages |
| Container Registry | `https://registry.<your-domain>/v2/` | OCI image API; browse images in GitLab |
| Argo CD | `https://argocd.<your-domain>` | GitOps delivery |
| SonarQube | `https://sonarqube.<your-domain>` | Source quality analysis |
| Grafana | `https://grafana.<your-domain>` | Metrics and security dashboards |
| Kibana | `https://kibana.<your-domain>` | Logs and audit dashboards |
| Keycloak | `https://keycloak.<your-domain>/auth/admin/master/console/` | Identity administration |
| Vault | `https://vault.<your-domain>` | Secrets and policies |
| Longhorn | `https://longhorn.<your-domain>` | Volumes, snapshots, and backups |
| Portainer | `https://portainer.<your-domain>` | Kubernetes management |
| DBGate | `https://dbgate.<your-domain>` | PostgreSQL, MongoDB, and Redis administration |
| Kafbat UI | `https://kafka.<your-domain>` | Kafka administration |
| Trivy reports | `https://grafana.<your-domain>/d/trivy-security/trivy-security-reports` | Current workload and cluster findings |
| Lynis reports | `https://kibana.<your-domain>/app/dashboards#/view/lynis-security-audits` | Host audit history |

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

Use [observability](observability.md) for platform alerts, application dashboards,
logs, security findings and source analysis. It owns discovery requirements and
troubleshooting; app repositories own their endpoints, log formats and custom dashboards.

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
If allocation remains high after deletion, compare replica allocation with live
filesystem usage. A filesystem can remember previous trim requests; reclaiming
those blocks may require a planned workload stop, verified unmount, restart and
another trim. Follow [Longhorn's trim guidance](https://longhorn.io/docs/1.12.1/nodes-and-volumes/volumes/trim-filesystem/)
and preserve a verified recovery copy before that interruption.

Retention is declared with the component that owns the data:

| Data | Configuration |
|---|---|
| Container and application logs | [logging-agent.yaml](../k8s/platform/logging-agent.yaml), Elasticsearch ILM policy |
| Lynis audit indices | [elk.yaml](../k8s/platform/elk.yaml), separate ILM policy |
| Shared Prometheus metrics | [monitoring.yaml](../k8s/platform/monitoring.yaml), time and size limits |
| GitLab's internal metrics | [gitlab.yaml](../k8s/platform/gitlab.yaml), embedded Prometheus flags |
| Images and packages | [GitLab retention job](../k8s/platform/gitlab-registry-retention.yaml) |
| CI artifacts | Each application's pipeline retention settings |

Read the configured values before changing retention. Update existing ILM
policies in place so already managed indices receive the change. GitLab's
embedded Prometheus expires its own blocks after a normal configuration rollout.
During log maintenance, remove only closed, processed archives outside the
chosen retention window; preserve current logs, unprocessed `.u` files, and
audit records. Use GitLab's supported cleanup paths for registry and artifact
data so references remain consistent.

### GitLab storage

Repositories, Registry data, packages and artifacts share the `gitlab-data` PVC
in [gitlab.yaml](../k8s/platform/gitlab.yaml). The daily retention job reconciles
native container-tag cleanup for the configured group and subgroups, and removes
Package Registry versions older than its declared retention period. GitLab
preserves protected tags and `latest`. The job's token comes from Vault
`secret/infra/gitlab` through External Secrets.

Deleting tags and packages does not itself reclaim physical Registry storage.
Use supported GitLab cleanup procedures; keep [recovery images](maintenance.md#runtime-and-recovery-constraints)
before removing old data. Increasing PVC capacity is separate from cleanup.

## Backups and recovery

[configure-k3s-backups.sh](../scripts/configure-k3s-backups.sh) installs the
backup timer and optional off-node storage. The root-only archives under
`/var/backups/bm-cluster/k3s` include a SQLite backup or embedded-etcd snapshot,
server credentials, K3s configuration, and available Vault/shared-database
backups. [backup-k3s.sh](../scripts/backup-k3s.sh) defines the contents and
retention; inspect the archive and service result when verifying coverage.

GitLab needs its own native data backup plus matching configuration and secrets.
For a Registry using the metadata database, verify that the backup also contains
`db/registry_database.sql.gz`, or pair it with a verified PostgreSQL dump from the
same write/GC freeze as the Registry files. `registry.tar.gz` alone does not cover
that database. Check the installed [Registry backup configuration](https://docs.gitlab.com/omnibus/settings/backups/)
and archive contents; a successful backup exit status does not establish complete
coverage. Verify the replacement before rotating older recovery archives.

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

The first command is offline and requires Bash, Git, ShellCheck, Python 3 with
PyYAML, Helm, Ansible, Node.js, jq, SQLite's `sqlite3` CLI, and `flock`. CI installs
these tools. Missing dependencies fail validation rather than silently skipping
deployment checks. It checks syntax, documentation links, manifest inventories,
workload policy and platform-owned image digests. Nine installer/GitOps render
combinations cover HA, Odoo scope, PostgreSQL staging/cutover,
Kafka migration phases, fencing and authenticated shared application data. Each render checks resource references,
Service selectors and named ports, Ingress backends, RBAC and installer/GitOps
parity, then the command runs the [deployment and recovery safety suites](structure.md#validation-policy).

The second command adds server-side dry-runs of the rendered profiles, including
the opted-in database migration and fencing resources, against the active
Kubernetes context.
It requires kubectl, access to the API and the platform CRDs; it does not install
resources. Synthetic `example.com` settings validate API compatibility, not the
live installation's credentials, routing or health. Generated files are private
and removed on exit.

Syntax and rendering cannot establish successful installation, image runtime
compatibility or failover. Rehearse installer/enrollment changes on disposable
hosts and follow each service's upgrade/recovery guide. See [delivery](delivery.md)
for the additional default-branch reconciliation and service checks.

Rehearse host provisioning, Longhorn recovery, physical fencing, Tunnel failover
and production authentication in a representative environment before relying on
them. A synthetic upstream restore does not establish compatibility with existing
data; use protected copies of the actual backups for [migration rehearsal](platform-migration.md#prepare-and-rehearse).
