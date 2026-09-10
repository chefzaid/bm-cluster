FROM docker.io/library/postgres@sha256:b939b3851e2cccb017dc4497af63b15e34efa57fba036548773c53b2f16a8871 AS patched
USER root
# Keep Debian/glibc, PostgreSQL and ICU unchanged: existing indexes depend on their collations.
RUN apt-get update && apt-get install -y --no-install-recommends --only-upgrade libpcre2-8-0 \
    # GnuPG is used to verify packages while building the upstream image. The
    # database, its extensions and backup tools do not use it or its SQLite
    # dependency. Remove the unused pinentry libraries and mount executable too;
    # containers receive their mounts from the runtime. Keep gpgv for apt,
    # libtinfo for PostgreSQL's tools, and do not autoremove runtime libraries.
    && apt-get purge -y dirmngr gnupg gnupg-l10n gnupg-utils gpg gpg-agent \
        gpg-wks-client gpg-wks-server gpgconf gpgsm libsqlite3-0 \
        mount pinentry-curses libncursesw6 libassuan0 libksba8 libnpth0 \
    && apt-get check \
    && rm -rf /var/lib/apt/lists/* /usr/local/bin/gosu /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem
# Copy the patched filesystem into a new image so the unused private key cannot
# be recovered from a parent layer. Preserve the pinned upstream runtime config.
FROM scratch
COPY --from=patched / /
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/lib/postgresql/18/bin" \
    LANG="en_US.utf8" PG_MAJOR="18" PG_VERSION="18.6-1.pgdg12+2" \
    PGDATA="/var/lib/postgresql/18/docker"
VOLUME /var/lib/postgresql
EXPOSE 5432
STOPSIGNAL SIGINT
# Kubernetes already starts PostgreSQL as its database owner; gosu is unused.
USER 999:999
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
