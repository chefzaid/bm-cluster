FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/kubernetes-csi/external-resizer.git \
    && git fetch --no-tags --depth 1 origin 32c003dbad0ec50d449b69cdddc5a7ba07a80cb8 && git checkout --detach FETCH_HEAD
RUN git tag v2.2.1 32c003dbad0ec50d449b69cdddc5a7ba07a80cb8
COPY csi-resizer.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./pkg/... \
    && go build -p 2 -trimpath -ldflags="-s -w -X main.version=v2.2.1" -o /out/csi-resizer ./cmd/csi-resizer
FROM docker.io/longhornio/csi-resizer@sha256:63d0aef25114d4a682b25afa6d9623a3cfcc19aca910269124408476bbe2c6fd
COPY --from=build /out/csi-resizer /csi-resizer
