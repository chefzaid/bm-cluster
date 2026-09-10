FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git make python3
WORKDIR /src
RUN git init && git remote add origin https://github.com/external-secrets/external-secrets.git \
    && git fetch --depth=1 origin refs/tags/v2.10.0:refs/tags/v2.10.0 \
    && git checkout --detach 'v2.10.0^{commit}' \
    && test "$(git rev-parse HEAD)" = 279f56c84d5d4058c3bfdeeaf5b1c2febb8851c0
COPY external-secrets.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
COPY external-secrets-version.patch /tmp/version.patch
RUN git apply --check /tmp/version.patch && git apply /tmp/version.patch
COPY external-secrets/ /security/
ENV CGO_ENABLED=0 GOMAXPROCS=1 GOMEMLIMIT=1800MiB GOGC=20 \
    GOTOOLCHAIN=local GOWORK=off GOFLAGS=-mod=readonly
# Test nested modules through their import paths from the root module. This
# selects the same patched dependency graph as the all-provider production build.
RUN make -f /security/Makefile security-unit security-build

FROM ghcr.io/external-secrets/external-secrets:v2.10.0@sha256:7881e1d92c771428f4f180f607b7418515a577094f911fd72cd8740f0234450e
COPY --from=build /out/external-secrets /bin/external-secrets
COPY --from=build /out/buildinfo.txt /usr/share/external-secrets/buildinfo.txt
COPY --from=build /out/application-version.txt /usr/share/external-secrets/application-version.txt
LABEL org.opencontainers.image.version="2.10.0+security.1" \
      org.opencontainers.image.revision="279f56c84d5d4058c3bfdeeaf5b1c2febb8851c0"
USER 10001:10001
