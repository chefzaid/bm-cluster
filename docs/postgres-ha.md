# PostgreSQL HA profile

This opt-in profile replaces one PostgreSQL writer with a CloudNativePG primary
and two synchronous standbys on three different hosts. It is for a cluster with
at least three Ready control planes and three schedulable storage hosts. The
current single-node installation keeps its existing Deployment and PVC until an
explicit migration. Merely enabling general cluster HA does not migrate data.

[postgres-ha-values.yaml](../config/postgres-ha-values.yaml) defines the database profile;
[postgres-ha-operator-values.yaml](../config/postgres-ha-operator-values.yaml) defines the
separate operator release. The helper installs the pinned chart from the
[official repository](https://github.com/cloudnative-pg/charts). The public
PostgreSQL image retains Debian Bookworm and PostgreSQL's major version; the
operator injects its instance manager. Do not substitute a standard image
without validating its tools, locales, extensions and operator compatibility.

`postgresHa.enabled=true, active=false` stages the new cluster with application
TCP access rejected. `active=true` selects the current CNPG primary through the
existing `infra/postgres` Service and sets the original Deployment to zero.
The original `postgres-v18-pvc`, ConfigMaps and Service identity are retained.
The CNPG Cluster has pruning/deletion protection; removing the profile is not a
database migration or a PVC cleanup procedure.

The cluster uses synchronous `ANY 1` with required durability, failover quorum,
primary isolation checks, strict hostname anti-affinity and operator-managed
PodDisruptionBudgets. The operator also has three instances and a PDB. Writes
wait when no synchronous standby is available. This protects acknowledged
commits during a supported single-host failure; clients must still reconnect
during failover. Three PVCs retain the configured per-instance capacity. With
three Longhorn replicas per PVC, this can require nine physical copies of the
database: check actual free capacity and rebuild headroom on every host.

## Prepare

Run from this repository with Python 3, PyYAML, Helm, and an administrator
`kubectl` context. The existing `postgres-secret` must already be supplied by
Vault/External Secrets. Neither its username nor its password is regenerated.
Use a private durable state directory with enough free space for all dumps;
keep it outside Git and include it in encrypted offsite backups.

```bash
export HIGH_AVAILABILITY_ENABLED=true
STATE_DIR=/var/backups/bm-cluster/postgres-ha-migration
sudo install -d -m 0700 -o "$(id -u)" -g "$(id -g)" "$STATE_DIR"
python3 scripts/configure-postgres-ha.py prepare --state-dir "$STATE_DIR"
```

Preparation installs CloudNativePG into `cnpg-system`, creates the bootstrap
Secret from the existing credentials, and applies only the dedicated PG HA
template. It waits for three Ready database instances on different hosts and
both streaming standbys. Retain its generated `staged-values.yaml` alongside
the private migration journal. Keep routine reconciliation paused while using
that staged profile; normal installer/Ansible reconciliation refuses unfinished
migration checkpoints. Resume with the full active `PLATFORM_HA_VALUES_FILE`
only after verified cutover.

For a completely fresh installation, run `fresh` after preparation, before
creating the legacy PostgreSQL Deployment/PVC or starting database clients:

```bash
python3 scripts/configure-postgres-ha.py fresh --state-dir "$STATE_DIR"
```

This retains the existing administrator privileges and initial `keycloak`
database contract. Fresh mode refuses any existing original Deployment/PVC.
Continue with the cutover instructions below. Application-specific database
provisioning runs afterward, against the canonical primary.

## Existing database migration

Schedule downtime. Pause automatic sync for every Argo Application in `infra`,
wait for current sync operations to finish, and stop application writers and
scheduled jobs. The helper checks the GitOps maintenance gate, rejects new TCP
connections in the source's persistent `pg_hba.conf`, and terminates existing
client sessions. It keeps local access for backup and recovery. It does not
rely on a NetworkPolicy to close established connections.

```bash
python3 scripts/configure-postgres-ha.py migrate \
  --state-dir "$STATE_DIR" --maintenance
```

The helper preserves all original role names, attributes, password hashes,
database owners, memberships and their options, ACLs, role/database settings,
schemas, table contents, large objects and sequence state. One documented
authority mapping is necessary: grants made by the original initdb bootstrap
superuser are recorded as granted by CNPG's bootstrap `postgres` role. The
original administrator remains a superuser with the same credentials; all
grant recipients and permission options are preserved. The exact mapping and
comparisons stay in the private state directory.

The helper fails before fencing for unsupported layouts: CNPG-reserved source
role names, non-default tablespaces, non-connectable databases, older password
hashes needing a SCRAM migration, active subscriptions, existing replication
slots, foreign tables, prepared transactions,
or a PostgreSQL downgrade. Review custom background workers/extensions and
stop their writers first. Do not use this helper to copy a database with an
independent background writer. User-defined changes to template databases need
a separate migration plan.

Each database gets a custom-format dump plus a shared globals dump. The helper
checks the source again after dumping, restores into the isolated target, and
compares inventories before generating `active-values.yaml`. All dumps,
password hashes and command errors remain private. No command uploads them or
deletes the original PVC.

## Cut over and recover

Review the generated active profile and store its full `postgresHa` map in the
platform's persistent Helm values. Keep automatic Argo sync paused until the
cutover completes; do not apply the active profile early. Then run:

```bash
python3 scripts/configure-postgres-ha.py cutover --state-dir "$STATE_DIR" \
  --maintenance --desired-values /path/to/reviewed-platform-ha-values.yaml
```

Cutover repeats verification, stops the old Deployment, switches the existing
Service selector, and permits application connections on CNPG. It records the
full non-secret profile in `infra/postgres-ha-state` (`data.postgresHa`) with
`data.phase=active`. A partial cutover records `cutover-started`; installers must
stop rather than guess which copy should serve traffic. Reconcile the reviewed
GitOps profile, resume writers, and verify application authentication and
health. Routine backups and password rotation resolve the canonical Service's
current primary, including after failover.

For the complete platform migration, continue with
[the ordered HA workflow](high-availability.md#activate-in-order) before running
the general installer. If activating PostgreSQL alone on a platform that has
not yet enabled global HA, unset `HIGH_AVAILABILITY_ENABLED` after the helper
finishes and retain the active `PLATFORM_HA_VALUES_FILE` for reconciliation.
The general HA switch also requires the completed Kafka migration; it is not
needed to retain a verified PostgreSQL cutover.

Before cutover, a failed import leaves the original database fenced and the
target isolated. To reconnect the original during the same maintenance window:

```bash
python3 scripts/configure-postgres-ha.py abort --state-dir "$STATE_DIR" --maintenance
```

Abort restores the saved source HBA, removes only its own migration checkpoint
ConfigMap, and keeps all database copies and backups. Restore the previous
persistent platform profile before resuming ordinary reconciliation. Inspect
any failed target separately before starting a new migration. After cutover,
never restart the old writer as a rollback: it no longer contains new commits.
Recover the HA cluster or perform a new, verified reverse migration. If cutover
stops partway, inspect the private journal, Service selector, Cluster policy and
old Deployment before completing the already-started cutover manually.

HA replicas do not replace backups. Keep the existing encrypted offsite backup
policy and test restoration; this profile does not configure continuous WAL
archiving. A multi-host operator failover drill is required when the extra
hosts become available. The isolated SQL canary validates migration semantics,
not a real three-node failure.

```bash
python3 scripts/test-postgres-ha.py
bash scripts/test-postgres-access.sh
# After explicitly pulling the profile's pinned public image:
python3 scripts/test-postgres-ha.py --docker
```

See the upstream guidance on [synchronous replication](https://cloudnative-pg.io/docs/1.30/replication/),
[primary election and isolation](https://cloudnative-pg.io/docs/1.30/failover/),
[scheduling](https://cloudnative-pg.io/docs/1.30/scheduling/),
and [logical import limitations](https://cloudnative-pg.io/docs/1.30/database_import/).
