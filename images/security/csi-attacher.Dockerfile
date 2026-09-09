FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/kubernetes-csi/external-attacher.git \
    && git fetch --no-tags --depth 1 origin f395fb4ff4d3fb41d2e2dfde0f8373d9e7162aeb && git checkout --detach FETCH_HEAD
RUN git tag v4.12.0 f395fb4ff4d3fb41d2e2dfde0f8373d9e7162aeb
COPY csi-attacher.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./pkg/... \
    && go build -p 2 -trimpath -ldflags="-s -w -X main.version=v4.12.0" -o /out/csi-attacher ./cmd/csi-attacher
FROM docker.io/longhornio/csi-attacher@sha256:a814aa4784197116983ea13e376fc691e000a390de9d0b9fca2bc4a2fb7c4a1f
COPY --from=build /out/csi-attacher /csi-attacher
