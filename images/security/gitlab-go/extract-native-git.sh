#!/bin/sh
set -eu
mkdir -p /tmp/gitaly-security-storage /vendor-git
cat > /tmp/gitaly-security.toml <<'EOF'
bin_dir = "/opt/gitlab/embedded/bin"
socket_path = "/tmp/gitaly-security.sock"
[[storage]]
name = "default"
path = "/tmp/gitaly-security-storage"
EOF
/opt/gitlab/embedded/bin/gitaly git -c /tmp/gitaly-security.toml -- \
  -c 'alias.copy-security-git=!cp "$(dirname "$GIT_EXEC_PATH")"/gitaly-git-* /vendor-git/' \
  copy-security-git
test "$(find /vendor-git -maxdepth 1 -type f | wc -l)" -eq 9
rm -rf /tmp/gitaly-security-storage /tmp/gitaly-security.toml
