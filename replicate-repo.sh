#!/usr/bin/env bash
# Compatibility entrypoint; all onboarding behavior lives in add-repos.sh.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/add-repos.sh" "$@"
