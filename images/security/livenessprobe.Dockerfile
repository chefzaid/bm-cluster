FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/kubernetes-csi/livenessprobe.git \
    && git fetch --no-tags --depth 1 origin d2d15a5e8217cc9f8680821ee649b6a051b38d96 && git checkout --detach FETCH_HEAD
RUN git tag v2.19.0 d2d15a5e8217cc9f8680821ee649b6a051b38d96
COPY livenessprobe.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./cmd/... \
    && go build -p 2 -trimpath -ldflags="-s -w -X main.version=v2.19.0" -o /out/livenessprobe ./cmd/livenessprobe
FROM docker.io/longhornio/livenessprobe@sha256:d0cb76b565ba9d36da0dc2b38e2b6a49a0ae4fe067b03086110682f32c600318
COPY --from=build /out/livenessprobe /livenessprobe
