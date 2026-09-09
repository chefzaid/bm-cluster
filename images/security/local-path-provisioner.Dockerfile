FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/rancher/local-path-provisioner.git \
    && git fetch --no-tags --depth 1 origin 49b2be8e26d6d34c9afaa21fa33108d2e82f8955 && git checkout --detach FETCH_HEAD
RUN git tag v0.0.37 49b2be8e26d6d34c9afaa21fa33108d2e82f8955
COPY local-path-provisioner.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./... \
    && go build -p 2 -trimpath -ldflags="-s -w -X main.VERSION=v0.0.37" -o /out/local-path-provisioner .
FROM docker.io/rancher/local-path-provisioner@sha256:e757967a5ec338f6a9b371c5a9688bedaa8c3578ea3dd4db329ea0084be0a86f
COPY --from=build /out/local-path-provisioner /usr/bin/local-path-provisioner
