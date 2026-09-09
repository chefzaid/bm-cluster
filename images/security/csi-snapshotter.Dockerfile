FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/kubernetes-csi/external-snapshotter.git \
    && git fetch --no-tags --depth 1 origin 78e32cd84e0abec2621924a30e38c755f93e180a && git checkout --detach FETCH_HEAD
RUN git tag v8.6.0 78e32cd84e0abec2621924a30e38c755f93e180a
COPY csi-snapshotter.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./pkg/... \
    && go build -p 2 -trimpath -ldflags="-s -w -X main.version=v8.6.0" -o /out/csi-snapshotter ./cmd/csi-snapshotter
FROM docker.io/longhornio/csi-snapshotter@sha256:2bca9ac55170efa61dc50e5cc8d9550373db2e3e5161d82d3fdaac5c25150360
COPY --from=build /out/csi-snapshotter /csi-snapshotter
