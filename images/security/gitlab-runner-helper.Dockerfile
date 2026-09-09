FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS runner-build
RUN apk add --no-cache git bash openssh-client curl tzdata \
    && addgroup -g 1000 builder && adduser -D -u 1000 -G builder builder
WORKDIR /src
RUN git init && git remote add origin https://gitlab.com/gitlab-org/gitlab-runner.git \
    && git fetch --no-tags --depth 1 origin a16f5092084b0373ebc30c6910f8972997e44b70 && git checkout --detach FETCH_HEAD \
    && git tag v19.3.1 a16f5092084b0373ebc30c6910f8972997e44b70
COPY gitlab-runner.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch \
    && mkdir -p tmp/gitlab-test && git -C tmp/gitlab-test init \
    && git -C tmp/gitlab-test remote add origin https://gitlab.com/gitlab-org/ci-cd/gitlab-runner-pipeline-tests/gitlab-test.git \
    && git -C tmp/gitlab-test fetch --depth 1 origin 6353879af977aed75f7f75b7f8084a5cb6f1177a \
    && git -C tmp/gitlab-test checkout --detach FETCH_HEAD \
    && mkdir /out && chown -R builder:builder /src /out
USER builder
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./common/... ./helpers/... ./executors/kubernetes/... ./network/... \
    && go build -p 2 -trimpath -ldflags="-s -w -X gitlab.com/gitlab-org/gitlab-runner/common.NAME=gitlab-runner -X gitlab.com/gitlab-org/gitlab-runner/common.VERSION=19.3.1 -X gitlab.com/gitlab-org/gitlab-runner/common.REVISION=a16f5092 -X gitlab.com/gitlab-org/gitlab-runner/common.BRANCH=19-3-stable" -o /out/gitlab-runner . \
    && go build -p 2 -trimpath -ldflags="-s -w -X gitlab.com/gitlab-org/gitlab-runner/common.NAME=gitlab-runner -X gitlab.com/gitlab-org/gitlab-runner/common.VERSION=19.3.1 -X gitlab.com/gitlab-org/gitlab-runner/common.REVISION=a16f5092 -X gitlab.com/gitlab-org/gitlab-runner/common.BRANCH=19-3-stable" -o /out/gitlab-runner-helper ./apps/gitlab-runner-helper
FROM registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:x86_64-v19.3.1@sha256:ce41f9ba0465950d1c7e290e38e33ea9064385b4015ba4fa4b12b318a6242682
USER root
RUN apk upgrade --no-cache
COPY --from=runner-build /out/gitlab-runner-helper /usr/bin/gitlab-runner-helper
