FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/oauth2-proxy/oauth2-proxy.git \
    && git fetch --depth 1 origin 81ff034fe2ff3246e670c694b02e3267d1ae46bc \
    && git checkout --detach FETCH_HEAD
COPY oauth2-proxy.patch /tmp/oauth2-proxy.patch
RUN git apply --check /tmp/oauth2-proxy.patch && git apply /tmp/oauth2-proxy.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=2GiB
RUN go test -p 2 ./pkg/encryption ./pkg/cookies ./pkg/sessions/... ./providers \
    && go build -p 2 -trimpath -ldflags="-s -w -X github.com/oauth2-proxy/oauth2-proxy/v7/pkg/version.VERSION=7.15.4-swirlit.1" -o /out/oauth2-proxy .
FROM docker.io/library/alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
RUN apk upgrade --no-cache && apk add --no-cache ca-certificates tzdata
COPY --from=build /out/oauth2-proxy /bin/oauth2-proxy
USER 10001:10001
ENTRYPOINT ["/bin/oauth2-proxy"]
