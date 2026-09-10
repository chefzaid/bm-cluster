FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/coredns/coredns.git \
    && git fetch --depth 1 origin refs/tags/v1.14.7:refs/tags/v1.14.7 \
    && git checkout --detach v1.14.7 \
    && test "$(git rev-parse HEAD)" = 427fc80ed9ca47f354585eb30a3f1332950856c4
COPY coredns.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=1 GOMEMLIMIT=1400MiB GOFLAGS=-mod=readonly
RUN go test -p 1 ./core/dnsserver ./plugin/health ./plugin/kubernetes \
    && go build -p 1 -trimpath -ldflags="-s -w" -o /out/coredns .
FROM docker.io/coredns/coredns@sha256:7efd3c635b03efd68c4e8398fc45f0d993d0e9ab016f72c1cefb0fd6d01aa286
COPY --from=build /out/coredns /coredns
USER 65534:65534
