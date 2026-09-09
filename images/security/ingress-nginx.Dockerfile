FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/kubernetes/ingress-nginx.git \
    && git fetch --no-tags --depth 1 origin 0a5901f3c64f11e92e487799b8da3f00cca37515 && git checkout --detach FETCH_HEAD
RUN git tag v1.15.1 0a5901f3c64f11e92e487799b8da3f00cca37515
COPY ingress-nginx.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOFLAGS=-mod=mod
RUN go test -p 2 ./internal/ingress/annotations/... ./internal/ingress/controller/template/... \
    && go build -p 2 -trimpath -ldflags="-s -w -X k8s.io/ingress-nginx/version.RELEASE=v1.15.1 -X k8s.io/ingress-nginx/version.COMMIT=0a5901f3c64f11e92e487799b8da3f00cca37515 -X k8s.io/ingress-nginx/version.REPO=https://github.com/kubernetes/ingress-nginx" -o /out/nginx-ingress-controller ./cmd/nginx \
    && go build -p 2 -trimpath -ldflags="-s -w -X k8s.io/ingress-nginx/version.RELEASE=v1.15.1 -X k8s.io/ingress-nginx/version.COMMIT=0a5901f3c64f11e92e487799b8da3f00cca37515 -X k8s.io/ingress-nginx/version.REPO=https://github.com/kubernetes/ingress-nginx" -o /out/dbg ./cmd/dbg \
    && go build -p 2 -trimpath -ldflags="-s -w -X k8s.io/ingress-nginx/version.RELEASE=v1.15.1 -X k8s.io/ingress-nginx/version.COMMIT=0a5901f3c64f11e92e487799b8da3f00cca37515 -X k8s.io/ingress-nginx/version.REPO=https://github.com/kubernetes/ingress-nginx" -o /out/wait-shutdown ./cmd/waitshutdown
FROM registry.k8s.io/ingress-nginx/controller@sha256:594ceea76b01c592858f803f9ff4d2cb40542cae2060410b2c95f75907d659e1
USER root
RUN apk upgrade --no-cache
COPY --from=build /out/nginx-ingress-controller /nginx-ingress-controller
COPY --from=build /out/dbg /dbg
COPY --from=build /out/wait-shutdown /wait-shutdown
USER 101
