FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/kubernetes-csi/external-provisioner.git \
    && git fetch --no-tags --depth 1 origin 1a7e9381439295969ad0336f1e21791f7dc3abe8 && git checkout --detach FETCH_HEAD
RUN git tag v5.3.0 1a7e9381439295969ad0336f1e21791f7dc3abe8
COPY csi-provisioner.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./pkg/... \
    && go build -p 2 -trimpath -ldflags="-s -w -X main.version=v5.3.0" -o /out/csi-provisioner ./cmd/csi-provisioner
FROM docker.io/longhornio/csi-provisioner@sha256:1bbb7b11d8087130e722e3249f364d0ab49ee3545e847c2f299e87b7e1ce5c4f
COPY --from=build /out/csi-provisioner /csi-provisioner
