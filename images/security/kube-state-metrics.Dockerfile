FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/kubernetes/kube-state-metrics.git \
    && git fetch --no-tags --depth 1 origin 4ffeda2ef866b0fef372849825a803296483b336 && git checkout --detach FETCH_HEAD
RUN git tag v2.20.0 4ffeda2ef866b0fef372849825a803296483b336
COPY kube-state-metrics.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./internal/store/... ./pkg/... \
    && go build -p 2 -trimpath -ldflags="-s -w -X github.com/prometheus/common/version.Version=v2.20.0 -X github.com/prometheus/common/version.Revision=4ffeda2ef866b0fef372849825a803296483b336 -X k8s.io/kube-state-metrics/v2/pkg/app.ClientGoVersion=v0.36.3" -o /out/kube-state-metrics .
FROM registry.k8s.io/kube-state-metrics/kube-state-metrics@sha256:01171220c7c059afc85034ffe687bfe7249e41c0cc46fbe9a5128503ceee3016
COPY --from=build /out/kube-state-metrics /kube-state-metrics
