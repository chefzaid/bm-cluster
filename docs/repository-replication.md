# Import, synchronize and deploy repositories

Run `./replicate-repo.sh` from a `bm-cluster` checkout on the control plane to
import GitHub repositories into GitLab and select which to deploy. The installer
can call this same entry point after platform and Argo CD setup. Shared CI,
registry and GitOps responsibilities are described in [delivery](delivery.md).

## Guided flow

1. Enter your GitHub username, a hidden personal access token, and comma-separated
   repository names such as `web,api,org/mobile`. Bare names belong to your user;
   `owner/name` supports organizations.
2. Confirm the public GitLab HTTPS URL and destination group. The URL defaults
   from `PLATFORM_DOMAIN` or the installed GitLab Ingress; the group defaults to
   `swirlit` and may be nested. Each source keeps its repository name.
3. The assistant creates missing private groups/projects, commits the managed
   `.github/workflows/sync-gitlab.yml` to each GitHub default branch, configures
   Actions secrets/variables and GitLab push/tag webhooks, and waits for the
   initial synchronization to succeed. An unrelated workflow at that path is
   reported instead of overwritten. Failures are reported per repository.
4. After import, the deployment prompt is prefilled with all successful names.
   Press Enter for all, choose a comma-separated subset, or enter `none`.
5. Each selection is checked against the deployment contract below. Valid
   selections get Argo CD repository credentials and an Application, then a
   default-branch GitLab pipeline. Invalid selections produce
   `[CANNOT DEPLOY] <repository>: <reason>` and remain imported and synchronized.

New projects have CI disabled during import; selecting a valid deployment enables
CI and the shared runner. Skipped new projects keep CI disabled. Existing projects
retain their CI setting during import, so synchronized commits can start their
normal pipelines and deployments.

The platform's `GITOPS_REPOSITORY_URL` is an independent installer choice and must
already be accessible. Replicating `bm-cluster` copies its source; its platform
Application and centrally owned Odoo remain the installer's responsibility.

## Prerequisites and credentials

The host needs Bash, Git, curl, jq, GNU date, Python 3.9+, PyYAML and libsodium.
The installer supplies `python3-yaml` and `libsodium23` on Ubuntu/Debian.
Deployment additionally requires `kubectl`, the control-plane kubeconfig,
Argo CD in `infra`, and the platform GitLab instance runner.

Use a GitHub [fine-grained PAT](https://github.com/settings/personal-access-tokens/new),
not an account password. The selected repositories need **Administration, Actions,
Contents, Secrets, Variables and Workflows: read/write**. The user must administer
them; organization rules must permit the token and Actions, and branch protection
must permit workflow installation and sync pushes. The assistant reports rejected
operations and leaves protection rules unchanged. Empty or archived sources are
unsupported.

| Credential | Storage and renewal |
| --- | --- |
| GitHub PAT | Encrypted Actions secret `REPOSITORY_SYNC_ADMIN_TOKEN` and GitLab webhook Authorization header; rerun with a replacement before expiry. |
| GitLab sync project token | `write_repository` and `self_rotate` scopes; the monthly GitHub schedule rotates it near expiry. Rerunning re-enables a managed workflow disabled through inactivity. |
| GitLab setup administrator token | Created locally through `gitlab-rails` with a short lifetime and revoked on exit. An explicit `GITLAB_ADMIN_TOKEN` with `api` scope is supported and is not revoked. |
| Argo CD project deploy token | Non-expiring `read_repository` token in a Kubernetes `repository-<hash>` Secret, reused on reruns. Revoke it when removing the repository; if externally revoked, delete its managed Secret and rerun to replace it. |

Setup credentials are not written into either repository. GitHub Actions must
reach public GitLab API/Git routes, and GitLab must reach `api.github.com` for
webhook dispatch. Browser-only Cloudflare Access must not intercept these requests.
`GITLAB_URL` can override the assistant's control-plane API route; synchronization
uses `GITLAB_PUBLIC_URL`. Argo CD uses `gitlab.<INTERNAL_DNS_ZONE>`, defaulting to
`internal.<domain>` derived from the public GitLab hostname. Set
`INTERNAL_DNS_ZONE` explicitly if the cluster uses another private zone.

## Deployment contract

Each selected repository must contain these files on its imported default branch:

- A nonempty `.gitlab-ci.yml` accepted by GitLab's project CI Lint API, including
  referenced configuration. Workflow rules must allow API-triggered default-branch
  pipelines.
- Exactly one bootstrap at `infra/argocd/application.yaml` or
  `argocd/application.yaml`, containing one `argoproj.io/v1alpha1` Application
  with a name and `spec.project`.
- One `spec.source` identifying the imported repository, with a nonempty
  repository directory in `source.path` at `targetRevision`. Repository-local
  Helm charts and Kustomize directories are supported; external charts and
  multi-source Applications are not.
- Destination server `https://kubernetes.default.svc` and an explicit namespace.
  The Application belongs in `infra`; its AppProject must already exist and
  permit the source and destination.

The assistant rewrites only the source repository URL to the private GitLab alias
and the Application namespace. It retains revision, path, destination, rendering
settings and sync policy. It rejects Application names belonging to another
repository and performs a server-side dry run before applying. CI lint failures
restore the project's previous CI setting.

Follow the app repository's bootstrap for registry pull credentials, database
secrets, DNS and build variables before deploying. The assistant does not generate
missing files, execute repository shell scripts/playbooks, or rewrite app-specific
hostnames, images, Vault paths and CI variables. Keep source URLs consistent in
app-owned automation that later reapplies the Application.

Success means the Application was registered and the pipeline started, not that
the asynchronous rollout finished. Follow the printed pipeline link and
`kubectl -n infra get applications`; manual sync policies still require a sync.
A later failure can leave an already-applied Application in place. Correct the
reported problem and rerun.

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

Use `DEPLOY_REPOSITORIES=none` or a comma-separated subset as needed. Export these
inputs with `CONFIGURE_REPOSITORY_SYNC=true` for `./install-control-plane.sh --yes`.
[Ansible](ansible.md#optional-host-and-account-changes) accepts the same
unattended contract after platform CI and Argo CD setup. Run once per destination
group; two sources with the same name cannot target one group.

Reruns reuse projects, reconcile managed workflows/hooks/secrets, verify sync and
offer deployment again. Existing visibility is preserved; private GitHub sources
require private GitLab destinations.

GitHub pushes and GitLab push/tag webhooks invoke the same workflow reconciler.
It fast-forwards the lagging side and merges non-conflicting divergence without
force pushing. Merge conflicts and conflicting tag objects fail visibly; resolve
them manually before retrying. A branch or tag deleted on only one side is restored.
Only Git history, branches and tags are synchronized; issues, pull requests,
releases, packages, Git LFS objects and hosting metadata need separate migration.

The exit status is nonzero if an import or selected deployment fails. Successful
imports are retained, other repositories continue, and there is no automatic
repository deletion or rollback.

## Validation

`./scripts/test-repository-replication.sh` checks onboarding, credentials cleanup,
deployment validation and partial failures, and exercises branch/tag convergence
and conflict refusal with local Git repositories. See
[repository validation](operations.md#validation) for the full check suite.
