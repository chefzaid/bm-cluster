#!/bin/sh
set -eu
mkdir -p /var/config/nginx
export IPV6_LISTEN=""
if ip -6 addr show scope global | grep -q inet6; then
    IPV6_LISTEN="listen [::]:${LONGHORN_UI_PORT};"
fi
envsubst '${LONGHORN_MANAGER_IP},${LONGHORN_UI_PORT},${IPV6_LISTEN}' \
    < /etc/nginx/nginx.conf.template > /var/config/nginx/nginx.conf
exec nginx -c /var/config/nginx/nginx.conf -g 'daemon off;'
