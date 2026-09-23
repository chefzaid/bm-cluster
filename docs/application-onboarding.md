# Application onboarding contract

Applications opt into `add-repos.sh` by committing `infra/onboarding.json`.
This reference is for application authors; the
[operator guide](repository-onboarding.md) covers setup credentials and reruns.
Version 1 declares supported platform operations without running repository
scripts or playbooks. Deploy workloads in `apps` using the
[namespace and discovery contract](observability.md#namespace-and-discovery).

The default branch needs a valid `.gitlab-ci.yml` and one Argo CD Application at
`infra/argocd/application.yaml` or `argocd/application.yaml`. Its source must be a
repository-local Kustomize directory or Helm chart using its defaults, with an
existing AppProject permitting the source/destination. External charts,
multi-source Applications and custom Helm/Kustomize source overrides are unsupported.

## Onboarding declaration

This generic example assumes an Application named `catalog`, a Kustomize source
at `infra/k8s`, and app-owned CI jobs named `verify` and `release`:

```json
{
  "version": 1,
  "application": "infra/argocd/application.yaml",
  "inputs": [
    {"name": "APP_SUBDOMAIN", "label": "Public subdomain (@ for apex)", "type": "subdomain", "default": "catalog"}
  ],
  "files": [".gitlab-ci.yml", "infra/argocd/application.yaml", "infra/k8s/ingress.yaml", "infra/k8s/kustomization.yaml"],
  "replacements": [
    {"from": "catalog.example.com", "to": "{{APP_HOST}}"},
    {"from": "example-com-tls", "to": "{{TLS_SECRET_NAME}}"},
    {"from": "targetRevision: main", "to": "targetRevision: {{DEFAULT_BRANCH}}"},
    {"from": "registry.example.com/team/catalog", "to": "{{REGISTRY_HOST}}/{{GITLAB_PROJECT_PATH}}"}
  ],
  "registry": {"path": "apps/catalog/registry"},
  "vault": [
    {"path": "apps/catalog/runtime", "fields": {"SIGNING_KEY": {"generate": 32, "encoding": "hex"}}}
  ],
  "dns": {"hosts": ["{{APP_HOST}}"]},
  "pipeline": {"variables": {"APP_ONBOARDING": "true"}, "jobs": ["verify", "release"]},
  "readiness": {"deployments": ["catalog"]}
}
```

Adapt the explicit files and mappings to the application. Image settings must
cover both workload manifests and later release helpers. Hostname changes may
also require browser configuration, redirects, allowed origins and build-time
canonical URLs. Test first rendering and a changed-context rerun against the
app's actual pipeline and rendered manifests.

## Fields

| Field | Contract |
|---|---|
| `version` | Must be `1`; unknown top-level fields are rejected. |
| `application` | Path to the Application described above. It must follow the default branch and target `apps` on `https://kubernetes.default.svc`. |
| `inputs` | Unique `name` values with optional `label`, `type`, `default`, `required` and `secret`. Declare `APP_SUBDOMAIN` to derive `APP_HOST`. |
| `files` | Unique, explicit local public files. No symlinks, paths outside the checkout, credential files, contract or saved-settings file. |
| `replacements` | Literal `from` text and a `to` template; simultaneous longest-match replacement uses prior rendered bindings on reruns. |
| `registry` | Required Vault `path` for verified `read_registry`/`read_repository` credentials, also projected into Argo CD through External Secrets. |
| `vault` | Optional list of `path` and `fields` maps; each field declares exactly one of `generate`, `value` or `input`. |
| `keycloak` | Optional `{"realm":"{{KEYCLOAK_REALM}}","file":"infra/keycloak/production-client.json"}` for a production public OIDC/PKCE client; add its file to `files` when it needs rendering. |
| `bootstrap` | Optional YAML files containing only `Namespace`, `Role`, `RoleBinding` or `ExternalSecret` resources in `apps`/`infra`. Namespace creation is limited to `apps`; use explicit resource namespaces. No workloads. |
| `dns` | Unique exact `hosts` in the selected public zone. Every rendered Ingress hostname must be declared; wildcards are unsupported. |
| `pipeline` | Public `variables` include `APP_ONBOARDING: "true"`; `jobs` lists required automatic delivery jobs. The platform supplies reserved `ONBOARDING_EXPECTED_SHA` and `ONBOARDING_RUN_ID`. |
| `readiness` | `deployments` lists names to verify in `apps` after Application `Synced`/`Healthy` status. |

Input types are `string`, `subdomain` and `cidrs`. `subdomain` accepts one DNS label
or `@`; only `APP_SUBDOMAIN` converts `@` to the zone apex. An alias constructed as
`{{ALIAS}}.{{PUBLIC_DOMAIN}}` needs a real label. `cidrs` accepts comma-separated IP
networks. Inputs are required unless `required:false` is declared. Public defaults
can reference context values; previous choices are offered on reruns.

Use `secret:true`, `required:false`, `default:""` for a hidden credential input
that can retain an existing value. Reference it only through a Vault field, such
as `"API_KEY":{"input":"PROVIDER_API_KEY"}`. Empty input retains an existing
credential; a missing required Vault value still stops setup. An optional feature
can seed an empty literal until deliberately enabled. Secret placeholders never
belong in public files, replacements or pipeline variables.

Registry/Vault paths must stay under `apps/<Application-name>/`. `generate`
requests 16–256 random bytes before `hex` or `base64` encoding. Literal `value`
fields are string defaults. Version-checked writes merge missing fields and
retain existing/unrelated values; a different supplied credential fails instead
of rotating it. Deleted versions require explicit recovery. Invalid registry
credentials can be replaced while prior tokens remain available for consumer
refresh; changing a declaration does not rotate a populated Vault value.

An optional Keycloak file must define a public HTTPS OIDC client using
Authorization Code with PKCE `S256`, limited to declared app hosts. Password,
implicit and service-account grants are disabled. The helper verifies realm,
client ownership and scopes, then reconciles supported scopes and group/audience
mappers. It does not import demonstration realms, users or secrets.

## Public rendering context

| Values | Meaning |
|---|---|
| `PUBLIC_DOMAIN`, `INTERNAL_DNS_ZONE`, `TLS_SECRET_NAME` | Platform public zone, private service zone and shared TLS Secret name. |
| `APP_SUBDOMAIN`, `APP_HOST` | Declared primary label and computed public hostname. |
| `GITLAB_PROJECT_PATH`, `GITLAB_PROJECT_ID`, `DEFAULT_BRANCH` | Imported destination identity and branch. |
| `GITLAB_PUBLIC_URL`, `GITLAB_INTERNAL_URL`, `GITLAB_REPOSITORY_URL` | Stable public GitLab base, internal API base and internal clone URL; the temporary setup port-forward is not saved. |
| `REGISTRY_HOST`, `REGISTRY_PUSH_HOST` | Public pull hostname and internal CI push endpoint. |
| `GITHUB_OWNER`, `GITHUB_REPOSITORY` | Imported GitHub source identity. |
| `KEYCLOAK_REALM` | Existing platform realm, discovered from the installed SSO issuer unless explicitly supplied. |
| `POD_CIDR` | Platform pod network; supply the actual `K3S_CLUSTER_CIDR` if it differs from the default. |
| `PLATFORM_SECURITY_PROJECT_PATH` | Shared helper-image project, discovered from the platform Application repository plus `/security`; independent of the app destination group. |
| `SONAR_PROJECT_KEY` | GitLab project path with `/` converted to `:`. |

Explicit `PLATFORM_DOMAIN`, `INTERNAL_DNS_ZONE` and `KEYCLOAK_REALM` settings
override discovery. Otherwise the installed `bm-cluster` Application supplies
Helm parameters, then `valuesObject`, then inline values. CoreDNS provides a
private-zone fallback; OAuth2 Proxy's OIDC issuer provides public-domain and
realm fallbacks. The private zone is never guessed from the public domain, and
missing required settings stop deployment.

Set `PLATFORM_SECURITY_PROJECT_PATH` to override helper-image discovery. If a
contract uses it and discovery fails, interactive setup asks for the value;
unattended setup requires it explicitly.

Declared public inputs add context names and cannot override platform values.
`infra/onboarding-values.json` stores version `1`, public `context` and `bindings`
mapping original literals to their last rendered values. These public settings
contain no secret inputs or credentials; the execution journal stays outside Git.
Keep the settings with rendered configuration so later pipelines reuse them.
Rendering normalizes the
Application's GitLab URL, default-branch revision and `infra` namespace while
preserving its source path/profile. Release jobs must preserve these choices.

## Required delivery behavior

The default-branch pipeline must accept source `api` and automatically run its
declared jobs with `APP_ONBOARDING=true`. Ordinary manual-release behavior remains
independent of onboarding; source-analysis pipelines follow the separate
[scanner contract](observability.md#scanner-contract).

Before publication, validate that `CI_COMMIT_SHA` equals a valid
`ONBOARDING_EXPECTED_SHA`, the branch is the default branch and source is `api`.
Tools with Git should also verify their checkout and the current remote branch.
Reject an advanced branch before changing desired state; an outdated onboarding
run must not report deployment success. Configuration commits use `[skip ci]`,
so the explicit onboarding pipeline owns first publication.

The final GitOps commit created by an onboarding pipeline must include these
trailers with the actual pipeline ID and source SHA:

```text
Onboarding-Pipeline: <CI_PIPELINE_ID>
Onboarding-Source: <CI_COMMIT_SHA>
```

If release preparation creates several commits, put the trailers on the final
branch tip. The helper verifies those identifiers and source ancestry before
accepting that tip as the deployment revision. `ONBOARDING_RUN_ID` identifies
the API request for recovery after a lost response; do not override or persist
it as public application configuration.

The release pipeline publishes immutable images, commits their selection and
applies the committed Application once prerequisites exist. That restores any
temporarily paused automatic sync policy. CI waits for its intended revision and
application-specific health checks. The generic helper then requires every
declared job to succeed, checks Argo CD's exact release revision, and verifies
Application/Deployment health. Keep required work in ordinary jobs; optional
reports may remain manual/non-blocking without
being listed as required delivery jobs.

See [reruns and recovery](repository-onboarding.md#automation-and-reruns) for
private journals and partial-setup behavior.
