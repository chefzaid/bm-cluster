FROM docker.io/gitlab/gitlab-ce@sha256:f7e453ff51d1910235365085fe836e4589716d26b44d99a8aa3e2c41377f034f AS patched
# Keep Omnibus and its database/application migration version unchanged.
RUN apt-mark hold gitlab-ce \
    && apt-get update && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
# /assets/init-container generates per-installation keys under the persistent
# /etc/gitlab volume and links them into /etc/ssh. Image-baked keys are unused.
FROM scratch
COPY --from=patched / /
ENV PATH="/opt/gitlab/embedded/bin:/opt/gitlab/bin:/assets:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    LANG="C.UTF-8" EDITOR="/bin/vi" GITLAB_ALLOW_SHA1_RSA="false" TERM="xterm"
VOLUME ["/etc/gitlab", "/var/log/gitlab", "/var/opt/gitlab"]
EXPOSE 22 80 443
HEALTHCHECK --interval=60s --timeout=30s --retries=5 CMD /opt/gitlab/bin/gitlab-healthcheck --fail --max-time 10
CMD ["/assets/init-container"]
