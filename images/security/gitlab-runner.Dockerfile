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
FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS machine-build
RUN apk add --no-cache git bash openssh-client \
    && addgroup -g 1000 builder && adduser -D -u 1000 -G builder builder
WORKDIR /src
RUN git init && git remote add origin https://gitlab.com/gitlab-org/ci-cd/docker-machine.git \
    && git fetch --no-tags --depth 1 origin 7e13feeb34e436fbb895cb03fb5386185b68b720 && git checkout --detach FETCH_HEAD \
    && git tag v0.16.2-gitlab.51 7e13feeb34e436fbb895cb03fb5386185b68b720
COPY docker-machine.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch \
    && mkdir /out && chown -R builder:builder /src /out
USER builder
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./libmachine/... ./commands/... \
    && go build -p 2 -trimpath -tags=static_build,netgo -ldflags="-s -w -X github.com/docker/machine/version.Version=0.16.2-gitlab.51 -X github.com/docker/machine/version.GitCommit=7e13feeb" -o /out/docker-machine ./cmd/docker-machine
FROM docker.io/gitlab/gitlab-runner:alpine-v19.3.1@sha256:af0325804248aee217e055e753add77ccaaba6c8f5e2143b01108fd401165ef3
USER root
RUN apk upgrade --no-cache
COPY --from=runner-build /out/gitlab-runner /usr/bin/gitlab-runner
COPY --from=machine-build /out/docker-machine /usr/bin/docker-machine
RUN sed -i "s/^gitlab-runner:x:[0-9]*:[0-9]*:/gitlab-runner:x:10001:10001:/" /etc/passwd \
    && sed -i "s/^gitlab-runner:x:[0-9]*:/gitlab-runner:x:10001:/" /etc/group \
    && chown -R 10001:10001 /home/gitlab-runner \
    && test "$(id -u gitlab-runner)" = 10001 && test "$(id -g gitlab-runner)" = 10001
USER 10001:10001
