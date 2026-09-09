FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/kubernetes-sigs/metrics-server.git \
    && git fetch --no-tags --depth 1 origin 2a7c4b2c7d46552ff47f4aeaa3a735c582587ecd && git checkout --detach FETCH_HEAD
RUN git tag v0.9.0 2a7c4b2c7d46552ff47f4aeaa3a735c582587ecd
COPY metrics-server.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./pkg/... \
    && go build -p 2 -trimpath -ldflags="-s -w -X k8s.io/client-go/pkg/version.gitVersion=v0.9.0 -X k8s.io/client-go/pkg/version.gitCommit=2a7c4b2c7d46552ff47f4aeaa3a735c582587ecd" -o /out/metrics-server ./cmd/metrics-server
FROM docker.io/rancher/mirrored-metrics-server@sha256:d9862115e7c7881280d3d75ca26bda8ffc0fc213315979575bf23ce9826205c0
COPY --from=build /out/metrics-server /metrics-server
