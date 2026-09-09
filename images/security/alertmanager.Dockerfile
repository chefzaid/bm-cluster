FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS source
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/prometheus/alertmanager.git \
    && git fetch --depth 1 origin 085f0ef7eb41da24cab8cd000f1345b6250f2edb \
    && git checkout --detach FETCH_HEAD
COPY alertmanager.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB
FROM docker.io/library/node:24.19.0-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 AS ui
WORKDIR /ui
COPY --from=source /src/ui/app/ ./
RUN npm ci --no-audit --no-fund && npm run build
FROM source AS build
COPY --from=ui /ui/dist/ /src/ui/app/dist/
RUN go test -p 2 ./config ./notify/... ./ui \
    && go build -p 2 -trimpath -ldflags="-s -w -X github.com/prometheus/common/version.Version=0.34.0-swirlit.1" -o /out/alertmanager ./cmd/alertmanager \
    && go build -p 2 -trimpath -ldflags="-s -w -X github.com/prometheus/common/version.Version=0.34.0-swirlit.1" -o /out/amtool ./cmd/amtool
FROM quay.io/prometheus/alertmanager@sha256:9e082985f56f4c8c9f724e18f2288c6708f472e56a5286b8863d080434ea065d
COPY --from=build /out/alertmanager /bin/alertmanager
COPY --from=build /out/amtool /bin/amtool
