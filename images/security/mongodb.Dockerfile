FROM docker.io/library/mongo@sha256:8ef27524b4cde51b9f07bb0827a56d02c6d3b148d0b7d0ca8ff4dfd57351ff4f
# The configured MongoDB apt source stays on the compatible 7.0 series. Upgrade
# OS packages and independently versioned database tools, retaining the server.
RUN apt-mark hold mongodb-org mongodb-org-database mongodb-org-server \
        mongodb-org-mongos mongodb-org-shell mongodb-org-tools \
        mongodb-org-database-tools-extra \
    && apt-get update && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* /usr/local/bin/gosu
# Kubernetes starts mongod directly as the existing database owner. The root
# branch of docker-entrypoint.sh, which invokes gosu, is not used.
USER 999:999
