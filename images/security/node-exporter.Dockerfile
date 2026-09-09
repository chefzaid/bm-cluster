FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git perl
WORKDIR /src
RUN git init && git remote add origin https://github.com/prometheus/node_exporter.git \
    && git fetch --depth 1 origin 6044da783597cc3b57aef7580ddcdcff58a4ee99 \
    && git checkout --detach FETCH_HEAD
COPY node-exporter.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB
RUN ./ttar -C collector/fixtures -x -f collector/fixtures/sys.ttar \
    && ./ttar -C collector/fixtures -x -f collector/fixtures/udev.ttar \
    && go test -p 2 ./collector \
    && go build -p 2 -trimpath -ldflags="-s -w -X github.com/prometheus/common/version.Version=1.12.1-swirlit.1" -o /out/node_exporter .
FROM quay.io/prometheus/node-exporter@sha256:da83fae85603c4e47e6c68369a7d746e2dda683dc35ea2e234b4f171e0d92798
COPY --from=build /out/node_exporter /bin/node_exporter
