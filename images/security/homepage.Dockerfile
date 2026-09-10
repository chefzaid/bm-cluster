FROM docker.io/library/node:22.23.2-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32 AS build
RUN apk add --no-cache git && npm install --global pnpm@10.34.5
WORKDIR /app
RUN git init && git remote add origin https://github.com/gethomepage/homepage.git \
    && git fetch --depth=1 origin 22f1317ad3933fb8f9d85f31ee02aaf50f5f0a32 \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = 22f1317ad3933fb8f9d85f31ee02aaf50f5f0a32
COPY homepage.patch /tmp/homepage.patch
RUN git apply --check /tmp/homepage.patch && git apply /tmp/homepage.patch \
    && pnpm install --frozen-lockfile --ignore-scripts
ENV NEXT_TELEMETRY_DISABLED=1 \
    NEXT_PUBLIC_VERSION=v2.2.0 \
    NEXT_PUBLIC_REVISION=22f1317ad3933fb8f9d85f31ee02aaf50f5f0a32 \
    NEXT_PUBLIC_BUILDTIME=2026-09-10T00:00:00Z \
    NODE_OPTIONS=--max-old-space-size=1536
RUN pnpm exec vitest run --maxWorkers=1 --pool=forks && pnpm run build

FROM docker.io/library/node:22.23.2-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32
WORKDIR /app
RUN apk upgrade --no-cache && apk add --no-cache su-exec iputils-ping shadow \
    && rm -rf /usr/local/lib/node_modules/npm /opt/yarn-* \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg
COPY --from=build --chown=10001:10001 /app/public/ ./public/
COPY --from=build --chown=10001:10001 /app/.next/standalone/ ./
COPY --from=build --chown=10001:10001 /app/.next/static/ ./.next/static/
COPY --from=build /app/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN mkdir -p /app/config/logs /app/.next/cache \
    && chown -R 10001:10001 /app/config /app/.next/cache \
    && chmod 755 /usr/local/bin/docker-entrypoint.sh
ENV NODE_ENV=production HOSTNAME=:: PORT=3000
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s \
    CMD wget --no-verbose --tries=1 --spider -Y off http://127.0.0.1:$PORT/api/healthcheck || exit 1
USER 10001:10001
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "server.js"]
