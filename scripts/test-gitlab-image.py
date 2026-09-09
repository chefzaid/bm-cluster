#!/usr/bin/env python3
"""Validate an Omnibus image using disposable volumes and loopback-only ports."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


def command(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout


def free_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


def request(url, method='GET', data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=30) as response:
        return response.status, dict(response.headers), response.read()


def check_registry(url, root_url, token):
    repository = 'root/security-fixture/image'
    authorization = base64.b64encode(('root:' + token).encode()).decode()
    query = urllib.parse.urlencode({'service': 'container_registry',
                                   'scope': f'repository:{repository}:pull,push'})
    _, _, payload = request(root_url + '/jwt/auth?' + query,
                            headers={'Authorization': 'Basic ' + authorization})
    registry_token = json.loads(payload)['token']
    headers = {'Authorization': 'Bearer ' + registry_token}
    config = json.dumps({'architecture': 'amd64', 'os': 'linux',
                         'rootfs': {'type': 'layers', 'diff_ids': []},
                         'config': {}}, separators=(',', ':')).encode()
    digest = 'sha256:' + hashlib.sha256(config).hexdigest()
    status, response_headers, _ = request(url + f'/v2/{repository}/blobs/uploads/',
                                          'POST', data=b'', headers=headers)
    assert status == 202
    location = next(v for k, v in response_headers.items() if k.lower() == 'location')
    parsed = urllib.parse.urlsplit(location)
    # Container-generated locations use its internal listener; retain only the
    # path and query when accessing the fixture's loopback publication.
    upload = url + parsed.path + '?' + parsed.query
    upload += ('&' if parsed.query else '') + urllib.parse.urlencode({'digest': digest})
    status, _, _ = request(upload, 'PUT', config,
                           {**headers, 'Content-Type': 'application/octet-stream'})
    assert status == 201
    manifest = json.dumps({'schemaVersion': 2,
        'mediaType': 'application/vnd.oci.image.manifest.v1+json',
        'config': {'mediaType': 'application/vnd.oci.image.config.v1+json',
                   'digest': digest, 'size': len(config)}, 'layers': []}).encode()
    manifest_url = url + f'/v2/{repository}/manifests/check'
    status, _, _ = request(manifest_url, 'PUT', manifest,
        {**headers, 'Content-Type': 'application/vnd.oci.image.manifest.v1+json'})
    assert status == 201
    _, _, downloaded = request(manifest_url,
        headers={**headers, 'Accept': 'application/vnd.oci.image.manifest.v1+json'})
    assert json.loads(downloaded)['config']['digest'] == digest
    _, _, downloaded = request(url + f'/v2/{repository}/blobs/{digest}', headers=headers)
    assert downloaded == config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image')
    parser.add_argument('--logs', required=True, type=Path)
    parser.add_argument('--timeout', type=int, default=1200)
    args = parser.parse_args()
    os.umask(0o077)
    args.logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    name = 'gitlab-security-test-' + secrets.token_hex(5)
    ports = [free_port() for _ in range(3)]
    while len(set(ports)) != 3:
        ports = [free_port() for _ in range(3)]
    http_port, registry_port, ssh_port = ports
    root_url = f'http://127.0.0.1:{http_port}'
    registry_url = f'http://127.0.0.1:{registry_port}'
    volumes = [name + '-' + suffix for suffix in ('config', 'logs', 'data')]
    password = secrets.token_urlsafe(32)
    created = False
    phase = 'startup'
    try:
        with tempfile.TemporaryDirectory(prefix=name + '-') as directory:
            private = Path(directory)
            config = private / 'gitlab.rb'
            config.write_text(f"""external_url '{root_url}'
