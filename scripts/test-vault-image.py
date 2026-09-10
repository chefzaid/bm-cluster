#!/usr/bin/env python3
"""Test a Vault Raft upgrade, access controls and recovery using disposable Docker data.

Only newly generated fixture secrets are used. No live Vault configuration,
credentials, storage or network is accessed. Docker must already have both images.
The private output directory must be outside this repository.
"""
import argparse
import base64
import gzip
import hashlib
from html.parser import HTMLParser
import io
import json
import os
from pathlib import Path
import secrets
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


def command(args, timeout=90):
    return subprocess.run(args, check=True, capture_output=True, timeout=timeout).stdout


def wait_for(check, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError, urllib.error.URLError, subprocess.CalledProcessError):
            pass
        time.sleep(1)
    raise TimeoutError('Vault fixture did not reach the expected state')


class AssetParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.assets = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        value = attrs.get('src') if tag == 'script' else attrs.get('href') if tag == 'link' else None
        if value and urllib.parse.urlsplit(value).path.endswith(('.js', '.css')):
            self.assets.append(value)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Fixture:
    def __init__(self, args, config_dir):
        self.args = args
        self.config_dir = config_dir
        self.name = 'vault-security-test-' + secrets.token_hex(6)
        self.network = self.name + '-network'
        self.volumes = []
        self.active = False
        self.network_created = False
        self.phase = 'setup'
        self.base = None
        self.root_token = None
        # Do not inherit an HTTP proxy or follow redirects to any other service.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.results = {'image': args.image, 'previousImage': args.previous_image,
                        'checks': [], 'versions': {}, 'snapshots': {}, 'uiAssets': {}}

    def request(self, path, data=None, *, token=None, method=None, expected=(200, 204), raw=False):
        headers = {}
        if token is not None:
            headers['X-Vault-Token'] = token
        if data is not None:
            if isinstance(data, bytes):
                headers['Content-Type'] = 'application/octet-stream'
            else:
                headers['Content-Type'] = 'application/json'
                data = json.dumps(data).encode()
        request = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        try:
            response = self.opener.open(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            body = response.read(64 * 1024 * 1024 + 1)
            assert len(body) <= 64 * 1024 * 1024, 'Fixture response exceeded 64 MiB'
            assert response.status in expected, f'Unexpected HTTP {response.status} for {path}'
        return body if raw else json.loads(body) if body else None

    def api(self, path, data=None, **kwargs):
        return self.request('/v1/' + path, data, **kwargs)

    def privileged(self, path, data=None, **kwargs):
        return self.api(path, data, token=self.root_token, **kwargs)

    def setup(self):
        for label, image in [('previous', self.args.previous_image), ('candidate', self.args.image)]:
            info = json.loads(command(['docker', 'image', 'inspect', image]))[0]
            self.results[label + 'ImageId'] = info['Id']
        command(['docker', 'network', 'create', '--internal', self.network])
        self.network_created = True
        assert json.loads(command(['docker', 'network', 'inspect', self.network]))[0]['Internal']
        config = {
            'ui': True, 'disable_mlock': True,
            'api_addr': 'http://127.0.0.1:8200', 'cluster_addr': 'https://127.0.0.1:8201',
            'storage': {'raft': {'path': '/vault/data', 'node_id': 'fixture'}},
            'listener': {'tcp': {'address': '0.0.0.0:8200', 'tls_disable': True}},
        }
        file = self.config_dir / 'fixture.json'
        file.write_text(json.dumps(config))
        file.chmod(0o644)

    def create_volumes(self, suffix):
        volumes = [self.name + '-' + suffix + '-' + kind for kind in ('data', 'audit')]
        for volume in volumes:
            command(['docker', 'volume', 'create', volume])
            self.volumes.append(volume)
        # This root helper can only change ownership in the two new fixture
        # volumes. The server itself always runs with all capabilities dropped.
        command(['docker', 'run', '--rm', '--network=none', '--read-only', '--memory=64m',
                 '--cpus=0.5', '--pids-limit=32', '--user=0:0', '--cap-drop=ALL',
                 '--cap-add=CHOWN', '--security-opt=no-new-privileges',
                 '-v', volumes[0] + ':/vault/data', '-v', volumes[1] + ':/vault/audit',
                 '--entrypoint=/bin/sh', self.args.previous_image, '-ec',
                 'chown 100:1000 /vault/data /vault/audit'])
        return volumes

    def start(self, image, volumes, label):
        self.phase = label + ' startup'
        command(['docker', 'run', '-d', '--name', self.name, '--network', self.network,
                 '--memory=512m', '--memory-swap=512m', '--cpus=1', '--pids-limit=128',
                 '--read-only', '--user=100:1000', '--cap-drop=ALL',
                 '--security-opt=no-new-privileges', '--tmpfs=/tmp:rw,noexec,nosuid,size=32m,uid=100,gid=1000',
                 '-e', 'SKIP_CHOWN=true', '-e', 'SKIP_SETCAP=true',
                 '-e', 'VAULT_ADDR=http://127.0.0.1:8200', '-e', 'VAULT_DISABLE_MLOCK=true',
                 '-v', str(self.config_dir) + ':/vault/config:ro',
                 '-v', volumes[0] + ':/vault/data', '-v', volumes[1] + ':/vault/audit',
                 image, 'vault', 'server', '-config=/vault/config/fixture.json'])
        self.active = True
        info = json.loads(command(['docker', 'inspect', self.name]))[0]
        # Internal Docker networks deliberately have no external forwarding or
        # published ports. The local Linux host can reach their bridge address.
        address = info['NetworkSettings']['Networks'][self.network]['IPAddress']
        self.base = 'http://' + address + ':8200'
        def startup_status():
            state = json.loads(command(['docker', 'inspect', self.name]))[0]['State']
            if not state['Running']:
                raise RuntimeError('Vault fixture exited during startup')
            return self.api('sys/seal-status')

        wait_for(startup_status)
        self.results['versions'][label] = command(['docker', 'exec', self.name, 'vault', 'version']).decode().strip()

    def stop(self, label):
        command(['docker', 'stop', '--time', '30', self.name])
        with (self.args.logs / (label + '.log')).open('wb') as log:
            subprocess.run(['docker', 'logs', self.name], stdout=log, stderr=subprocess.STDOUT, check=True)
        info = json.loads(command(['docker', 'inspect', self.name]))[0]
        assert not info['State']['OOMKilled'], 'Fixture container was killed by its memory limit'
        assert info['State']['ExitCode'] == 0, 'Vault did not shut down cleanly'
        command(['docker', 'rm', '-v', self.name])
        self.active = False

    def initialize(self):
        result = self.api('sys/init', {'secret_shares': 1, 'secret_threshold': 1}, method='PUT')
        self.unseal(result['keys_base64'][0])
        return result

    def unseal(self, key):
        status = self.api('sys/unseal', {'key': key}, method='PUT')
        assert not status['sealed'], 'Fixture unseal failed'
        wait_for(lambda: self.api('sys/health', expected=(200, 429, 503))['sealed'] is False)
        wait_for(lambda: self.api('sys/leader')['is_self'])

    def ui(self, label):
        page = self.request('/ui/', raw=True)
        parser = AssetParser()
        parser.feed(page.decode())
        assert parser.assets, 'Vault UI did not reference JavaScript or CSS'
        assets = {}
        for asset in sorted(set(parser.assets)):
            url = urllib.parse.urljoin(self.base + '/ui/', asset)
            parsed = urllib.parse.urlsplit(url)
            assert parsed.scheme + '://' + parsed.netloc == self.base, 'UI referenced an external asset'
            path = urllib.parse.urlunsplit(('', '', parsed.path, parsed.query, ''))
            content = self.request(path, raw=True)
            assert len(content) > 100, 'Vault UI asset was empty'
            assert not content.lstrip().lower().startswith(b'<!doctype html'), 'Asset request returned the HTML fallback'
            assets[path] = {'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest()}
        assert any(path.endswith('.js') for path in assets), 'Vault UI has no JavaScript'
        self.results['uiAssets'][label] = assets

    def seed(self):
        self.phase = 'previous image fixture writes'
        self.privileged('sys/audit/file', {'type': 'file', 'options': {'file_path': '/vault/audit/vault-audit.log'}})
        self.privileged('sys/mounts/fixture', {'type': 'kv', 'options': {'version': '2'}})
        for version in (1, 2):
            self.privileged('fixture/data/allowed', {'data': {'value': 'fixture-version-' + str(version)},
                                                   'options': {'cas': version - 1}})
        self.privileged('fixture/data/forbidden', {'data': {'value': 'restricted-fixture'}})
        policy = 'path "fixture/data/allowed" { capabilities = ["read"] }'
        self.privileged('sys/policies/acl/fixture-reader', {'policy': policy})
        reader = self.privileged('auth/token/create', {
            'policies': ['fixture-reader'], 'no_default_policy': True,
            'ttl': '1h', 'explicit_max_ttl': '1h', 'renewable': False,
        })['auth']['client_token']
        self.privileged('sys/auth/userpass', {'type': 'userpass'})
        password = secrets.token_urlsafe(32)
        self.privileged('auth/userpass/users/fixture-user', {
            'password': password, 'token_policies': ['fixture-reader'],
            'token_no_default_policy': True, 'token_ttl': '1h', 'token_max_ttl': '1h',
        })
        self.privileged('sys/mounts/transit', {'type': 'transit'})
        self.privileged('transit/keys/fixture', {'type': 'aes256-gcm96'})
        plaintext = base64.b64encode(secrets.token_bytes(32)).decode()
        ciphertext = self.privileged('transit/encrypt/fixture', {'plaintext': plaintext})['data']['ciphertext']
        return {'readerToken': reader, 'password': password, 'plaintext': plaintext, 'ciphertext': ciphertext}

    def verify(self, state, label, version=2):
        self.phase = label + ' access and data verification'
        for number in (1, 2):
            data = self.privileged('fixture/data/allowed?version=' + str(number))['data']
            assert data['metadata']['version'] == number
            assert data['data'] == {'value': 'fixture-version-' + str(number)}
        policy = self.privileged('sys/policies/acl/fixture-reader')['data']['policy']
        assert 'fixture/data/allowed' in policy
        self.verify_reader(state['readerToken'], version)
        auth = self.api('auth/userpass/login/fixture-user', {'password': state['password']})['auth']
        assert auth['token_policies'] == ['fixture-reader']
        self.verify_reader(auth['client_token'], version)
        self.api('auth/userpass/login/fixture-user', {'password': secrets.token_urlsafe(32)}, expected=(400, 403))
        self.api('fixture/data/allowed', expected=(403,))
        recovered = self.privileged('transit/decrypt/fixture', {'ciphertext': state['ciphertext']})['data']['plaintext']
        assert recovered == state['plaintext'], 'Previously encrypted transit data did not decrypt'
        peers = self.privileged('sys/storage/raft/configuration')['data']['config']['servers']
        assert len(peers) == 1 and peers[0]['node_id'] == 'fixture' and peers[0]['leader']
        self.ui(label)
        self.audit_rotation(label)
        self.results['checks'].append(label + ': KV history, persisted token, policy denial, userpass, transit, Raft, UI, audit rotation')

    def verify_reader(self, token, version):
        data = self.api('fixture/data/allowed', token=token)['data']
        assert data['metadata']['version'] == version
        assert data['data'] == {'value': 'fixture-version-' + str(version)}
        self.api('fixture/data/forbidden', token=token, expected=(403,))
        self.api('fixture/data/allowed', {'data': {'value': 'must-not-write'}}, token=token, expected=(403,))
        self.api('sys/mounts', token=token, expected=(403,))

    def audit_rotation(self, label):
        self.phase = label + ' audit rotation'
        # Signal from the same unprivileged UID as the real audit sidecar. No
        # extra capability or Docker daemon signal is needed to reopen the log.
        command(['docker', 'exec', self.name, '/bin/sh', '-ec',
                 'test -s /vault/audit/vault-audit.log; '
                 'mv /vault/audit/vault-audit.log /vault/audit/vault-audit.log.rotated; '
                 'vault_pid="$(pidof vault)"; test -n "$vault_pid"; kill -HUP "$vault_pid"'])
        wait_for(lambda: command(['docker', 'exec', self.name, '/bin/sh', '-c',
                                 'test -f /vault/audit/vault-audit.log && echo reopened']).strip() == b'reopened')
        self.privileged('fixture/data/allowed')
        entries = command(['docker', 'exec', self.name, 'cat', '/vault/audit/vault-audit.log'])
        parsed = [json.loads(line) for line in entries.splitlines()]
        assert any(entry.get('type') == 'request' and entry.get('request', {}).get('path') == 'fixture/data/allowed'
                   for entry in parsed), 'Reopened audit log did not receive the fixture request'
        (self.args.logs / (label + '-audit.jsonl')).write_bytes(entries)

    def snapshot(self, label):
        self.phase = label + ' snapshot verification'
        snapshot = self.privileged('sys/storage/raft/snapshot', raw=True)
        # Parse the complete compressed archive and validate Vault's SHA256SUMS.
        # Never extract archive paths onto the host filesystem.
        with gzip.GzipFile(fileobj=io.BytesIO(snapshot)) as compressed:
            expanded = compressed.read(64 * 1024 * 1024 + 1)
            assert len(expanded) <= 64 * 1024 * 1024, 'Expanded fixture snapshot exceeded 64 MiB'
            assert compressed.read(1) == b''
        with tarfile.open(fileobj=io.BytesIO(expanded), mode='r:') as archive:
            members = archive.getmembers()
            names = [member.name for member in members]
            assert len(names) == len(set(names)), 'Snapshot contains duplicate members'
            assert all(member.isfile() and member.size <= 32 * 1024 * 1024 for member in members)
            assert {'meta.json', 'state.bin', 'SHA256SUMS', 'SHA256SUMS.sealed'} == set(names)
            content = {member.name: archive.extractfile(member).read() for member in members}
            checksums = {}
            for line in content['SHA256SUMS'].decode().splitlines():
                digest, filename = line.split(None, 1)
                filename = filename.lstrip('*')
                assert filename in content and filename not in checksums
                assert hashlib.sha256(content[filename]).hexdigest() == digest, 'Snapshot checksum mismatch'
                checksums[filename] = digest
            assert {'meta.json', 'state.bin'} <= checksums.keys(), 'Snapshot data is not checksum-covered'
            metadata = json.loads(content['meta.json'])
            assert metadata['Index'] > 0 and metadata['Size'] == len(content['state.bin'])
        (self.args.logs / (label + '.snap')).write_bytes(snapshot)
        # The real CLI additionally parses every state entry, rather than only
        # checking the archive and checksums. Its temporary file stays in tmpfs.
        inspected = subprocess.run(['docker', 'exec', '-i', self.name, '/bin/sh', '-ec',
                                    'umask 077; cat > /tmp/fixture.snap; '
                                    'vault operator raft snapshot inspect -format=json /tmp/fixture.snap; '
                                    'rm /tmp/fixture.snap'], input=snapshot,
                                   capture_output=True, check=True, timeout=90).stdout
        json.loads(inspected)
        (self.args.logs / (label + '-snapshot-inspect.json')).write_bytes(inspected)
        self.results['snapshots'][label] = {'sha256': hashlib.sha256(snapshot).hexdigest(),
                                           'bytes': len(snapshot), 'index': metadata['Index'],
                                           'verifiedMembers': sorted(checksums)}
        return snapshot

    def run(self):
        self.setup()
        original = self.create_volumes('original')
        self.start(self.args.previous_image, original, 'previous')
        init = self.initialize()
        self.root_token = init['root_token']
        state = self.seed()
        # These credentials belong only to this generated fixture. Keeping them
        # beside its private snapshots permits independent evidence review.
        (self.args.logs / 'fixture-credentials.json').write_text(json.dumps({'initialization': init, **state}) + '\n')
        self.verify(state, 'previous')
        snapshot = self.snapshot('previous')
        self.stop('previous')
        print('Previous image initialized Raft data, access controls, transit keys and a verified snapshot', flush=True)

        self.start(self.args.image, original, 'candidate')
        assert self.api('sys/seal-status')['initialized'], 'Candidate lost the existing initialized state'
        self.unseal(init['keys_base64'][0])
        self.verify(state, 'candidate')
        self.privileged('fixture/data/allowed', {'data': {'value': 'fixture-version-3'}, 'options': {'cas': 2}})
        self.verify_reader(state['readerToken'], 3)
        self.snapshot('candidate')
        self.stop('candidate')
        print('Candidate preserved old data, authentication and encryption, then wrote a new version', flush=True)

        self.start(self.args.image, original, 'restarted')
        self.unseal(init['keys_base64'][0])
        self.verify(state, 'restarted', version=3)
        self.stop('restarted')

        self.phase = 'isolated snapshot restore'
        restored = self.create_volumes('restored')
        self.start(self.args.previous_image, restored, 'restore')
        recovery_init = self.initialize()
        recovery_root = recovery_init['root_token']
        # Force is required only because this completely separate disposable
        # instance was initialized with different keys. No live data is used.
        self.api('sys/storage/raft/snapshot-force', snapshot, token=recovery_root)
        wait_for(lambda: self.api('sys/seal-status')['sealed'])
        self.unseal(init['keys_base64'][0])
        self.verify(state, 'restored')
        self.stop('restored')
        self.results['checks'].append('previous snapshot restored into separate old-image Raft/audit volumes with original keys')
        self.results['status'] = 'passed'
        print('Candidate restart and isolated previous-image snapshot recovery passed', flush=True)

    def cleanup(self):
        if self.active:
            with (self.args.logs / 'failed-container.log').open('wb') as log:
                subprocess.run(['docker', 'logs', self.name], stdout=log, stderr=subprocess.STDOUT, check=False, timeout=30)
            subprocess.run(['docker', 'rm', '-f', '-v', self.name], capture_output=True, check=False, timeout=60)
        for volume in self.volumes:
            subprocess.run(['docker', 'volume', 'rm', volume], capture_output=True, check=False, timeout=60)
        if self.network_created:
            subprocess.run(['docker', 'network', 'rm', self.network], capture_output=True, check=False, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image')
    parser.add_argument('--previous-image', required=True)
    parser.add_argument('--logs', type=Path, required=True)
    args = parser.parse_args()
    args.logs = args.logs.resolve()
    if args.logs.is_relative_to(Path(__file__).resolve().parents[1]):
        parser.error('--logs must be outside the repository because it contains fixture credentials and snapshots')
    os.umask(0o077)
    args.logs.mkdir(parents=True, mode=0o700, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='vault-security-config-') as directory:
        config_dir = Path(directory)
        config_dir.chmod(0o755)
        fixture = Fixture(args, config_dir)
        try:
            fixture.run()
        except Exception as error:
            fixture.results.update(status='failed', phase=fixture.phase, errorType=type(error).__name__)
            (args.logs / 'failure.txt').write_text(str(error) + '\n')
            if isinstance(error, subprocess.CalledProcessError):
                (args.logs / 'command-stderr.log').write_bytes(error.stderr or b'')
            raise RuntimeError(f'Vault fixture failed during {fixture.phase}; inspect {args.logs}') from None
        finally:
            (args.logs / 'result.json').write_text(json.dumps(fixture.results, indent=2) + '\n')
            fixture.cleanup()


if __name__ == '__main__':
    main()
