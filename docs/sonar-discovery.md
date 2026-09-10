# Sonar discovery and source analysis

The platform discovers source repositories behind workloads in `apps` and
provisions their Sonar projects. Each application owns the build, coverage and
scanner inputs needed to analyze its backend and frontend. Discovery does not
infer those requirements or replace manual scans.

## Automatic and manual scans

| Trigger | Behavior |
| --- | --- |
| Default-branch CI | The application's quality job runs automatically with its normal pipeline. |
| Namespace discovery | Every 15 minutes, request a scan if the repository has no analysis or its latest analysis is over 24 hours old. |
| Manual scan | Run a default-branch GitLab pipeline with `SONAR_SCAN_ONLY=true`; app-specific manual jobs/local scanner commands remain available as documented by the app. |

The [`sonar-apps-discovery` CronJob](../k8s/apps/sonar-apps-discovery.yaml) runs
in `infra`, listing Deployments, StatefulSets, DaemonSets, CronJobs, standalone
Jobs and Pods in `apps`. It follows Argo CD tracking annotations to Applications,
accepts source repositories only within configured GitLab hosts and group, and
deduplicates components of the same repository. There is no application-name list
to maintain. Corporate/vendor workloads in `corp`, including Odoo, are outside
this scope. Trivy security scanning operates independently.

Discovery provisions missing projects, binds them to the managed `swirlit-gitlab`
ALM integration and creates a protected, masked `SONAR_TOKEN` project variable
when absent. Non-public GitLab repositories receive private Sonar projects.
It requests at most one scan-only pipeline per run, defers while a discovered
app's default-branch pipeline is active, and waits six hours after a recent
API-triggered pipeline before retrying. Freshness is a scheduling target, not an
exact daily scan time; successful manual or normal CI analysis satisfies it too.

## Application contract

Keep these files and CI rules in every application repository:

- `sonar-project.properties` must declare `sonar.projectKey=<group>:<repository>`
  with every GitLab path slash replaced by a colon. Include all backend, frontend
  and shared source paths, compiled inputs where required, and coverage reports.
- `.sonar-auto.json` declares the quality job and scan-only variable:

  ```json
  {"version":1,"job":"02-quality","scanOnlyVariable":"SONAR_SCAN_ONLY"}
  ```

  Website uses `"job":"sonar"`. The declaration names the app's contract; the
  platform does not modify its pipeline implementation.
- A default-branch pipeline with `SONAR_SCAN_ONLY=true` must run only the needed
  compilation, tests/coverage and analysis. Job rules must exclude image builds,
  packaging for release, publishing, deployment and version changes.
- The Sonar job consumes `SONAR_TOKEN` and fails visibly on scanner submission
  errors. The default branch must be protected to receive the protected token.
  Quality findings may remain non-blocking for delivery.

An app without this contract can be provisioned in Sonar but cannot be scanned
automatically. Missing contracts, unmapped workloads and unsupported sources fail
the discovery Job visibly while other valid repositories continue. Check the
Sonar project's source inventory to confirm that both backend and frontend were
analyzed; namespace discovery alone does not establish source coverage.

DevApp is the template: its `docs/code-quality.md` covers onboarding and manual
scans, and `docs/adr/0008-code-quality-and-verification.md` records the decision.
Other apps retain their own code-quality and deployment documentation. See
[delivery](delivery.md) for the shared CI/GitOps boundary.

## Credentials and operation

[`configure-sonar-discovery.sh`](../scripts/configure-sonar-discovery.sh), invoked
by `configure-gitlab-ci.sh`, provisions a dedicated GitLab group Maintainer API
token in Vault at `secret/infra/gitlab:sonar_discovery_api_token`. External Secrets
projects it into `infra`; Sonar administration uses the existing Vault-backed
admin token. Rerun the configurator before expiry; it reuses valid credentials
and renews them within the renewal window declared in that script. Discovery
itself does not renew the group token.

Kubernetes permissions allow only workload listing in `apps` and Application
listing in `infra`; the service account cannot read application Secrets or
corporate workloads. The controller has no PVC, source checkout or build cache.
Completed Jobs expire through their declared TTL/history limits.

Inspect discovery or request an immediate discovery pass:

```sh
kubectl -n infra get cronjob sonar-apps-discovery
kubectl -n infra logs -l app=sonar-apps-discovery --prefix
JOB_NAME="sonar-apps-manual-$(date +%s)"
kubectl -n infra create job "$JOB_NAME" --from=cronjob/sonar-apps-discovery
kubectl -n infra logs -f "job/$JOB_NAME"
```

This discovery pass still follows freshness and retry rules; use the scan-only
GitLab pipeline for an explicit manual analysis.
Check the resulting quality job and Sonar analysis timestamp. Submission precedes
server-side processing, and a failed quality gate differs from submission failure.

## Validation

`./scripts/test-sonar-discovery.sh` checks namespace boundaries, deduplication,
privacy, scan-only triggers, active/recent work and missing contracts. Each app's
`infra/scripts/test-quality.sh` checks successful submission, scanner failure and
missing-token behavior. Validate app CI with both values of `SONAR_SCAN_ONLY` and
confirm that a scan-only pipeline cannot publish or deploy. The platform's
[validation suite](operations.md#validation) includes discovery tests.
