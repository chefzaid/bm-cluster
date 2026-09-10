# Keep the deployed Argo CD release, its embedded UI and every repository tool.
FROM quay.io/argoproj/argocd:v3.5.2@sha256:e2aadfae709d904e87f46ba4aa49601d827b3022db22cd4d03aae816a2e7097b

# Ubuntu inherits this optional service manager. Argo CD starts with tini and
# does not use Pebble; its pinned source references it only in a historical scan.
# Verify the audited binary before removing it. Retain the package database and
# all Git, Git LFS, Helm, Kustomize, GPG, SSH and Argo CD files unchanged.
USER root
RUN test -f /usr/bin/pebble \
    && ! dpkg-query -S /usr/bin/pebble >/dev/null 2>&1 \
    && echo 'c8e0e71b4eee9d2521f142c259902ac39381eef2093a9664bef689d6b2d4d8da  /usr/bin/pebble' | sha256sum --check --status \
    && rm /usr/bin/pebble

# Preserve the vendor default; the shared Helm values set runtime UID/GID 10001.
# The upstream image lacks a passwd entry for 10001, which prevents SSH client
# use at that UID. This removal-only image retains that existing limitation;
# scripts/test-argocd-image.py records it alongside the verified file parity.
USER 999
