FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS build
RUN apk add --no-cache git patch
WORKDIR /src
RUN git init && git remote add origin https://github.com/aquasecurity/trivy-operator.git \
    && git fetch --depth 1 origin 7107830178ae50e96e9f09d98976e51e6152759f \
    && git checkout --detach FETCH_HEAD
COPY trivy-operator.patch /tmp/operator.patch
RUN git apply --check /tmp/operator.patch && git apply /tmp/operator.patch
ENV CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=2GiB GOEXPERIMENT=jsonv2
RUN go test -p 2 ./pkg/vulnerabilityreport ./pkg/policy ./pkg/operator/workload \
    && go build -p 2 -trimpath -ldflags="-s -w -X main.version=0.34.0-swirlit.2 -X main.commit=7107830178ae50e96e9f09d98976e51e6152759f" -o /out/trivy-operator ./cmd/trivy-operator
FROM docker.io/library/alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
RUN apk upgrade --no-cache && apk add --no-cache ca-certificates
COPY --from=build /out/trivy-operator /usr/local/bin/trivy-operator
USER 10001:10001
ENTRYPOINT ["trivy-operator"]
