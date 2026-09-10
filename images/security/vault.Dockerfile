FROM docker.io/hashicorp/vault@sha256:783103ba38c5e3edcaa9bbbcb0ff80fc93c690361f03fd487e89227da6c3efa9 AS vendor

FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git python3
WORKDIR /src
RUN git init && git remote add origin https://github.com/hashicorp/vault.git \
    && git fetch --depth=1 origin cb6a54face072e372480d7cc2e64a3110b84756f \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = cb6a54face072e372480d7cc2e64a3110b84756f \
    && test "$(cat version/VERSION)" = 2.1.0
COPY vault.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
COPY vault-ui.py /tmp/vault-ui.py
COPY --from=vendor /bin/vault /tmp/vault-vendor
# The UI is embedded in the vendor binary. Preserve every asset, verifying the
# pinned compiler's content hashes; no frontend version metadata is rewritten.
RUN python3 /tmp/vault-ui.py /tmp/vault-vendor /tmp/vendor-ui --manifest /tmp/vendor-ui.json \
    && cp -a /tmp/vendor-ui/. http/web_ui/ \
    && rm -rf /tmp/vendor-ui /tmp/vault-vendor
# Disable inlining only for the enormous generated Microsoft Graph models.
# This preserves the provider API while reducing compiler memory pressure.
ENV CGO_ENABLED=0 GOMAXPROCS=1 GOMEMLIMIT=1800MiB GOGC=20 \
    GOTOOLCHAIN=local GOWORK=off \
    GOFLAGS="-mod=readonly -gcflags=github.com/microsoftgraph/msgraph-sdk-go/models=-l"
# Retain ELF symbols and stamp the verified release version. With trimpath,
# scanners otherwise see only a v0.0.0 VCS pseudo-version for this module.
RUN go build -p 1 -trimpath -tags ui \
      -ldflags='-w -X github.com/hashicorp/vault/version.Version=2.1.0 -X github.com/hashicorp/vault/version.GitCommit=cb6a54face072e372480d7cc2e64a3110b84756f+security -X github.com/hashicorp/vault/version.BuildDate=2026-09-10T00:00:00Z' \
      -o /out/vault . \
    && go test -short -p 1 ./version ./helper/pgpkeys ./physical/raft \
    && python3 /tmp/vault-ui.py /out/vault /tmp/candidate-ui --manifest /tmp/candidate-ui.json \
    && python3 -c 'import json; assert json.load(open("/tmp/vendor-ui.json"))["files"] == json.load(open("/tmp/candidate-ui.json"))["files"]'

FROM vendor
USER root
RUN apk upgrade --no-cache
COPY --from=build /out/vault /bin/vault
USER 100:1000
