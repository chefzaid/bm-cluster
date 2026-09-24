# Add, synchronize and deploy repositories

Run `./add-repos.sh` from this checkout on a configured control-plane host. It
imports GitHub repositories into GitLab, configures two-way synchronization,
and deploys selected applications. Rerun it to add repositories, change public
settings or resume interrupted setup.

The installer calls this helper after platform and Argo CD setup when repository
onboarding is selected. [Ansible](installation.md#optional-host-and-account-changes)
uses the same helper and unattended inputs. Application declarations stay in
their repositories; `bm-cluster` has no application inventory.

## Guided flow

1. Enter a GitHub username, hidden personal access token and comma-separated
   repositories such as `catalog,org/api`; bare names belong to that user.
2. Confirm the public GitLab HTTPS URL and destination group. Defaults come from
   the installed platform identity/domain or GitLab Ingress. Nested groups are
   supported; repository names are preserved.
3. The helper creates missing groups/projects privately, configures synchronization
   and verifies the initial copy. It manages the GitHub workflow, encrypted Actions
   secrets/variables and GitLab push/tag webhook. A conflicting workflow is reported
   rather than overwritten.
4. Select deployments: accept all successful imports, choose a comma-separated
   subset or enter `none`. Each selected repository must have the
   [onboarding contract](application-onboarding.md).
5. Supply declared app inputs; previous public choices are defaults. After
   validation, the helper commits public configuration with `[skip ci]` and sets
   up declared registry/Vault/identity resources, bootstrap prerequisites and DNS.
6. An API pipeline receives the configured source SHA and a unique run ID. The
   app publishes images and applies its Argo CD Application. The helper waits for
   required jobs, the exact release revision to become `Synced`/`Healthy`, and
   declared Deployment rollouts.

Selecting deployment authorizes these configuration commits and service changes.
The helper reports `[READY]` only after delivery and readiness succeed. Missing contracts,
prerequisites or required jobs produce `[CANNOT DEPLOY]`; imports remain available
for correction and retry, and failures make the command exit nonzero.

New projects have CI disabled during import; selecting a valid deployment enables
CI and the shared runner. Skipped new projects keep CI disabled. Existing projects
retain their CI setting, so ordinary synchronized source commits can still start
existing pipelines.

For version 1 contracts, when public configuration changes, an existing automatically synced Application
is paused before the settings commit is published. Workloads remain running.
The app's release job reapplies its committed Application after publishing images,
restoring its sync policy. First deployment is also owned by that release job;
onboarding does not start application workloads ahead of it.

## Environment deployment

DevApp uses contract version 2. First [register the local or remote environments](installation.md#application-deployment-clusters)
and enable [shared data access](application-onboarding.md#shared-application-data).
Run `add-repos.sh` once on the central platform to import the one repository.
Version 2 needs Cloudflare Zone Read, DNS Edit and SSL and Certificates Edit
on the managed parent zone for DNS, origin certificates and edge-coverage checks.
Onboarding provisions registry access, separate data credentials and browser
clients for every registered target, reconciles their DNS/TLS, and writes the
public inventory and target settings into the application repository.
It also provisions project-scoped integration/release runners and their scoped
Application permissions. The default branch must be protected; the project no
longer uses the shared instance runner. See [delivery permissions](delivery.md#application-delivery).

`APP_SUBDOMAIN` is one shared app label. With `platform.hostnameStyle: suffix`,
`devapp` produces `devapp-int.example.com`, `devapp-uat.example.com` and
`devapp.example.com`. The [installation guide](installation.md#application-deployment-clusters)
also covers nested hostnames and their certificate requirements.
Onboarding applies that label to all registered environments. It defaults the
initial deployment to `int`; export `ONBOARDING_DEPLOYMENT_ENVIRONMENT=uat` or
`prod` to choose a different initial target. This does not change the normal CI
dropdown. Later deployments and release promotions use [GitLab CI](delivery.md#application-delivery).

Onboarding prepares every registered target and checks certificate/DNS
prerequisites for all of them, even when the initial deployment selects only one.
For staged adoption, register environments as their infrastructure and DNS
prerequisites become ready.

Newly registered targets require another application-onboarding run to provision
their data, identity and DNS before first deployment. Existing Applications keep
independently pinned revisions while public settings are updated; they need no
automatic-sync pause. Onboarding verifies the selected runtime commit separately
from the final Git commit containing its Application pointer.

## Prerequisites and credentials

The host needs Bash, Git, curl, jq, GNU date, Python, PyYAML and libsodium. The
installer supplies the Ubuntu/Debian packages. Deployment also needs the
control-plane kubeconfig, `kubectl`, Argo CD in `infra`, the instance runner and
requested shared services. Local Helm charts require Helm. Vault must be unsealed
with its KV-v2 `secret/` mount; External Secrets and public ingress/TLS must work.
Before publishing configuration, onboarding checks the selected application namespace foundation,
the AppProject's repository/destination permissions and certificate coverage for
the declared hosts. Repository credentials must complete a fresh successful
ExternalSecret refresh before delivery starts.

Use a GitHub [fine-grained PAT](https://github.com/settings/personal-access-tokens/new),
not an account password. Selected repositories require **Administration, Actions,
Contents, Secrets, Variables and Workflows: read/write**. Organization rules must
permit the token and Actions. Branch protection must permit workflow installation,
configuration commits, synchronization and release pushes. Rejected operations
are reported; the helper does not relax protection. Empty or archived sources
are unsupported.

| Credential | Scope and handling |
|---|---|
| GitHub PAT | Encrypted Actions secret `REPOSITORY_SYNC_ADMIN_TOKEN` and GitLab webhook Authorization header; rerun with a replacement before expiry. |
| GitLab sync project token | `write_repository` and `self_rotate`; the monthly GitHub workflow rotates it near expiry. |
| GitLab setup administrator token | Issued locally through `gitlab-rails` and revoked on exit. An explicit `GITLAB_ADMIN_TOKEN` with `api` scope is accepted and retained. |
| App registry deploy token | `read_registry` and `read_repository`, stored at the app-declared Vault path; valid credentials are verified and reused. |
| Argo CD repository access | A generic `infra/repository-<hash>` ExternalSecret projects the verified app registry/repository credential from Vault; no separate unmanaged password is copied into Git. |
| Cloudflare API token | **Zone Read** and **DNS Edit** for the selected zone; environment or hidden prompt. Onboarding uses an existing HA Tunnel rather than creating one. |
| Vault setup access | Private `VAULT_BOOTSTRAP_TOKEN_FILE`, default `/var/lib/bm-cluster/vault-bootstrap-token`; access through a local port-forward. Declared paths need read/create/update and KV metadata-read access. |
| Optional Keycloak setup access | Uses the platform administrator Secret and a local port-forward; no client credentials are committed. |

Secrets stay in memory or private temporary credential files during setup, outside
Git and the progress journal. Declared secret inputs use hidden prompts. Keep
unattended inputs outside repositories with mode `0600`; operator-supplied files
are not automatically deleted.

Setup normally reaches GitLab through a temporary loopback `kubectl port-forward`
for API requests, cloning and registry authentication. This avoids depending on
the operator host's DNS or browser authentication. An explicit `GITLAB_URL`
overrides that control route; when the GitLab Service is unavailable, imports
fall back to public GitLab. Deployment still requires access to the cluster.

Synchronization uses `GITLAB_PUBLIC_URL`: GitHub Actions must reach public GitLab
API/Git routes, and GitLab must reach `api.github.com`. Browser-only Cloudflare
Access must not intercept those synchronization requests. Argo CD and app CI use
the installed private service zone; temporary loopback addresses are never saved
as application endpoints. See [installed context discovery](application-onboarding.md#public-rendering-context)
for defaults and explicit overrides.

## Application configuration

The [app-author reference](application-onboarding.md) defines supported files,
inputs, service setup and CI behavior. Public choices are saved in
`infra/onboarding-values.json`; reruns replace prior rendered values so changed
domains/groups survive releases. Existing Vault values are retained, not rotated.

Applications follow the [namespace and discovery contract](observability.md#namespace-and-discovery)
for dashboards and source analysis. Their selected deployment paths remain
app-owned; onboarding does not add nodes or activate [HA](high-availability.md).
The shared `apps` foundation is available even when Odoo is disabled.

For hostname changes and direct/Tunnel routing, follow
[application DNS ownership](networking.md#application-dns-ownership).

## Automation and reruns

`--yes` never prompts. Supply `DEPLOY_REPOSITORIES=all`, `none`, or a comma-separated
subset, plus required app inputs. A private JSON file is keyed by GitHub slug:

```json
{
  "alice/catalog": {"APP_SUBDOMAIN": "catalog"},
  "org/api": {"APP_SUBDOMAIN": "api"}
}
```

```bash
chmod 600 /secure/repository-inputs.json
read -rsp 'GitHub personal access token: ' GITHUB_ADMIN_TOKEN; echo
read -rsp 'Cloudflare DNS token: ' CLOUDFLARE_API_TOKEN; echo
export GITHUB_ADMIN_TOKEN CLOUDFLARE_API_TOKEN
GITHUB_USERNAME=alice \
GITHUB_REPOSITORIES='catalog,org/api' \
GITLAB_PUBLIC_URL=https://gitlab.example.com \
GITLAB_GROUP_PATH=team \
DEPLOY_REPOSITORIES=all \
  ./add-repos.sh --yes --inputs /secure/repository-inputs.json \
    --state-dir /secure/repository-state
unset GITHUB_ADMIN_TOKEN CLOUDFLARE_API_TOKEN
```

`--inputs` and `--state-dir` also work interactively. Their environment equivalents
are `REPOSITORY_INPUTS_FILE` and `REPOSITORY_STATE_DIR`. Unknown app input names
fail validation. The state directory is created privately and must have mode
`0700` if it exists.

Export these inputs with `CONFIGURE_REPOSITORY_SYNC=true` for the installer or
Ansible. `ONBOARDING_TIMEOUT` controls the required-job wait in seconds: default
`3600`, range `30`–`43200`. Application synchronization waits up to 15 minutes
within that setting, then checks declared Deployment rollouts.

Progress defaults to `~/.local/state/bm-cluster/repositories`. Each locked journal
records project/cluster identity, configuration and pipeline progress without
credentials. Rerun from the same host/state directory to resume a recorded
pipeline or retry failed jobs. An active earlier pipeline must finish before
settings change. Missing or manual required jobs cannot count as deployment
success; inspect the reported pipeline and correct its cause before rerunning.

Pipeline creation intent is journaled before the API request. If its response is
lost, rerunning looks for the matching source SHA and `ONBOARDING_RUN_ID` instead
of immediately creating another pipeline. An unresolved request stops recovery.
Check GitLab before removing only `pipeline_intent` from the private journal,
and do so only after confirming that request created no pipeline. An ambiguous
HTTP timeout cannot guarantee exactly one pipeline without that confirmation.

Failures can leave configuration commits, credentials, DNS or a paused Application
in place. Completed setup is retained; there is no automatic repository deletion
or data rollback. After configuration is published, the corrected release
restores the Application's policy. If publication never happened, a rerun can
restore the prior policy after verifying the source is unchanged. Other selected
repositories continue. A new host can recover public choices
from Git; transferring the private journal is necessary to resume its recorded
pipeline rather than start a new operation.

## Synchronization and validation

Reruns preserve visibility; private GitHub sources require private GitLab
projects. Sync fast-forwards the lagging side and merges compatible divergence
without force pushes. Resolve merge conflicts and conflicting tags before
retrying. Deletion on only one side is restored. Issues, pull requests, releases,
packages, Git LFS objects and hosting metadata require separate migration.

The platform GitOps URL is an independent installer choice. Importing this
repository copies source; it does not replace platform installation or Odoo setup.

Run [repository validation](operations.md#validation), then verify onboarding
changes with a disposable repository using the [app contract](application-onboarding.md):
confirm private-source visibility, synchronization, a successful pinned pipeline,
application readiness and an idempotent rerun.
