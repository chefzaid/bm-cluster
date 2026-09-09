FROM docker.io/gitlab/gitlab-ce@sha256:f7e453ff51d1910235365085fe836e4589716d26b44d99a8aa3e2c41377f034f AS vendor
FROM vendor AS native-git
COPY gitlab-go/extract-native-git.sh /tmp/extract-native-git.sh
RUN sh /tmp/extract-native-git.sh

FROM docker.io/library/golang:1.26.7-bookworm@sha256:e8c859f5632dcfde7b32d2012b4351728f6437930887c2f6a91ea242459e5514 AS gitlab-go-build
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 libkrb5-dev libsystemd-dev pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 1001 builder && useradd -m -u 1001 -g 1001 builder \
    && mkdir /build && chown builder:builder /build
COPY --from=native-git --chown=1001:1001 /vendor-git /vendor-git
COPY gitlab-go /security/gitlab-go
ENV CGO_ENABLED=1 GOMAXPROCS=2 GOMEMLIMIT=1400MiB GOTOOLCHAIN=local GOWORK=off
USER builder
RUN python3 /security/gitlab-go/build.py

FROM vendor AS gitlab-ruby-build
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential patch libjemalloc-dev rustc \
    && rm -rf /var/lib/apt/lists/*
COPY gitlab-ruby /tmp/security-ruby
# Compile extensions against the existing Ruby ABI. The verified source archive
# supplies build headers; the vendor interpreter and libruby stay in place.
RUN curl --fail --silent --show-error --location \
      https://cache.ruby-lang.org/pub/ruby/3.3/ruby-3.3.12.tar.gz \
      --output /tmp/ruby-3.3.12.tar.gz \
    && ruby /tmp/security-ruby/restore-headers.rb /tmp/ruby-3.3.12.tar.gz \
    && rm /tmp/ruby-3.3.12.tar.gz \
    && curl --fail --silent --show-error --location \
      https://rubygems.org/downloads/resolv-0.3.1.gem \
      --output /tmp/security-ruby/resolv-0.3.1.gem \
    && curl --fail --silent --show-error --location \
      https://rubygems.org/downloads/resolv-0.3.2.gem \
      --output /tmp/security-ruby/resolv-0.3.2.gem
WORKDIR /opt/gitlab/embedded/service/gitlab-rails
RUN cp Gemfile.lock /tmp/rails-original.lock \
    && patch -p1 --fuzz=0 < /tmp/security-ruby/rails.patch \
    && patch -p1 --fuzz=0 < /tmp/security-ruby/application.patch \
    && ruby /tmp/security-ruby/verify-lockfile.rb /tmp/rails-original.lock Gemfile.lock \
    && bundle install --jobs=1 && bundle check
WORKDIR /opt/gitlab/embedded/service/omnibus-gitlab
RUN cp Gemfile.lock /tmp/omnibus-original.lock \
    && patch -p1 --fuzz=0 < /tmp/security-ruby/omnibus.patch \
    && ruby /tmp/security-ruby/verify-lockfile.rb /tmp/omnibus-original.lock Gemfile.lock \
    && bundle install --jobs=1 && bundle check
RUN ruby /tmp/security-ruby/update-default-resolv.rb \
    && ruby /tmp/security-ruby/prune-superseded.rb \
    && bundle check \
    && cd /opt/gitlab/embedded/service/gitlab-rails && bundle check \
    && bundle exec ruby /tmp/security-ruby/test-poller.rb \
    && bundle exec ruby /tmp/security-ruby/test-libraries.rb \
    && rm -rf /opt/gitlab/embedded/lib/ruby/gems/3.3.0/cache

FROM vendor AS patched
# COPY merges directories, so remove the original gem tree first. Otherwise
# superseded implementations would survive next to the replacement versions.
RUN rm -rf /opt/gitlab/embedded/lib/ruby /opt/gitlab/embedded/bin
COPY --from=gitlab-ruby-build /opt/gitlab/embedded/lib/ruby /opt/gitlab/embedded/lib/ruby
COPY --from=gitlab-ruby-build /opt/gitlab/embedded/bin /opt/gitlab/embedded/bin
COPY --from=gitlab-ruby-build /opt/gitlab/embedded/service/gitlab-rails/Gemfile* /opt/gitlab/embedded/service/gitlab-rails/
COPY --from=gitlab-ruby-build /opt/gitlab/embedded/service/gitlab-rails/lib/gitlab/patch/sidekiq_cron_poller.rb /opt/gitlab/embedded/service/gitlab-rails/lib/gitlab/patch/sidekiq_cron_poller.rb
COPY --from=gitlab-ruby-build /opt/gitlab/embedded/service/omnibus-gitlab/Gemfile* /opt/gitlab/embedded/service/omnibus-gitlab/
COPY --from=gitlab-go-build /build/runtime/ /
COPY gitlab-go/update-manifest.rb /tmp/update-manifest.rb
# Keep Omnibus and its database/application migration version unchanged.
RUN /opt/gitlab/embedded/bin/ruby /tmp/update-manifest.rb && rm /tmp/update-manifest.rb \
    && apt-mark hold gitlab-ce \
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
