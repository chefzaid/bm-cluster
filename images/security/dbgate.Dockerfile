FROM docker.io/dbgate/dbgate@sha256:03956fb18367a2b1d736b4ebb702401c68ec5f7bde691f9ea2412c3df0c27e34
USER root
# Preserve the supported Node 22 runtime and native database-driver ABI. The
# upstream Alpine variant still embeds Node 18 and is not a safe replacement.
RUN apt-get update && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global --ignore-scripts npm@12.0.2 \
    && npm cache clean --force
# npm's published bundle includes development-only metadata referring to
# unpublished workspace packages. Keep its runtime dependency graph only.
RUN node -e 'const fs=require("node:fs"); const p="/usr/local/lib/node_modules/npm/package.json"; const pkg=JSON.parse(fs.readFileSync(p)); delete pkg.devDependencies; delete pkg.workspaces; fs.writeFileSync(p,JSON.stringify(pkg,null,2)+"\n")' \
    && npm install --prefix /usr/local/lib/node_modules/npm --ignore-scripts \
        --omit=dev --no-package-lock --no-audit --no-fund \
        brace-expansion@5.0.9 ip-address@10.3.1 tar@7.5.21 undici@6.28.0 \
    && npm cache clean --force
USER 10001:10001
