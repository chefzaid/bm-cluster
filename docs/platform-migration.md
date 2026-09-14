# Migrating the platform to Traefik and upstream images

Chart 2 moves routing from retired ingress-nginx to native Traefik Ingress and
replaces privately rebuilt platform images with pinned public vendor images.
This is a maintenance operation spanning `bm-cluster`, DevApp, Indezy, Thoughty
and Website. It is separate from changing topology or activating database HA.
New installations do not need this procedure.

The installer and Ansible perform a read-only legacy workload check. Old root
Application image profile files also stop Helm rendering. These guards prevent
an ordinary rerun or existing profile-based sync from silently switching the
platform. They do not replace pausing automated reconciliation before publishing
migration changes.

## Prepare and rehearse

1. Record the installed source revisions, root and app Application specifications,
   Helm release values/versions, workload image digests, volume ownership and
   ingress/DNS mode in a private recovery directory. Pause automatic sync for the
   root and all four apps before publishing the new revisions. Keep it paused
   through validation; the root Application manages its own sync settings.
2. Verify off-host K3s, Vault, GitLab and database backups and retain the exact old
   images. Restore copies into disposable infrastructure. Check PostgreSQL
   collations/extensions and globals, MongoDB authentication/data, Vault unseal
   and Raft, GitLab repositories/secrets, and Keycloak/SonarQube database access.
   [Image maintenance](security-images.md#runtime-and-recovery-constraints)
   explains runtime identity changes. Stop writers before the final migration
   backup and ownership changes. Never run old and new writers against one volume.
3. Render the cluster with its existing identity and HA values using
   [the installation inputs](installation.md#organization-and-installation-identity).
   Review the resulting root Application and every app's rendered manifests.
   Preserve all installed identity, Odoo scope and HA migration settings. Rehearse
   the source revisions, routing and data restore on an isolated K3s cluster.

## Prepare routing without moving the public endpoint

Install Traefik and its CRDs before applying any new Middleware or app routes.
`INGRESS_MIGRATION_CANDIDATE=true ./scripts/configure-ingress.sh` installs a
ClusterIP Deployment without a Cloudflare Tunnel sidecar, even on an HA cluster.
Supply the existing identity and rendered `INGRESS_VALUES_FILE`. Probe this
candidate through a local port-forward with temporary copies of the new routes
and policies, using distinct names and synthetic backends where appropriate.
It neither publishes DNS nor starts a tunnel connector, and its IngressClass is
not the default during overlap. Candidate mode refuses to replace an existing
Traefik release; remove only a verified disposable candidate before repeating
this preparation. Promotion uses the normal helper on the prepared release.

The old and new controllers require different NetworkPolicy pod selectors.
Keeping legacy traffic during overlap requires temporary copies of both the old
Ingress objects and their ingress-allow policies. Applying the new app policies
alone can disconnect the old controller. The simpler supported cutover is a
maintenance window: update routes and policies together while writers and
external traffic are paused. Preserve the old manifests for rollback.

Verify HTTPS with the real origin certificate/SNI, HTTP redirects, OAuth login
and return URL, identity headers, app request limits, WebSockets, Sonar scanner
API access, GitLab Registry push/pull and Thoughty's canary rules. Traefik uses
same-namespace Middleware; app authentication and request limits are owned by
each app. The platform normalizes forwarded routing headers, trusts only the
configured Cloudflare ranges (direct mode) or loopback (Tunnel mode), and limits
public routers to its HTTP/HTTPS entry points.

## Cut over in a maintenance window

1. Keep automated sync paused. Remove the retired system image-override admission
   policies/bindings using the exact saved inventory; otherwise they can rewrite
   new Pods back to private images. Preserve the separate workload-hardening
   policies. Retain old image credentials until all installed consumers migrate.
2. Reconcile stateful services one at a time with the reviewed public image and
   runtime settings. Reconcile Vault/Argo CD Helm values as well as chart-owned
   workloads. Verify readiness, data and authentication after each transition.
   Replace app PostgreSQL helper images from their owning repositories.
3. Apply the new Ingress/Middleware and NetworkPolicy resources together. Remove
   the old ingress-nginx Helm release only after the candidate checks pass and
   the maintenance window begins. This releases direct-mode host ports or stops
   the old HA connectors. Run `configure-ingress.sh` without the candidate flag
   to promote the reviewed Traefik release to the existing direct/HA mode.
   For HA, this starts the co-located connectors against the existing tunnel;
   then run the Cloudflare configurator's origin/connector checks before DNS
   publication. Reconcile its platform-host client-IP transform and verify the
   resulting address at GitLab/Keycloak; GitLab loads the Traefik release's
   `ingress-proxy-trust` ConfigMap at startup. Restart it after any edge-range or
   ingress-mode change. Keep public hostnames unchanged in this step.
4. Replace the root Application's **entire Helm configuration** with the rendered
   configuration, preserving the reviewed identity and HA inputs. Remove old
   `profiles/security-images-*.values`, `securityImagesEnabled`, private Trivy
   registry/repository parameters, and ad hoc image overrides from parameters,
   inline values and `valuesObject`. Merely changing an image profile is not a
   migration. Keep `spec.syncPolicy.automated.enabled=false` on the staged
   Application until verification is complete. Use
   `PLATFORM_MIGRATION_APPROVED=true` (Ansible: `platform_migration_approved=true`)
   only for this prepared maintenance reconciliation; it does not bypass the
   separate ingress release guard or restore compatibility with retired inputs.
5. Check all platform and app routes, jobs, PVCs, installed image digests,
   authentication and fresh vulnerability reports. Re-enable automatic sync only
   after these checks pass. Remove temporary overlap resources, obsolete private
   registry ExternalSecrets/cache workloads and their unused credentials after
   the recovery window. Keep recovery archives off-host.

## Roll back

Pause reconciliation and writers. Restore the recorded source revisions,
Application Helm settings, ingress release and network policies as one set.
Restore data and matching application secrets when a service changed its on-disk
format or schema; switching an image back cannot undo a database migration.
Restore the previous direct endpoint or HA connector only after its routes are
ready. Verify data and external behavior before reopening traffic.

Kubernetes documents [ingress-nginx retirement](https://kubernetes.io/blog/2026/04/22/kubernetes-v1-36-release/#ingress-nginx-retirement).
The replacement uses Traefik's [native Ingress provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress/)
and [ForwardAuth](https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/forwardauth/),
with strict path-segment matching and automatic WebSocket forwarding. Global
900-second connection/request deadlines and app-specific response-header
limits are not exact replacements for NGINX idle read/send timers. Exercise long
uploads and streaming against the edge provider's own limits too.
