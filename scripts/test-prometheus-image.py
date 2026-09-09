#!/usr/bin/env python3
"""Check Prometheus queries, UI, reload and existing WAL data in disposable Docker volumes."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


def command(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout


def request(url, method='GET'):
    with urllib.request.urlopen(urllib.request.Request(url, method=method), timeout=10) as response:
        return response.read()


def wait_for(check, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = check()
            if value:
                return value
        except (OSError, ValueError, urllib.error.URLError):
            pass
        time.sleep(1)
    raise TimeoutError('Prometheus fixture did not reach the expected state')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image')
    parser.add_argument('--previous-image', required=True)
    parser.add_argument('--logs', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    args.logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    name = 'prometheus-security-test-' + secrets.token_hex(5)
    volume = name + '-data'
    active = False
    phase = 'previous image'
    try:
        command(['docker', 'volume', 'create', volume])
        # Ownership matches the current Kubernetes deployment. This volume is
        # newly created for the fixture and never contains production data.
        command(['docker', 'run', '--rm', '--network=none', '--read-only',
                 '--memory=64m', '--cpus=0.5', '--user=0:0', '--cap-drop=ALL',
                 '--cap-add=CHOWN', '--security-opt=no-new-privileges',
                 '-v', volume + ':/prometheus', '--entrypoint=/bin/sh',
                 args.previous_image, '-ec', 'chown 65534:65534 /prometheus'])
        with tempfile.TemporaryDirectory(prefix=name + '-') as directory:
            config_dir = Path(directory)
            config_dir.chmod(0o755)
            config = config_dir / 'prometheus.yml'

            def write_config(label):
                config.write_text('global:\n  scrape_interval: 1s\nscrape_configs:\n'
                                  '  - job_name: fixture\n    static_configs:\n'
                                  '      - targets: ["127.0.0.1:9090"]\n'
                                  f'        labels: {{fixture: "{label}"}}\n')
                config.chmod(0o644)

            def start(image):
                nonlocal active
                command(['docker', 'run', '-d', '--name', name, '--memory=512m',
                         '--cpus=1', '--pids-limit=128', '--read-only',
                         '--user=65534:65534', '--cap-drop=ALL',
                         '--security-opt=no-new-privileges', '--tmpfs=/tmp:rw,noexec,nosuid,size=32m',
                         '-p', '127.0.0.1::9090', '-v', volume + ':/prometheus',
                         '-v', str(config_dir) + ':/etc/prometheus:ro', image,
                         '--config.file=/etc/prometheus/prometheus.yml',
                         '--storage.tsdb.path=/prometheus', '--storage.tsdb.retention.time=1h',
                         '--web.enable-lifecycle'])
                active = True
                info = json.loads(command(['docker', 'inspect', name]))[0]
                port = info['NetworkSettings']['Ports']['9090/tcp'][0]['HostPort']
                url = 'http://127.0.0.1:' + port
                wait_for(lambda: request(url + '/-/ready'))
                return url

            def query(url, expression, at=None):
                params = {'query': expression}
                if at is not None:
                    params['time'] = str(at)
                result = json.loads(request(url + '/api/v1/query?' + urllib.parse.urlencode(params)))
                assert result['status'] == 'success'
                return result['data']['result']

            def stop(label):
                nonlocal active
                command(['docker', 'stop', '--time', '30', name])
                with (args.logs / (label + '.log')).open('wb') as log:
                    subprocess.run(['docker', 'logs', name], stdout=log,
                                   stderr=subprocess.STDOUT, check=True)
                command(['docker', 'rm', name])
                active = False

            write_config('before')
            url = start(args.previous_image)
            wait_for(lambda: query(url, 'prometheus_build_info{fixture="before"}'))
            saved_time = time.time()
            previous_sample = query(url, 'prometheus_build_info{fixture="before"}', saved_time)
            stop('previous')
            print('Previous image wrote queryable fixture samples', flush=True)

            phase = 'candidate'
            write_config('after')
            url = start(args.image)
            assert query(url, 'prometheus_build_info{fixture="before"}', saved_time) == previous_sample
            wait_for(lambda: query(url, 'prometheus_build_info{fixture="after"}'))
            assert query(url, 'vector(6 * 7)')[0]['value'][1] == '42'
            html = request(url + '/query').decode()
            assets = re.findall(r'(?:src|href)="([^"]+\.js)"', html)
            assert assets, 'UI does not reference a JavaScript asset'
            assert len(request(urllib.parse.urljoin(url + '/', assets[0]))) > 1000
            command(['docker', 'exec', name, '/bin/promtool', 'check', 'config',
                     '/etc/prometheus/prometheus.yml'])
            write_config('reloaded')
            request(url + '/-/reload', method='POST')
            wait_for(lambda: query(url, 'prometheus_build_info{fixture="reloaded"}'))
            stop('candidate')
            print('Candidate read previous WAL data and passed scrape, PromQL, UI and reload checks', flush=True)

            phase = 'restart'
            url = start(args.image)
            assert query(url, 'prometheus_build_info{fixture="before"}', saved_time) == previous_sample
            wait_for(lambda: query(url, 'prometheus_build_info{fixture="reloaded"}'))
            stop('restarted')
            (args.logs / 'result.json').write_text(json.dumps({'image': args.image,
                'previousImage': args.previous_image, 'status': 'passed'}, indent=2) + '\n')
            print('Restart and persisted sample readback passed', flush=True)
    except Exception as error:
        (args.logs / 'result.json').write_text(json.dumps({'image': args.image,
            'status': 'failed', 'phase': phase, 'errorType': type(error).__name__}, indent=2) + '\n')
        (args.logs / 'failure.txt').write_text(str(error) + '\n')
        if isinstance(error, subprocess.CalledProcessError):
            (args.logs / 'command-stderr.log').write_bytes(error.stderr or b'')
        raise RuntimeError(f'Prometheus test failed during {phase}; inspect {args.logs}') from None
    finally:
        if active:
            with (args.logs / 'container.log').open('wb') as log:
                subprocess.run(['docker', 'logs', name], stdout=log, stderr=subprocess.STDOUT, check=False)
            subprocess.run(['docker', 'rm', '-f', '-v', name], capture_output=True, check=False)
        subprocess.run(['docker', 'volume', 'rm', volume], capture_output=True, check=False)


if __name__ == '__main__':
    main()
