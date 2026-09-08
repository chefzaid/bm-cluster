FROM ghcr.io/kiwigrid/k8s-sidecar:2.11.2@sha256:2912be006f62f9ea080194cf6d3afcd90daead8d101d0ba686a137a849f6a4f6
USER root
# This runtime only watches Kubernetes resources and writes dashboard files.
# Remove package installers and their vulnerable bundled libraries, including
# Python's bootstrap wheel, from both Python environments.
RUN apk upgrade --no-cache \
    && /app/.venv/bin/python -m pip uninstall --yes pip setuptools \
    && /usr/local/bin/python -m pip uninstall --yes pip setuptools \
    && rm -rf /usr/local/lib/python*/ensurepip /root/.cache
USER 10001:10001
