#!/usr/bin/env python3
"""Check a removal-only Argo CD image against its pinned vendor image.

Uses disposable, network-isolated Docker containers with no production mounts.
Repository manifest inputs are copied from local worktrees, never fetched using
live credentials. Reports and rendered manifests stay outside the repository.

Example (both images must already exist in the local Docker daemon):
  sudo python3 scripts/test-argocd-image.py \
    --image CANDIDATE_IMAGE --previous-image PINNED_VENDOR_IMAGE \
    --application-sources /private/application-sources.json \
    --output /private/argocd-image-test

The private application-sources JSON is a list of objects with name, namespace
and source fields. Source uses the Argo CD path and optional Helm valueFiles,
parameters and releaseName fields. For example:
  [{"name":"devapp","namespace":"apps","source":{"path":"infra/k8s"}}]
The workspace defaults to the parent of this repository; --workspace overrides
it. Supply all five deployed applications to reproduce the recorded comparison.

Checks cover image configuration, file bytes, modes, ownership and symlinks;
the unchanged Argo binary also preserves its embedded UI and resource assets.
Runtime checks exercise all Argo role help commands, local Git/LFS transfer,
GPG commit signing/verification and manifest generation at UID/GID10001 with a
read-only root. SSH key/configuration checks use the vendor account UID999.

The vendor image has no passwd entry for UID10001, so OpenSSH rejects that UID.
This removal-only candidate deliberately preserves and reports that limitation.
A separately tested private account preview fixes it, but is not part of this
Dockerfile or this parity test. The fixture uses local repositories and command
checks; rollout health, remote Git authentication and UI HTTP serving require
separate deployment validation. result.json records the scope and limitations.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess


def command(args, *, timeout=180):
    return subprocess.run(args, check=True, capture_output=True, timeout=timeout).stdout


def save(path, value):
    path.write_bytes(value if isinstance(value, bytes) else (json.dumps(value, indent=2) + '\n').encode())
    path.chmod(0o600)


class Fixture:
    def __init__(self, output):
        self.output = output
        self.prefix = 'argocd-security-test-' + secrets.token_hex(6)
        self.containers = set()
        self.sequence = 0

    def run(self, image, args, *, root=False, user='10001:10001', mount=None, timeout=180):
        self.sequence += 1
        name = f'{self.prefix}-{self.sequence}'
        self.containers.add(name)
        cmd = ['docker', 'run', '--name', name, '--network', 'none', '--read-only',
               '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
               '--memory', '1g', '--memory-swap', '1g', '--cpus', '0.5',
               '--pids-limit', '128', '--user', '0:0' if root else user,
               '--tmpfs', '/tmp:rw,exec,nosuid,nodev,size=128m,mode=1777',
               '--env', 'HOME=/tmp/home', '--env', 'XDG_CONFIG_HOME=/tmp/config',
               '--env', 'XDG_CACHE_HOME=/tmp/cache', '--env', 'GNUPGHOME=/tmp/gnupg',
               '--env', 'GOMEMLIMIT=768MiB']
        if root:
            # Read-only inventory must traverse vendor-owned mode-0700 paths.
            cmd += ['--cap-add', 'DAC_OVERRIDE']
        if mount:
            cmd += ['--mount', f'type=bind,src={mount},dst=/fixtures,readonly']
        try:
            return command(cmd + [image] + args, timeout=timeout)
        except subprocess.CalledProcessError as error:
            save(self.output / (name + '-failed.stdout'), error.stdout)
            save(self.output / (name + '-failed.stderr'), error.stderr)
            raise RuntimeError(f'Fixture command failed with exit {error.returncode}; see private {name} logs') from error
        finally:
            command(['docker', 'rm', '-f', '-v', name])
            self.containers.discard(name)

    def cleanup(self):
        for name in list(self.containers):
            command(['docker', 'rm', '-f', '-v', name])
            self.containers.discard(name)


INVENTORY = r'''
set -eu
find / -xdev \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
  -type f ! -path /etc/hosts ! -path /etc/hostname ! -path /etc/resolv.conf \
  -print0 | sort -z | xargs -0 sha256sum
'''

METADATA = r'''
set -eu
find / -xdev \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
  ! -path /etc/hosts ! -path /etc/hostname ! -path /etc/resolv.conf \
  -printf '%y %m %U:%G %p %l\n' | sort
'''

TOOLS = r'''
set -eu
test "$(id -u)" = 10001
test "$(id -g)" = 10001
mkdir -p "$HOME" "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
argocd version --client
helm version --short
kustomize version
git --version
git lfs version
gpg --version
tini --version
for tool in argocd-server argocd-repo-server argocd-cmp-server \
  argocd-application-controller argocd-dex argocd-notifications \
  argocd-applicationset-controller argocd-k8s-auth argocd-commit-server; do
  test "$(readlink -f "$(command -v "$tool")")" = /usr/local/bin/argocd
  "$tool" --help >/dev/null
done
test -s /etc/ssl/certs/ca-certificates.crt
test "$(readlink /etc/ssh/ssh_known_hosts)" = /app/config/ssh/ssh_known_hosts
test -x /usr/local/bin/gpg-wrapper.sh
test -x /usr/local/bin/git-verify-wrapper.sh
test -x /usr/bin/connect-proxy
git config --system --get filter.lfs.process
cd /tmp
git init --quiet --bare remote.git
git init --quiet -b main work
cd work
git config user.name 'Argo image fixture'
git config user.email 'fixture@example.invalid'
git lfs install --local
git lfs track '*.bin'
printf 'Argo LFS fixture payload\n' > fixture.bin
git add .gitattributes fixture.bin
git commit --quiet -m fixture
git remote add origin file:///tmp/remote.git
git push --quiet origin main
git --git-dir=/tmp/remote.git symbolic-ref HEAD refs/heads/main
git clone --quiet file:///tmp/remote.git /tmp/clone
cmp /tmp/work/fixture.bin /tmp/clone/fixture.bin
git -C /tmp/clone lfs fsck
gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-generate-key 'Argo image fixture <fixture@example.invalid>' ed25519 sign 0
git config user.signingkey fixture@example.invalid
git -c gpg.program=gpg commit --quiet --allow-empty -S -m signed-fixture
git verify-commit HEAD
printf 'local clone, LFS transfer and signed commit passed\n'
'''


SSH = r'''
set -eu
ssh -V 2>&1
ssh-keygen -q -t ed25519 -N '' -f /tmp/ssh-fixture
ssh-keygen -y -f /tmp/ssh-fixture > /tmp/ssh-public
ssh-keygen -lf /tmp/ssh-public >/dev/null
ssh -G -o UserKnownHostsFile=/app/config/ssh/ssh_known_hosts \
  -o ProxyCommand='connect-proxy -H localhost:8080 %h %p' fixture.example.invalid >/dev/null
'''


def manifests(fixture, image, applications, inputs, output):
    results = {}
    for app in applications:
        name = app['name']
        source = app['source']
        path = '/fixtures/' + name + '/' + source['path']
        if 'helm' in source:
            helm = source['helm']
            args = ['helm', 'template', helm.get('releaseName', name), path,
                    '--namespace', app['namespace'], '--include-crds']
            for value_file in helm.get('valueFiles', []):
                assert not value_file.startswith(('/', '$')), 'Only local chart values are supported'
                args += ['--values', path + '/' + value_file]
            for parameter in helm.get('parameters', []):
                args += ['--set-string' if parameter.get('forceString') else '--set',
                         parameter['name'] + '=' + parameter['value']]
            assert not any(helm.get(key) for key in ('values', 'valuesObject', 'fileParameters')), \
                'Inline Helm values need explicit fixture support'
        else:
            args = ['kustomize', 'build', path]
        data = fixture.run(image, args, mount=inputs)
        assert b'apiVersion:' in data and b'kind:' in data
        save(output / (name + '.yaml'), data)
        results[name] = {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True)
    parser.add_argument('--previous-image', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--application-sources', required=True, type=Path,
                        help='Private JSON of app name/source/namespace; no live API access is performed')
    parser.add_argument('--workspace', type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    os.umask(0o077)
    output = args.output.resolve()
    assert not output.is_relative_to(Path(__file__).resolve().parents[1]), 'Keep fixture output outside Git'
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    fixture = Fixture(output)
    inputs = output / 'inputs'
    inputs.mkdir(mode=0o755)
    inputs.chmod(0o755)
    applications = json.loads(args.application_sources.read_text())
    result = {'status': 'running', 'images': {}, 'toolChecks': {}, 'sshUID10001': {}, 'manifests': {},
              'isolation': {'network': 'none', 'memoryMiB': 1024, 'cpu': 0.5,
                            'runtimeUID': 10001, 'runtimeGID': 10001, 'readOnlyRoot': True}}
    try:
        for app in applications:
            name = app['name']
            assert name in ('bm-cluster', 'devapp', 'indezy', 'thoughty', 'website')
            assert not app.get('sources') and app.get('source')
            subdir = 'k8s' if name == 'bm-cluster' else 'infra/k8s'
            destination = inputs / name / subdir
            shutil.copytree(args.workspace / name / subdir, destination, symlinks=True)
            for path in (inputs / name, *destination.parents):
                if path == inputs:
                    break
                path.chmod(0o755)
        for label, image in [('vendor', args.previous_image), ('candidate', args.image)]:
            metadata = json.loads(command(['docker', 'image', 'inspect', image]))[0]
            result['images'][label] = {'id': metadata['Id'], 'config': metadata['Config'],
                                       'layers': metadata['RootFS']['Layers']}
            save(output / (label + '-files.sha256'), fixture.run(image, ['sh', '-ec', INVENTORY], root=True))
            save(output / (label + '-metadata.txt'), fixture.run(image, ['sh', '-ec', METADATA], root=True))
            save(output / (label + '-tools.log'), fixture.run(image, ['sh', '-ec', TOOLS], timeout=300))
            result['toolChecks'][label] = 'passed'
            # The existing cluster UID has no passwd entry in the vendor image.
            # Record its real SSH behavior instead of hiding an existing failure
            # with a fabricated passwd mount; also exercise the supported UID.
            ssh_probe = fixture.run(image, ['sh', '-c', 'ssh -V 2>&1; printf "exit=%s\\n" "$?"'])
            save(output / (label + '-ssh-uid10001.log'), ssh_probe)
            result['sshUID10001'][label] = ssh_probe.decode().replace('\r\n', '\n').strip()
            save(output / (label + '-ssh-vendor-uid.log'), fixture.run(image, ['sh', '-ec', SSH], user='999:999'))
            rendered = output / (label + '-manifests')
            rendered.mkdir()
            result['manifests'][label] = manifests(fixture, image, applications, inputs, rendered)
        old = result['images']['vendor']
        new = result['images']['candidate']
        assert old['config'] == new['config'], 'Image runtime configuration changed'
        assert new['layers'][:-1] == old['layers'], 'Candidate must add exactly one removal layer'
        for suffix in ('files.sha256', 'metadata.txt'):
            before = (output / ('vendor-' + suffix)).read_bytes().splitlines()
            after = (output / ('candidate-' + suffix)).read_bytes().splitlines()
            removed = [line for line in before if b' /usr/bin/pebble' in line]
            assert len(removed) == 1, 'Expected precisely one vendor Pebble entry'
            assert [line for line in before if line not in removed] == after, \
                'Unexpected image filesystem or metadata difference'
        assert result['manifests']['vendor'] == result['manifests']['candidate'], 'Manifest outputs changed'
        assert result['sshUID10001']['vendor'] == result['sshUID10001']['candidate'], 'SSH behavior changed'
        if 'exit=255' in result['sshUID10001']['vendor']:
            assert result['sshUID10001']['vendor'] == 'No user exists for uid 10001\nexit=255'
            result['existingLimitations'] = ['OpenSSH requires a passwd entry for UID10001; both images fail identically at the cluster UID and pass at vendor UID999.']
        else:
            assert result['sshUID10001']['vendor'].endswith('exit=0')
        result['status'] = 'passed'
        result['filesystemChange'] = 'Only /usr/bin/pebble removed; all remaining bytes, modes, ownership and symlinks match'
        result['embeddedUI'] = 'Consolidated Argo CD binary unchanged byte-for-byte, including embedded UI and resource assets'
    finally:
        fixture.cleanup()
        shutil.rmtree(inputs)
        result['containersCleaned'] = not fixture.containers
        save(output / 'result.json', result)
    print(json.dumps({'status': result['status'], 'applications': len(applications),
                      'evidence': str(output / 'result.json')}))


if __name__ == '__main__':
    main()
