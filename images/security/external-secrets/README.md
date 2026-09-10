# External Secrets Operator security rebuild

This recipe prepares ESO 2.10.0 from commit
`279f56c84d5d4058c3bfdeeaf5b1c2febb8851c0`, with Go 1.26.7 and the complete
upstream `all_providers` build. It retains the upstream runtime base and all
provider/generator registrations. The controller, certificate controller and
admission webhook are subcommands of the same binary.

The dependency patch updates CEL to 0.29.0, MongoDB driver to 1.17.9,
`x/crypto` to 0.56.0, gRPC to 1.83.2 and `x/mod` to 0.40.0, together with the
transitive changes selected by Go. Checksums are preserved in `go.sum`; builds
use `-mod=readonly` and assert the patched versions in the compiled binary.
The module-level Unknown advisory
[GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932) has no fixed version and
remains visible. It concerns the unmaintained `x/crypto/openpgp` packages;
the compiled binary contains no OpenPGP symbols. This observation does not
replace the raw scanner result or a formal reachability analysis.

The candidate remains unpublished and undeployed. The shared catalog and
chart selections have not changed. Complete the promotion checks below
before publishing a replacement pin.
Use a serialized build with a 4 GiB memory limit once the host has capacity;
the provider SDK graph is large. Compilation uses one worker, `GOGC=20` and an
1800 MiB Go memory target. Generated Microsoft Graph model packages receive
package-specific `-l` flags if present, preserving all provider features and
the normal optimization of other packages. This dependency graph does not
currently select Microsoft Graph modules. The build runs the upstream API validation,
runtime, Vault provider/generator and controller-command unit tests. These tests
select dependencies through the root module's local replacements, so they
exercise the same versions as the production binary, without rewriting every
provider module's own development lockfile.

The version patch exposes `external-secrets version 2.10.0+security.1`, checked
against the verified upstream tag and `UPSTREAM_VERSION` fixture. The build
retains the ELF version symbol and explicitly sets the binary mode to 0755 so
the configured runtime UID can execute it even after a restrictive host umask.

## Chart and API compatibility

Use the separately published Helm chart **2.10.0**. The application source tag
still contains chart metadata for 2.9.0. The published chart archive has SHA-256
`b96e948fff3674638b5d3f9e43886f3796e04739c4b4127929aed2ddac7d1418`.
With the platform's existing values, chart 2.9.0 and 2.10.0 both render 44
resources and 25 CRDs, with unchanged object identities and served/storage
versions. Vault schemas are unchanged. Other provider schema changes include
new GitHub fields and tighter Nebius authentication validation; review these
for installations using those providers. The existing UID/GID 10001,
read-only filesystem, dropped capabilities, resource limits and seccomp
settings remain present in all three rendered Deployments.
Repeat the structural checks with
`scripts/test-external-secrets-compatibility.py OLD_RENDER NEW_RENDER --report PRIVATE_REPORT`;
the report retains other providers' changes for review.

## Required verification before promotion

1. Run the full multistage Docker build, review its recorded Go build information, and scan the
   exact candidate digest with vulnerability and secret scanners at every
   severity. The public 2.10.0 image still has eight findings; do not substitute
   it for the rebuilt candidate or claim zero from a source-only scan.
2. Run `scripts/test-external-secrets-source.sh SOURCE PRIVATE_LOG_DIRECTORY`
   with verified Kubernetes 1.36 `KUBEBUILDER_ASSETS`. This runs the existing
   controller integration suites against disposable local API-server/etcd
   processes, plus the unit suites used in the image build. It explicitly
   disables `USE_EXISTING_CLUSTER` and clears inherited Kubernetes credentials.
   The suites cover ExternalSecret/SecretStore reconciliation, updates, failure
   paths, CRDs, webhook certificate configuration and push-secret controllers.
   Set `EXTERNAL_SECRETS_GO` when the pinned Go 1.26.7 executable is outside
   `PATH`; GNU Make is required on the test host and can be selected using
   `EXTERNAL_SECRETS_MAKE`.
3. Run `scripts/test-external-secrets-image.py` as described below. It uses the
   final image for the controller and admission webhook, genuine Kubernetes
   service-account TokenRequests and a disposable Vault instance. It asserts
   actual destination Secret values, two rotations, unauthorized-path denial,
   forged-token and unbound-identity rejection, then valid-auth recovery.
4. The same canary submits valid and invalid SecretStore/ExternalSecret objects
   through the candidate webhook over verified TLS. Cross-namespace credential
   references and conflicting deletion policies must be rejected by admission.
   Controller restart and webhook certificate replacement must preserve these
   checks and reconciliation. Controller unit tests alone do not validate the
   final image or TLS routing.
