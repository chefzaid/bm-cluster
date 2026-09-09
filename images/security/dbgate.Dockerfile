FROM docker.io/dbgate/dbgate@sha256:03956fb18367a2b1d736b4ebb702401c68ec5f7bde691f9ea2412c3df0c27e34 AS application
USER root
# Retain DBGate's application and native Node 22 addons. Only the runtime OS is
# replaced; Wolfi supplies glibc, preserving the addons' GNU libc ABI.
RUN npm install --global --ignore-scripts npm@12.0.2 \
    && npm cache clean --force
# npm's published bundle includes development-only metadata referring to
# unpublished workspace packages. Keep its runtime dependency graph only.
RUN node -e 'const fs=require("node:fs"); const p="/usr/local/lib/node_modules/npm/package.json"; const pkg=JSON.parse(fs.readFileSync(p)); delete pkg.devDependencies; delete pkg.workspaces; fs.writeFileSync(p,JSON.stringify(pkg,null,2)+"\n")' \
    && npm install --prefix /usr/local/lib/node_modules/npm --ignore-scripts \
        --omit=dev --no-package-lock --no-audit --no-fund \
        brace-expansion@5.0.9 ip-address@10.3.1 tar@7.5.21 undici@6.28.0 \
    && npm cache clean --force
FROM cgr.dev/chainguard/wolfi-base@sha256:918a593b8268c222afd4e2c4f06860ac984e60719b4697e4c71d796bc8fcd042
RUN apk upgrade --no-cache \
    && apk add --no-cache nodejs-22 libstdc++ libgcc libaio openssl ca-certificates tzdata \
    && addgroup -g 10001 node && adduser -D -u 10001 -G node -h /home/node node
COPY --from=application /home/dbgate-docker /home/dbgate-docker
COPY --from=application /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN mkdir -p /usr/local/bin \
    && ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
ENV PATH="/usr/local/bin:/usr/bin:/bin" HOME="/home/node" WORKSPACE_DIR="/home/node/.dbgate"
WORKDIR /home/dbgate-docker
USER 10001:10001
EXPOSE 3000
# The upstream Docker-only wrapper tries to rewrite /etc/hosts. Kubernetes owns
# DNS and /etc/hosts; start the same API process directly on a read-only root.
ENTRYPOINT ["node"]
CMD ["bundle.js", "--listen-api"]