letsencrypt['enable'] = false
nginx['listen_port'] = 80
nginx['listen_https'] = false
gitlab_rails['initial_root_password'] = '{password}'
gitlab_rails['gitlab_shell_ssh_port'] = {ssh_port}
gitlab_rails['usage_ping_enabled'] = false
gitlab_rails['smtp_enable'] = false
puma['worker_processes'] = 0
puma['min_threads'] = 1
puma['max_threads'] = 4
sidekiq['concurrency'] = 2
postgresql['shared_buffers'] = '128MB'
prometheus_monitoring['enable'] = false
gitlab_kas['enable'] = false
registry_external_url '{registry_url}'
registry_nginx['listen_port'] = 5050
registry_nginx['listen_https'] = false
""")
            run = ['docker', 'run', '-d', '--name', name, '--memory=5g', '--cpus=2',
                   '--pids-limit=1024', '--shm-size=256m',
                   '--security-opt=no-new-privileges',
                   '-p', f'127.0.0.1:{http_port}:80',
                   '-p', f'127.0.0.1:{registry_port}:5050',
                   '-p', f'127.0.0.1:{ssh_port}:22']
            for volume, path in zip(volumes, ('/etc/gitlab', '/var/log/gitlab', '/var/opt/gitlab')):
                command(['docker', 'volume', 'create', volume])
                run += ['-v', volume + ':' + path]
            run += ['-v', str(config) + ':/etc/gitlab/gitlab.rb:ro', args.image]
            command(run)
            created = True
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                try:
                    # GitLab hides monitoring endpoints from Docker's bridge
                    # gateway. Check them inside the container, preserving its
                    # production monitoring allow-list.
                    body = command(['docker', 'exec', name, 'curl', '--fail',
                                    '--silent', '--show-error', '--max-time', '5',
                                    'http://127.0.0.1/-/readiness?all=1'])
                    if json.loads(body)['status'] == 'ok':
                        break
                except (OSError, ValueError, subprocess.CalledProcessError):
                    pass
                if command(['docker', 'inspect', '-f', '{{.State.Running}}', name]).strip() != b'true':
                    raise RuntimeError('Candidate container exited during startup')
                time.sleep(5)
            else:
                raise TimeoutError('GitLab did not become ready')
            print('GitLab reconfigure and readiness passed', flush=True)
            phase = 'authentication and API'
            ruby = """u=User.find_by_username!('root');
