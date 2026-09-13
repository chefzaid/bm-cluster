#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
python3 - "$root/k8s/platform/application-observability.yaml" "$work/discovery.mjs" <<'PY'
import pathlib, sys, yaml
resources = list(yaml.safe_load_all(pathlib.Path(sys.argv[1]).read_text()))
config = next(resource for resource in resources if resource['kind'] == 'ConfigMap')
pathlib.Path(sys.argv[2]).write_text(config['data']['discovery.mjs'])
role = next(resource for resource in resources if resource['kind'] == 'Role')
assert role['metadata']['namespace'] == 'apps'
assert all(rule['verbs'] == ['list'] and 'secrets' not in rule['resources'] for rule in role['rules'])
PY
APPLICATION_OBSERVABILITY_MODULE="$work/discovery.mjs" node --test "$root/scripts/test-application-observability.mjs"
