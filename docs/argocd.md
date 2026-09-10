# Argo CD operations

Argo CD is installed through Helm. `install-control-plane.sh` and
`ansible/deploy.yml` both use the rendered `config/argocd-values.yaml`, with the
chart and application versions from `config/platform.env`. The `bm-cluster`
Application reconciles platform resources after bootstrap; it does not upgrade
the Argo CD Helm release itself. Changes to these Helm values require an
installer/Ansible reconciliation or a Helm upgrade using the same rendered
values and version pins.

## Application controller memory

The application controller keeps a cache of Kubernetes resources for comparing
live state with Git. Its container requests 256 MiB and has a 1 GiB memory limit.
`controller.env` sets `GOMEMLIMIT=768MiB` so Go collects garbage before reaching
the container limit, leaving 256 MiB for non-Go allocations and transient work.
The limit applies only to the application controller.

This headroom addresses repeated `OOMKilled` restarts when process memory
approached the container limit despite a smaller live Go heap. See the
[Argo CD memory guidance](https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/#mitigating-oomkilled-events-from-memory-spikes).

`GOMEMLIMIT` uses Go units such as `MiB`, while Kubernetes resource quantities
use `Mi`. It is a soft limit on memory managed by Go, not a reservation or a hard
process limit. The runtime can exceed it if garbage collection cannot keep up;
see the [Go garbage collector guide](https://go.dev/doc/gc-guide#Memory_limit).

After upgrading the Helm release, wait for the controller StatefulSet rollout
and verify that all Applications return to `Synced` and `Healthy`. Confirm the
controller's `go_gc_gomemlimit_bytes` metric is `805306368` and watch restart
counts, container working memory, GC activity, CPU use, and reconciliation
duration across cold start and several normal reconciliation cycles. Continue
observation for 24 hours before considering the recurring OOM problem resolved.

If OOMs continue or sustained garbage collection slows reconciliation, inspect
the controller's live heap and resource cache. Increase the container budget
and soft limit together only when node capacity supports it. Do not keep
lowering the soft limit into the live working set or remove resource coverage
to conceal memory pressure.
