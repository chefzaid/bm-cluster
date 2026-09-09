FROM docker.io/library/golang:1.26.7-alpine@sha256:28d89ee9cc0ff9fec75c82ca201e6bf7fdf9a679d4b7b24dfa04f2bb766bb468 AS toolchain
FROM cgr.dev/chainguard/wolfi-base@sha256:918a593b8268c222afd4e2c4f06860ac984e60719b4697e4c71d796bc8fcd042 AS tools
RUN apk add --no-cache git gcc glibc-dev krb5-dev pkgconf
COPY --from=toolchain /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:$PATH CGO_ENABLED=1 GOMAXPROCS=2 GOMEMLIMIT=1400MiB
WORKDIR /src
RUN git init && git remote add origin https://github.com/mongodb/mongo-tools.git \
    && git fetch --depth 1 origin 21a342dfee6468ad9350d156d25086da64dd03b1 \
    && git checkout --detach FETCH_HEAD
COPY mongodb-tools.patch /tmp/dependencies.patch
RUN git apply --check /tmp/dependencies.patch && git apply /tmp/dependencies.patch
# Preserve the vendor's Kerberos authentication support and PIE build mode.
RUN go test -p 2 -tags=gssapi,failpoints ./common/archive ./common/json ./common/options \
    && for name in bsondump mongodump mongoexport mongofiles mongoimport mongorestore mongostat mongotop; do \
      go build -p 2 -trimpath -buildmode=pie -tags=gssapi,failpoints \
        -ldflags='-s -w -X main.VersionStr=100.18.0-swirlit.1 -X main.GitCommit=21a342dfee6468ad9350d156d25086da64dd03b1' \
        -o /out/$name ./$name/main; \
    done
FROM docker.io/library/mongo@sha256:8ef27524b4cde51b9f07bb0827a56d02c6d3b148d0b7d0ca8ff4dfd57351ff4f AS upstream
USER root
RUN apt-get update && apt-get install -y --no-install-recommends mongodb-mongosh=2.10.0 \
    && mkdir /vendor-licenses && cp -a /usr/share/doc/mongodb* /vendor-licenses/
FROM docker.io/library/node:24.19.0-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 AS yaml
WORKDIR /yaml
RUN npm pack --ignore-scripts js-yaml@3.15.1 && tar xzf js-yaml-3.15.1.tgz
FROM cgr.dev/chainguard/wolfi-base@sha256:918a593b8268c222afd4e2c4f06860ac984e60719b4697e4c71d796bc8fcd042
RUN apk upgrade --no-cache && apk add --no-cache bash jq numactl libcurl-openssl4 krb5-libs libgcc libstdc++ openssl ca-certificates tzdata \
 && mkdir -p /data/db && addgroup -g 999 mongodb && adduser -D -u 999 -G mongodb -h /data/db mongodb \
 && mkdir -p /data/db /data/configdb /docker-entrypoint-initdb.d && chown -R 999:999 /data
COPY --from=upstream /usr/bin/mongod /usr/bin/mongos /usr/bin/mongosh /usr/bin/
COPY --from=upstream /usr/lib/mongosh_crypt_v1.so /usr/lib/
COPY --from=upstream /vendor-licenses/ /usr/share/doc/
COPY --from=upstream /usr/local/bin/docker-entrypoint.sh /usr/local/bin/
RUN sed -i 's/dpkgArch="$(dpkg --print-architecture)"/case "$(uname -m)" in x86_64) dpkgArch=amd64;; aarch64) dpkgArch=arm64;; *) exit 1;; esac/' /usr/local/bin/docker-entrypoint.sh
COPY --from=yaml /yaml/package/dist/ /opt/js-yaml/dist/
COPY --from=yaml /yaml/package/package.json /opt/js-yaml/package.json
COPY --from=yaml /yaml/package/LICENSE /opt/js-yaml/LICENSE
COPY --from=tools /out/ /usr/bin/
ENV HOME=/data/db MONGO_PACKAGE=mongodb-org MONGO_REPO=repo.mongodb.org MONGO_MAJOR=7.0 MONGO_VERSION=7.0.40
USER 999:999
EXPOSE 27017
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["mongod"]
