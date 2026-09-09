# Import, synchronize, and deploy repositories

The three guided entry points are:

| Command | Purpose |
| --- | --- |
| `./install-control-plane.sh` | Install/reconcile the cluster, with optional repository onboarding at the end |
| `./add-node.sh` | Add control-plane or worker nodes to an existing cluster; see [node enrollment](node-enrollment.md) |
| `./replicate-repo.sh` | Import more repositories and select deployments on an existing cluster |

Run the repository assistant from a `bm-cluster` checkout on the control plane:

```bash
./replicate-repo.sh
```

## Guided flow

1. Enter your GitHub username, a personal access token using hidden input, and
   repository names separated by commas, for example `web,api,org/mobile`.
   Bare names belong to your username; `owner/name` supports organizations.
2. Confirm the public GitLab HTTPS URL and destination group. The URL defaults
   from `PLATFORM_DOMAIN`, or from the cluster's GitLab Ingress. The group
   defaults to `swirlit`; standalone imports also support nested groups.
   Each source keeps its repository name in that group.
3. The assistant creates missing private groups/projects, installs or updates
   the managed `.github/workflows/sync-gitlab.yml` on each GitHub default branch,
   configures encrypted Actions secrets and repository variables, and creates
   or updates GitLab push/tag webhooks. Installing the workflow creates a commit.
   An unrelated workflow at that path is reported instead of overwritten.
4. GitHub Actions performs the first import and verifies that branches and tags
   match. The assistant waits for the dispatched run to finish successfully,
   including when the destination already has commits. It reports failures per
   repository and continues with the other names.
5. **After imports finish**, the deployment prompt is prefilled with all
   successfully imported names, comma separated. Edit the answer to select a
   subset, press Enter for all, or enter `none` to import without deploying.
6. For each selection, the assistant checks the deployment contract below,
   configures Argo CD repository access, applies the Application, and starts a
   default-branch GitLab pipeline. Missing or invalid configuration produces
   `[CANNOT DEPLOY] <repository>: <reason>` and processing continues.

New projects have GitLab CI disabled during import. Selecting a valid deployment
enables CI and the shared instance runner. Imported projects that are skipped
keep CI disabled; their repository synchronization still works. Existing
projects retain their CI setting during import, so their existing pipelines
and deployments can respond to synchronized commits as usual.

The installer asks whether to duplicate GitHub repositories, then calls this
same standalone entry point after its platform and Argo CD installation stages.
GitHub credentials and repository names are collected by the assistant at that
point. The cluster's own `GITOPS_REPOSITORY_URL` remains an independent installer
choice and must already be accessible; it is not switched to an empty GitLab
project. Odoo remains centrally managed by the installer. Replicating
`bm-cluster` copies its source, but its platform Application is still installed
by `install-control-plane.sh`, outside the application bootstrap contract below.

## Prerequisites and credentials

The host needs Bash, Git, curl, jq, GNU date, Python 3.9 or newer, PyYAML,
and libsodium. On Ubuntu/Debian, the installer installs `python3-yaml` and
`libsodium23` along with its other prerequisites. Deployments also need `kubectl`,
the control-plane kubeconfig, an installed Argo CD in `infra`, and the platform's
GitLab instance runner. The assistant configures projects; shared platform
provisioning stays in the installer and `scripts/configure-gitlab-ci.sh`.

