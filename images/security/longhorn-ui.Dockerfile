FROM docker.io/longhornio/longhorn-ui:v1.12.1@sha256:03a3ce6673df6e948c261fe978a695adaa8fb190d68bfe5c358af8ee3d3fbef5 AS ui
FROM docker.io/library/nginx:1.30.4-alpine@sha256:dc5069ad14f19660b141b21236140b91656bf89bbc3e2417c70ae650cd66104c
RUN apk upgrade --no-cache && addgroup -g 10001 longhorn && adduser -D -u 10001 -G longhorn longhorn
COPY --from=ui /web/dist /web/dist
COPY --from=ui /etc/nginx/nginx.conf.template /etc/nginx/nginx.conf.template
RUN sed -i '1i pid /var/run/nginx.pid;\nerror_log /dev/stderr warn;' /etc/nginx/nginx.conf.template \
    && sed -i '/^http {/a\    access_log /dev/stdout;' /etc/nginx/nginx.conf.template
COPY longhorn-ui-entrypoint.sh /usr/local/bin/longhorn-ui-entrypoint.sh
RUN chmod 755 /usr/local/bin/longhorn-ui-entrypoint.sh
ENV LONGHORN_MANAGER_IP=http://localhost:9500 LONGHORN_UI_PORT=8000
USER 10001:10001
EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/longhorn-ui-entrypoint.sh"]
CMD []