5. Before the real upgrade, preserve the Helm release values and CRDs privately,
   inventory every ExternalSecret/ClusterSecretStore readiness condition, and
   verify the rendered manifest with server-side dry-run. Update the shared
   installer/Ansible chart version and all three image selections together.
   After rollout, verify every store/secret is Ready, synthetic rotation works,
   all three workloads are healthy, and fresh Trivy reports match their digests.

## Final-image canary

The host needs Linux Docker bridge connectivity, Docker access, Python 3,
OpenSSL and `kubectl`. Both image arguments must already exist locally; the
script resolves their immutable image IDs and uses `--pull=never`. Supply the
exact upstream source checkout and verified Kubernetes 1.36 envtest binaries.
The trusted checksum file contains SHA-256 values under `kube-apiserver` and
`etcd`; obtain these from the verified asset archive before running the canary.

```sh
python3 scripts/test-external-secrets-image.py "$ESO_CANDIDATE_IMAGE" \
  --vault-image "$VAULT_FIXTURE_IMAGE" \
  --source "$ESO_SOURCE" \
  --assets "$KUBEBUILDER_ASSETS" \
  --asset-checksums "$PRIVATE_EVIDENCE/envtest-binary-checksums.json" \
  --logs "$PRIVATE_EVIDENCE/eso-final-image-canary"
```

The log directory must be new and outside the workspace. Its permissions and
all fixture credentials are private. A newly created internal Docker network
contains API server, etcd, Vault, controller and webhook containers. Their
combined memory limits are 2.5 GiB and combined CPU limit is 2.5 cores; etcd
data is disposable and bounded. All containers use UID/GID 10001, read-only
roots, dropped capabilities and no published ports. The API and webhook use a
fresh private CA. The controller's fixture kubeconfig and every `kubectl`
command target only the disposable API, whose CRDs come from the verified
source commit. This fixture does not require a scheduler, nodes or production
cluster access.

On success, failure or ordinary interruption, the canary saves component logs
and `result.json`, removes its containers and network, and deletes the fixture
keys, tokens and data. Vault's synthetic root token is redacted from saved
logs. Any cleanup failure fails the canary and identifies the owned resource
in `result.json`. Only schedule this test when capacity is available; it does
not launch compilation or download images.

## Verification on 2026-09-10

The maintained Makefile completed the complete `all_providers` binary build,
14 unit-test packages and 13 controller-test packages, including all seven
isolated Kubernetes 1.36.2 envtest suites. The host build used the pinned Go
1.26.7 compiler in a 4 GiB, one-CPU, no-swap scope, with no OOM events. Syntax,
Makefile dry-run, patch and chart compatibility checks also passed.

The validated host binary was assembled using the Dockerfile's exact final
runtime stage and pinned vendor base. A fresh build of the complete multistage
Dockerfile was **not run**. The first local image inherited mode 0700 from the
private host output and failed to launch as UID 10001. The maintained Makefile
now normalizes the executable to 0755. Reassembling only the runtime stage
preserved the binary SHA-256
`cfb8f92e8e469896c45fb9cdf8e23008e23147cd31584fd962b3a9d70a34db3f`;
the image member is root-owned 0755 and `--version` works as UID 10001.

The corrected local image ID is
`sha256:192791310d893347cf8194940014caa6fc212aa7648b74cfee5de427837f6375`.
This is a local image ID, not a published registry manifest digest. Its fresh
Trivy vulnerability and secret scan reported **0 Critical, 0 High, 0 Medium,
0 Low, 1 Unknown and 0 secrets**. The Unknown is GO-2026-5932 above; no finding
was excluded. The scanner still leaves the main application module's version
blank despite the verified CLI and ELF metadata, so version attribution needs
review before promotion. The public 2.10.0 vendor image had eight findings in
the preceding scan.

The corrected image passed all eight canary checks with the separately
verified Vault 2.1.0 security build and Kubernetes 1.36.2: real Kubernetes
authentication, namespaced and cluster-scoped stores, actual Secret values,
rotation, unauthorized paths, forged JWTs, unbound identities, admission
validation, controller restart and webhook certificate replacement. Cleanup
left no fixture containers, networks or credential directories. The fixture
also passed earlier against vendor ESO 2.10.0 and Vault 2.1.0. Both the diagnosed
first failure and successful rerun remain in private evidence alongside the
image scan and source-build logs.

The preparation does not change the platform catalog, installer, Helm values,
live controllers, or CRDs. A full upstream contribution additionally follows
the upstream `make test` / `make check-diff` workflow.
