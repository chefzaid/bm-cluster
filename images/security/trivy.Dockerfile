FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git init && git remote add origin https://github.com/aquasecurity/trivy.git \
    && git fetch --depth 1 origin e1fd17a0ea4a8cf24bc4b4dd7e2cfbf4bb31b994 \
    && git checkout --detach FETCH_HEAD
COPY trivy.patch /tmp/trivy.patch
RUN git apply --check /tmp/trivy.patch && git apply /tmp/trivy.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=2GiB GOEXPERIMENT=jsonv2
RUN go build -p 2 -trimpath -ldflags="-s -w -X github.com/aquasecurity/trivy/pkg/version/app.ver=0.74.0-swirlit.2" -o /out/trivy ./cmd/trivy
FROM docker.io/library/alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
RUN apk upgrade --no-cache && apk add --no-cache ca-certificates git
COPY --from=build /out/trivy /usr/local/bin/trivy
USER 65534:65534
ENTRYPOINT ["trivy"]
