#!/usr/bin/env python3
"""Exercise a Homepage image with disposable configuration and loopback ports."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid


def command(args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image')
    parser.add_argument('--logs', required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    args.logs.mkdir(parents=True, exist_ok=False)
    name = 'homepage-security-' + uuid.uuid4().hex[:12]
    created = False
    try:
        with tempfile.TemporaryDirectory(prefix='homepage-security-') as directory:
            config = Path(directory) / 'config'
            config.mkdir(mode=0o755)
            config.chmod(0o755)
            (config / 'logs').mkdir()
            fixtures = {
                'settings.yaml': 'title: Security fixture\n',
                'services.yaml': '- Applications:\n    - Fixture service:\n        href: https://example.invalid/fixture\n',
                'bookmarks.yaml': '[]\n', 'widgets.yaml': '[]\n',
                'kubernetes.yaml': '{}\n', 'docker.yaml': '{}\n',
                'proxmox.yaml': '{}\n', 'custom.css': '', 'custom.js': '',
            }
            for filename, contents in fixtures.items():
                file = config / filename
                file.write_text(contents)
                file.chmod(0o644)
            run = ['docker', 'run', '-d', '--name', name, '--memory=512m', '--cpus=1',
                   '--read-only', '--user=10001:10001', '--cap-drop=ALL',
                   '--security-opt=no-new-privileges', '-p', '127.0.0.1::3000',
                   '-e', 'HOSTNAME=0.0.0.0', '-e', 'HOMEPAGE_ALLOWED_HOSTS=fixture.invalid',
                   '-v', str(config) + ':/app/config:ro']
            for path in ('/tmp', '/app/config/logs', '/app/.next/cache'):
                run += ['--tmpfs', path + ':uid=10001,gid=10001,size=64m']
            command(run + [args.image])
            created = True
            def address():
                ports = json.loads(command(['docker', 'inspect', '--format',
                                           '{{json .NetworkSettings.Ports}}', name]))
                return 'http://127.0.0.1:' + ports['3000/tcp'][0]['HostPort']

            base = address()

            def get(path, host='fixture.invalid'):
                req = urllib.request.Request(base + path, headers={'Host': host})
                with urllib.request.urlopen(req, timeout=10) as response:
                    return response.read()

            def ready():
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    try:
                        if get('/api/healthcheck') == b'up':
                            return
                    except (OSError, urllib.error.URLError):
                        pass
                    time.sleep(2)
                raise TimeoutError('Homepage did not become ready')

            ready()
            # Homepage prerenders the image's example settings at build time.
            # Its browser refreshes the page through this endpoint on startup.
            assert json.loads(get('/api/revalidate')) == {'revalidated': True}
            page = get('/')
            (args.logs / 'page.html').write_bytes(page)
            assert b'Security fixture' in page
            services = json.loads(get('/api/services'))
            assert any(service.get('href') == 'https://example.invalid/fixture'
                       for group in services for service in group.get('services', []))
            assert json.loads(get('/api/bookmarks')) == []
            try:
                get('/api/services', host='untrusted.invalid')
            except urllib.error.HTTPError as error:
                assert error.code == 400
            else:
                raise AssertionError('An unapproved Host header was accepted')
            # Resolve Sharp as Next.js does, including pnpm's nested layout.
            # The standalone image may omit it when all images are unoptimized.
            native = command(['docker', 'exec', name, 'node', '-e', r'''
const assert = require('node:assert/strict');
const {createRequire} = require('node:module');
const nextRequire = createRequire(require.resolve('next/package.json'));
let sharpPath;
try { sharpPath = nextRequire.resolve('sharp'); }
catch (error) {
  if (error.code !== 'MODULE_NOT_FOUND') throw error;
  console.log('Sharp omitted by standalone tracing'); process.exit(0);
}
const sharp = nextRequire(sharpPath);
(async () => {
  const input = {create: {width: 8, height: 8, channels: 4, background: '#4477aa'}};
  for (const format of ['png', 'webp', 'avif']) {
    const bytes = await sharp(input).toFormat(format).toBuffer();
    const metadata = await sharp(bytes).metadata();
    assert.equal(metadata.width, 8); assert.equal(metadata.height, 8);
  }
  assert.equal(sharp.versions.sharp, '0.35.4');
  console.log('Sharp native PNG, WebP and AVIF round trips passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
'''])
            command(['docker', 'restart', '--time', '20', name])
            # Docker can allocate a new ephemeral host port after a restart.
            base = address()
            ready()
            assert json.loads(get('/api/services')) == services
            assert json.loads(get('/api/revalidate')) == {'revalidated': True}
            assert b'Security fixture' in get('/')
            (args.logs / 'result.json').write_text(json.dumps({
                'image': args.image, 'status': 'passed', 'nativeImageCheck': native.strip(),
                'checks': ['health', 'rendered page', 'configured services', 'bookmarks',
                           'Host header rejection', 'read-only UID 10001', 'restart'],
            }, indent=2) + '\n')
            print('Homepage runtime, configuration, host validation and restart checks passed')
    finally:
        if created:
            with (args.logs / 'container.log').open('w') as log:
                subprocess.run(['docker', 'logs', name], stdout=log, stderr=log, check=False)
            subprocess.run(['docker', 'rm', '-f', name], check=True, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    main()
