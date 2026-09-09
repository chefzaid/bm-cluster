FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/kubernetes-csi/node-driver-registrar.git \
    && git fetch --no-tags --depth 1 origin c5794c45f34ce9c62e47dfd5a2b073c3824f2c79 && git checkout --detach FETCH_HEAD
RUN git tag v2.17.0 c5794c45f34ce9c62e47dfd5a2b073c3824f2c79
COPY csi-node-driver-registrar.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./pkg/... \
    && go build -p 2 -trimpath -ldflags="-s -w -X main.version=v2.17.0" -o /out/csi-node-driver-registrar ./cmd/csi-node-driver-registrar
FROM docker.io/longhornio/csi-node-driver-registrar@sha256:29f7cfd519008fe8f8dff5e79db43f70d65c43a89c08f1bafbb199ca90df79f0
COPY --from=build /out/csi-node-driver-registrar /csi-node-driver-registrar