GitHub requires a token rather than an account password. Create a
[fine-grained personal access token](https://github.com/settings/personal-access-tokens/new)
for the selected repositories with **Administration, Actions, Contents, Secrets,
Variables, and Workflows: read/write**. The account must administer the selected
repositories; organization policies must allow the token and GitHub Actions.
GitHub requires the additional Workflows permission when
[writing workflow files](https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents).
Branch protection/rulesets must allow the workflow installation and the sync
identity's pushes. The assistant reports rejected operations; it does not
change protection rules. Empty or archived GitHub sources cannot be onboarded.

The GitHub PAT is needed for ongoing synchronization, including workflow-file
commits, and must remain valid. It is stored as an encrypted Actions secret
`REPOSITORY_SYNC_ADMIN_TOKEN` and a GitLab webhook Authorization header. Rerun
the assistant with a replacement PAT before expiry; it refreshes both places.
The managed GitLab project token has `write_repository` and `self_rotate` scopes.
The monthly GitHub Actions schedule renews it when expiry approaches. GitHub
may disable schedules on inactive public repositories; rerunning the assistant
re-enables the managed workflow.

The control-plane token helper creates a one-day GitLab administrator token
locally through `gitlab-rails` and revokes it on exit. You can instead provide
`GITLAB_ADMIN_TOKEN` with the `api` scope; a supplied token is not revoked.
Setup credentials are not written into either repository. Argo CD gets a
project deploy token restricted to `read_repository`, stored in a Kubernetes
repository Secret. This token has no expiry; remove/revoke it when removing the
repository. Reruns reuse its Secret. If it has been revoked externally, delete
that managed `repository-<hash>` Secret and rerun to issue a replacement.

GitHub-hosted Actions must reach `https://gitlab.<domain>` for API and Git access,
and GitLab must reach `https://api.github.com` for webhook dispatch. Browser-only
Cloudflare Access authentication must not intercept these machine requests.
`GITLAB_URL` can override the assistant's control-plane API route, for example
an internal Service IP; synchronization still uses `GITLAB_PUBLIC_URL`.
Argo CD uses `gitlab.<INTERNAL_DNS_ZONE>`; the zone defaults to
`internal.<domain>` derived from the public `gitlab.<domain>` hostname. Export
`INTERNAL_DNS_ZONE` for a cluster with a different private zone.

## Deployment contract

The [Ansible entry points](ansible.md#repository-replication-and-deployment)
support the same unattended inputs. They configure platform CI first and invoke
this assistant after Argo CD is available.

Each selected repository must contain, on its imported default branch:

- A nonempty `.gitlab-ci.yml` accepted by GitLab's project CI Lint API, including
  any referenced CI configuration. Its workflow rules must allow API-triggered
  default-branch pipelines.
- Exactly one bootstrap location: `infra/argocd/application.yaml` or
  `argocd/application.yaml`. The file contains one
  `argoproj.io/v1alpha1` `Application` with a name and `spec.project`.
- One `spec.source` that identifies this GitHub or destination GitLab repository
  and a nonempty repository directory in `source.path` at `targetRevision`.
  Helm charts stored inside the repository and Kustomize directories are both
  supported. External chart sources and multi-source Applications are not.
- A destination server of `https://kubernetes.default.svc` and an explicit
  destination namespace. The Application lives in `infra`; its AppProject must
  already exist and permit the source and destination.

The assistant reads these files through GitLab and renders the Application's
`repoURL` to the cluster's private GitLab DNS alias. It retains the declared revision,
path, destination, Helm/Kustomize settings, and sync policy. Application names
already bound to a different repository are rejected. The rendered bootstrap
is server-side dry-run validated before it is applied. CI lint failures restore
the project's previous CI setting.

Application resources remain owned by their source repositories. The assistant
does not invent deployment files, execute repository-provided shell scripts or
Ansible playbooks, or rewrite application hostnames, image names, Vault paths,
and CI variables. Configure application-specific prerequisites such as registry
pull credentials, database secrets, DNS, and build variables using that
repository's documented bootstrap before deploying it. Keep Application source
URLs consistent in any app-owned automation that later reapplies the bootstrap.

Successful output means the Application was registered and the pipeline was
started. Builds and Argo CD reconciliation run asynchronously; use the printed
pipeline link and `kubectl -n infra get applications` to inspect rollout status.
An Application with manual sync still requires the normal Argo CD sync action.
If a later step fails, an already-applied Application remains in the cluster;
the assistant reports the failure and supports rerunning after correction.

## Automation and reruns

`--yes` never prompts and requires an explicit deployment selection:

```bash
read -rsp 'GitHub personal access token: ' GITHUB_ADMIN_TOKEN; echo
export GITHUB_ADMIN_TOKEN
GITHUB_USERNAME=alice \
GITHUB_REPOSITORIES='web,org/api' \
GITLAB_PUBLIC_URL=https://gitlab.example.com \
GITLAB_GROUP_PATH=team \
DEPLOY_REPOSITORIES=all \
  ./replicate-repo.sh --yes
unset GITHUB_ADMIN_TOKEN
```

Use `DEPLOY_REPOSITORIES=none` or a comma-separated subset instead of `all` as
needed. Export these inputs with `CONFIGURE_REPOSITORY_SYNC=true` when invoking
`./install-control-plane.sh --yes`; the installer forwards them to the assistant.
The former installer `REPOSITORY_SYNC_MAPPINGS` input is replaced by
`GITHUB_USERNAME`, `GITHUB_REPOSITORIES`, and `GITLAB_GROUP_PATH`. For different
destination groups, run the assistant once per group. Two sources with the same
repository name cannot target the same group.

Reruns reuse projects, update the managed workflow, reconcile the existing
webhook and secrets, verify synchronization again, and offer deployment again.
New groups/projects are private; existing visibility is preserved. Importing a
private GitHub repository into a public/internal destination is refused until
the destination is made private.

Synchronization fast-forwards the lagging side and merges non-conflicting
divergence. It never force-pushes, fails on merge conflicts or conflicting tag
objects, and restores branches/tags deleted on only one side. Resolve conflicts
manually, then rerun. Source history, branches, and tags are synchronized;
issues, pull requests, releases, packages, Git LFS objects, and other hosting
metadata are not imported. Keep separate LFS synchronization where required.

Exit status is zero when every requested operation succeeds, and nonzero when
an import fails or a selected repository cannot be deployed. Successful imports
are retained on partial failure, and unaffected repositories continue. There is
no automatic deletion or rollback of repositories.

## Validation

```bash
./scripts/test-repository-replication.sh
./scripts/validate-repository.sh
```

Offline tests cover input validation, workflow installation/reuse, private
projects, deployment selection, missing/invalid configuration, CI lint failures,
Application collisions, credential cleanup, and partial failures. The actual
GitHub workflow reconciler also runs against local Git repositories to verify
two-way branch/tag convergence and refusal to overwrite merge conflicts.