raise 'Root password validation failed' unless u.valid_password?(ARGV.fetch(0));
raise 'Invalid password accepted' if u.valid_password?('deliberately-wrong');
t=u.personal_access_tokens.create!(name:'disposable-image-test',
scopes:['api','read_repository','write_repository'],expires_at:1.day.from_now);
puts t.token"""
            # Pass the generated password through a private file, not argv.
            runner = private / 'authenticate.rb'
            runner.write_text('ARGV << File.read("/tmp/image-test-password").strip\n' + ruby)
            (private / 'password').write_text(password)
            command(['docker', 'cp', str(runner), name + ':/tmp/authenticate.rb'])
            command(['docker', 'cp', str(private / 'password'), name + ':/tmp/image-test-password'])
            command(['docker', 'exec', name, 'chown', 'git:git',
                     '/tmp/authenticate.rb', '/tmp/image-test-password'])
            token_output = command(['docker', 'exec', name, 'gitlab-rails', 'runner',
                                    '/tmp/authenticate.rb']).decode()
            token = token_output.strip().splitlines()[-1]
            if not token.startswith('glpat-'):
                raise RuntimeError('Fixture token was not returned')
            api_headers = {'PRIVATE-TOKEN': token, 'Content-Type': 'application/json'}
            _, _, body = request(root_url + '/api/v4/user', headers=api_headers)
            assert json.loads(body)['username'] == 'root'
            _, _, body = request(root_url + '/api/graphql', 'POST',
                json.dumps({'query': '{ currentUser { username } }'}).encode(), api_headers)
            assert json.loads(body)['data']['currentUser']['username'] == 'root'
            _, _, body = request(root_url + '/api/v4/projects', 'POST',
                json.dumps({'name': 'security-fixture', 'initialize_with_readme': True}).encode(), api_headers)
            project = json.loads(body)
            print('Password verification, REST and GraphQL passed', flush=True)
            phase = 'Git over HTTP and SSH'
            token_file = private / 'token'
            token_file.write_text(token)
            askpass = private / 'askpass'
            askpass.write_text('#!/bin/sh\ncase "$1" in *Username*) echo root;; *) cat "$FIXTURE_TOKEN_FILE";; esac\n')
            askpass.chmod(0o700)
            git_env = {**os.environ, 'GIT_ASKPASS': str(askpass),
                       'GIT_TERMINAL_PROMPT': '0', 'FIXTURE_TOKEN_FILE': str(token_file)}
            checkout = private / 'repository'
            command(['git', 'clone', root_url + '/root/security-fixture.git', str(checkout)], env=git_env)
            (checkout / 'security-test.txt').write_text('HTTP commit fixture\n')
            command(['git', 'add', '.'], cwd=checkout)
            command(['git', '-c', 'user.name=Image Test', '-c', 'user.email=test@example.invalid',
                     'commit', '-m', 'Exercise HTTP repository push'], cwd=checkout)
            command(['git', 'push', 'origin', 'HEAD'], cwd=checkout, env=git_env)
            key = private / 'id_ed25519'
            command(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)])
            request(root_url + '/api/v4/user/keys', 'POST',
                    json.dumps({'title': 'disposable-test', 'key': key.with_suffix('.pub').read_text()}).encode(), api_headers)
            host_key = command(['docker', 'exec', name, 'cat', '/etc/ssh/ssh_host_ed25519_key.pub']).decode()
            hosts = private / 'known_hosts'
            hosts.write_text(f'[127.0.0.1]:{ssh_port} ' + host_key)
            ssh = shlex.join(['ssh', '-i', str(key), '-p', str(ssh_port),
                              '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
                              '-o', 'UserKnownHostsFile=' + str(hosts)])
            ssh_url = 'git@127.0.0.1:root/security-fixture.git'
            command(['git', 'ls-remote', ssh_url], env={**git_env, 'GIT_SSH_COMMAND': ssh})
            (checkout / 'security-test.txt').write_text('SSH commit fixture\n')
            command(['git', '-c', 'user.name=Image Test', '-c', 'user.email=test@example.invalid',
                     'commit', '-am', 'Exercise SSH repository push'], cwd=checkout)
            command(['git', 'push', ssh_url, 'HEAD'], cwd=checkout,
                    env={**git_env, 'GIT_SSH_COMMAND': ssh})
            _, _, body = request(root_url + f'/api/v4/projects/{project["id"]}/repository/files/security-test.txt/raw?ref=HEAD',
                                 headers=api_headers)
            assert body == b'SSH commit fixture\n'
            print('HTTP/SSH clone, authentication, push and repository readback passed', flush=True)
            phase = 'registry'
            check_registry(registry_url, root_url, token)
            print('Authenticated OCI manifest and blob upload/download passed', flush=True)
            phase = 'restart'
            command(['docker', 'restart', '--time', '120', name])
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                try:
                    _, _, body = request(root_url + f'/api/v4/projects/{project["id"]}/repository/files/security-test.txt/raw?ref=HEAD',
                                         headers=api_headers)
                    if body == b'SSH commit fixture\n':
                        break
                except (OSError, urllib.error.URLError):
                    pass
                time.sleep(5)
            else:
                raise TimeoutError('Saved repository unavailable after restart')
            print('Restart and persisted repository readback passed', flush=True)
            (args.logs / 'result.json').write_text(json.dumps({'image': args.image, 'status': 'passed'}, indent=2) + '\n')
    except Exception as error:
        # Logs are private: vendor startup can contain generated credentials.
        (args.logs / 'failure.txt').write_text(str(error) + '\n')
        if isinstance(error, subprocess.CalledProcessError):
            (args.logs / 'command-stderr.log').write_bytes(error.stderr or b'')
            (args.logs / 'command-stdout.log').write_bytes(error.stdout or b'')
        (args.logs / 'result.json').write_text(json.dumps({'image': args.image, 'status': 'failed',
            'phase': phase, 'errorType': type(error).__name__}, indent=2) + '\n')
        raise RuntimeError(f'GitLab test failed during {phase}; inspect private logs at {args.logs}') from None
    finally:
        if created:
            with (args.logs / 'container.log').open('wb') as log:
                subprocess.run(['docker', 'logs', name], stdout=log, stderr=subprocess.STDOUT, check=False)
            with (args.logs / 'services.tar.gz').open('wb') as log, \
                    (args.logs / 'services-export.log').open('wb') as errors:
                subprocess.run(['docker', 'exec', name, 'tar', '-C', '/var/log/gitlab', '-czf', '-', '.'],
                               stdout=log, stderr=errors, check=False)
            subprocess.run(['docker', 'rm', '-f', '-v', name], check=False, capture_output=True)
        for volume in volumes:
            subprocess.run(['docker', 'volume', 'rm', volume], check=False, capture_output=True)


if __name__ == '__main__':
    main()
