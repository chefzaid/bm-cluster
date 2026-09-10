# Kafka high availability

The default Kafka deployment has one static KRaft controller and one broker.
The opt-in profile uses three controllers and three brokers on distinct hosts.
Existing topics, including internal offset/transaction topics, receive three
replicas; writes require at least two in-sync replicas and unclean leader
election is disabled. Producers must use `acks=all`; validate producer settings in each consuming
application before activation.
A majority controller quorum and sufficient broker ISR must remain available.

This is a forward migration using Kafka's native
[dynamic quorum upgrade and controller membership commands](https://kafka.apache.org/43/operations/kraft/).
It does not format a replacement cluster or change existing topic identities.
The original `kafka-controller` and `kafka` StatefulSets, their ordinal-zero
PVCs, controller ID `3000`, broker ID `1`, and verified cluster UUID remain.
Extra controllers use IDs `3001`/`3002`; extra brokers use `2`/`3`.

## Prepare

Follow the host and capacity prerequisites in [high availability](high-availability.md).
Use three Ready control planes and at least three schedulable hosts. Have room
for the new broker data and any Longhorn replica copies. Upgrade the existing
singleton to the repository's pinned compatible Kafka image separately before
changing topology; the helper refuses to combine an image replacement with a
quorum migration.

Take and verify recoverable Kafka metadata and record backups outside these
PVCs. The helper's private journal records manifests, topic assignments and
identities; **it is not a Kafka record backup**. Schedule downtime and stop all
Kafka producers, consumers and topic-management jobs. Pause automatic sync on
all Argo Applications and let in-progress operations finish. Leave them paused
until the final values have been persisted and verified.

Use rendered installation Helm values for `--desired-values`, with the normal
domain, internal DNS, image profile and GitOps inputs. Follow
[installation inputs](installation.md#unattended-installation); do not
pass the placeholder reference in `config/kafka-ha-values.yaml` as the complete
platform values. Keep this file and the migration journal outside Git:

```bash
umask 077
HIGH_AVAILABILITY_ENABLED=false scripts/render-cluster-config.sh \
  --output /path/to/private/rendered \
  --domain "$PLATFORM_DOMAIN" --internal-domain "$INTERNAL_DNS_ZONE" \
  --gitops-repository "$GITOPS_REPOSITORY_URL" \
  --cloudflare-access-team "$CLOUDFLARE_ACCESS_TEAM_NAME"

python3 scripts/configure-kafka-ha.py prepare \
  --state-dir /path/to/private/kafka-ha \
  --desired-values /path/to/private/rendered/k8s/values.yaml
```

`prepare` reads the running cluster and writes local evidence plus
`review-active-manifests.yaml`; it makes no cluster changes. Review the
resources and backup evidence before starting the maintenance operation:

```bash
python3 scripts/configure-kafka-ha.py migrate \
  --state-dir /path/to/private/kafka-ha \
  --desired-values /path/to/private/rendered/k8s/values.yaml \
  --maintenance --backup-confirmed
```

The migration performs these checks and transitions:

1. Record the original Kubernetes cluster, StatefulSet and PVC identities.
   Upgrade the existing static quorum to `kraft.version=1` and verify it before
   replacing `controller.quorum.voters` with bootstrap-server discovery.
2. Restart the existing controller and broker with the dynamic configuration.
   Original storage without its expected metadata refuses startup.
3. Expand to three controllers and brokers. New controllers format as
   observers with `--no-initial-controllers`; the helper verifies recent,
   zero-lag catch-up before admitting each with `add-controller`.
4. Reassign every partition to all three brokers. Only after a full ISR is
   verified does it enforce `min.insync.replicas=2` and disable unclean
   elections on existing topics and the cluster default. It removes overriding broker
   election settings, and broker minimum-ISR overrides when ELR is disabled.
   With ELR enabled, Kafka requires the cluster-level minimum and rejects
   broker-level changes. The active pod configuration also
   supplies replication defaults for future topics and transaction state.
5. Verify the actual quorum, brokers, placement and effective topic policies;
   record the active profile and write `active-values.yaml` in the journal.

Only Kafka resources are applied. Each phase merges its `kafkaHa` map into the
platform Argo Application without replacing unrelated values or sync settings.
The nonsecret checkpoint `infra/kafka-ha-state` blocks ordinary installation
while a migration is incomplete. Preserve the **complete** generated active
map in the installation's desired platform values before resuming Argo sync;
see [activation order](high-availability.md#activate-in-order). Keep the same
private journal for every retry. Run one operator at a time; the journal is
locked while a command runs, and its identity/checkpoint must match the cluster.
Do not clone an old journal to start another concurrent migration.

## Interrupted migration and recovery

Failures stop in the recorded phase. Re-run the same command after correcting
capacity, placement or readiness; do not create a new journal, reformat storage,
shrink the voter list or restore the original static manifest. If partition
reassignment is still running, let it finish before retrying. The native
feature/membership upgrade has no automatic rollback. Kubernetes manifests
alone cannot restore a previous Kafka metadata history.

Original ordinals refuse to initialize empty storage once bootstrap is off.
A lost original PVC requires explicit Kafka recovery, even if another copy is
available. New controller storage has a directory identity as well as a node
ID; replacing a failed voter requires the native Kafka membership recovery
procedure, not merely deleting its volume. Retained data is never deleted by
this helper.

For an entirely new Kafka installation, `fresh` replaces `prepare`/`migrate`.
It requires the same maintenance/backup acknowledgements and refuses any
existing Kafka StatefulSet, HA checkpoint or retained Kafka PVC. It generates
a new UUID, explicitly initializes only the initial controller/broker, disables
bootstrap again, then uses the same verified expansion. It is not a way to
reset an installed cluster.

## Verify

The read-only verifier needs no private journal:

```bash
python3 scripts/configure-kafka-ha.py verify
```

It requires an active checkpoint, all six Ready pods on distinct hosts within
each role, the expected three voters and brokers, three replicas/full ISR for
every partition, and the effective minimum-ISR/election policy. This is a
healthy-baseline check; it intentionally fails while a host is down, although
a correctly configured remaining quorum can keep serving.

Before relying on HA, perform the [controlled host-failure drill](high-availability.md#verify-before-relying-on-ha).
Check acknowledged production and consumption after losing the original host,
then restore full health before another failure. Replica counts alone do not
prove data durability or host-failure behavior.

Repository checks are `python3 scripts/test-kafka-ha.py`. The optional
`python3 scripts/test-kafka-ha-integration.py --output-dir PRIVATE_DIR` runs
an isolated Docker canary using the rendered pinned image and temporary
volumes; it exercises native upgrade, record preservation, observer admission,
replication and loss of the original controller/broker. It requires Docker,
Helm and several GiB of spare memory. It does not mutate Kubernetes or establish
physical-host/network/storage failover.
