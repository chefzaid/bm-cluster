#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
python3 - "$root/k8s/platform/application-observability.yaml" "$work/discovery.mjs" "$root/k8s/platform/monitoring.yaml" <<'PY'
import pathlib, subprocess, sys, tempfile, yaml
resources = list(yaml.safe_load_all(pathlib.Path(sys.argv[1]).read_text()))
config = next(resource for resource in resources if resource['kind'] == 'ConfigMap')
pathlib.Path(sys.argv[2]).write_text(config['data']['discovery.mjs'])
role = next(resource for resource in resources if resource['kind'] == 'Role')
assert role['metadata']['namespace'] == 'apps'
assert all(rule['verbs'] == ['list'] and 'secrets' not in rule['resources'] for rule in role['rules'])
monitoring = list(yaml.safe_load_all(pathlib.Path(sys.argv[3]).read_text()))
grafana = next(r for r in monitoring if r and r['kind'] == 'Deployment' and r['metadata']['name'] == 'grafana')
pod = grafana['spec']['template']['spec']
initializer = next(c for c in pod['initContainers'] if c['name'] == 'prepare-dashboard-directories')
assert initializer['command'][:2] == ['node', '-e']
mount = next(m for m in initializer['volumeMounts'] if m['name'] == 'dashboard-files')['mountPath']
grafana_container = next(c for c in pod['containers'] if c['name'] == 'grafana')
separate_mounts = {m['mountPath'] for m in grafana_container['volumeMounts'] if m['name'] != 'dashboard-files'}
provider = next(r for r in monitoring if r and r['kind'] == 'ConfigMap' and r['metadata']['name'] == 'grafana-dashboard-provider')
with tempfile.TemporaryDirectory(prefix='grafana-init-test-') as directory:
    subprocess.run(['node', '-e', initializer['command'][2].replace(mount, directory)], check=True)
    for entry in yaml.safe_load(provider['data']['dashboards.yaml'])['providers']:
        path = entry['options']['path']
        if path not in separate_mounts:
            assert (pathlib.Path(directory) / pathlib.Path(path).relative_to(mount)).is_dir(), path
PY
APPLICATION_OBSERVABILITY_MODULE="$work/discovery.mjs" node --test "$root/scripts/test-application-observability.mjs"
