FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git curl bash gzip
WORKDIR /src
RUN git init && git remote add origin https://github.com/prometheus/prometheus.git \
    && git fetch --depth 1 origin d7598b7141418fa35be2b5ec5d0fefb634199610 \
    && test "$(git rev-parse FETCH_HEAD)" = d7598b7141418fa35be2b5ec5d0fefb634199610 \
    && git checkout --detach FETCH_HEAD
COPY prometheus.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
# Keep the official UI for this exact release, including embedded static assets.
RUN curl --fail --silent --show-error --location https://github.com/prometheus/prometheus/releases/download/v3.14.0/prometheus-web-ui-3.14.0.tar.gz --output /tmp/ui.tar.gz \
    && echo 'be18623c5891d32572998070de0d48522c966b737d9204aa41e0e88d6318e029  /tmp/ui.tar.gz' | sha256sum -c - \
    && tar xzf /tmp/ui.tar.gz -C web/ui && rm /tmp/ui.tar.gz \
    && bash scripts/compress_assets.sh
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOTOOLCHAIN=local GOWORK=off GOFLAGS=-mod=readonly
RUN go build -p 1 -trimpath -tags netgo,builtinassets \
      -ldflags='-s -w -X github.com/prometheus/common/version.Version=3.14.0 -X github.com/prometheus/common/version.Revision=d7598b7141418fa35be2b5ec5d0fefb634199610 -X github.com/prometheus/common/version.Branch=security-patched' \
      -o /out/prometheus ./cmd/prometheus \
    && go build -p 1 -trimpath -tags netgo,builtinassets \
      -ldflags='-s -w -X github.com/prometheus/common/version.Version=3.14.0 -X github.com/prometheus/common/version.Revision=d7598b7141418fa35be2b5ec5d0fefb634199610 -X github.com/prometheus/common/version.Branch=security-patched' \
      -o /out/promtool ./cmd/promtool \
    && go test -short -p 1 -tags builtinassets ./config/... ./model/... ./discovery/... ./web/... ./scrape/...
FROM docker.io/prom/prometheus@sha256:e906cef998316bbe319f98711e1b4d8613ad37e14b08ff831d7036e77b7464f9
COPY --from=build /out/prometheus /bin/prometheus
COPY --from=build /out/promtool /bin/promtool
