#!/usr/bin/env python3
"""Test an existing Keycloak database, OIDC login and a read-only candidate using Docker."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
from html.parser import HTMLParser
import http.cookiejar
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa


def command(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout


def wait_for(check, timeout=600):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError, subprocess.CalledProcessError):
            pass
        time.sleep(2)
    raise TimeoutError('Fixture did not become ready')


def request(url, data=None, *, context):
    if data is not None:
        data = urllib.parse.urlencode(data).encode()
    with urllib.request.urlopen(url, data=data, timeout=15, context=context) as response:
        return response.read()


def free_port():
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        return listener.getsockname()[1]


class LoginForm(HTMLParser):
    def __init__(self):
        super().__init__()
        self.action = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'form' and attrs.get('id') == 'kc-form-login':
            self.action = attrs['action']


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def browser_login(issuer, password, context):
    callback = 'http://127.0.0.1:9/fixture-callback'
    verifier = secrets.token_urlsafe(48)
    state = secrets.token_urlsafe(24)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    params = {'client_id': 'fixture', 'redirect_uri': callback, 'response_type': 'code',
              'scope': 'openid profile email', 'state': state,
              'code_challenge': challenge, 'code_challenge_method': 'S256'}
    cookies = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies),
                                        urllib.request.HTTPSHandler(context=context), NoRedirect())
    with opener.open(issuer + '/protocol/openid-connect/auth?' + urllib.parse.urlencode(params), timeout=15) as response:
        form = LoginForm()
        form.feed(response.read().decode())
    assert form.action, 'Login form not returned'
    try:
        opener.open(form.action, data=urllib.parse.urlencode({
            'username': 'fixture-user', 'password': password, 'credentialId': ''}).encode(), timeout=15)
    except urllib.error.HTTPError as response:
        if response.code != 302:
            raise
        redirect = urllib.parse.urlsplit(response.headers['Location'])
        assert redirect.scheme + '://' + redirect.netloc + redirect.path == callback
        returned = urllib.parse.parse_qs(redirect.query)
        assert returned['state'] == [state]
        code = returned['code'][0]
    else:
        raise AssertionError('Login did not return an authorization code')
    return json.loads(request(issuer + '/protocol/openid-connect/token', {
        'grant_type': 'authorization_code', 'client_id': 'fixture', 'code': code,
        'redirect_uri': callback, 'code_verifier': verifier}, context=context))


def verify_id_token(issuer, token, context):
    def decode(value):
        return base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
    header, payload, signature = token.split('.')
    metadata, claims = json.loads(decode(header)), json.loads(decode(payload))
    assert metadata['alg'] == 'RS256'
    keys = json.loads(request(issuer + '/protocol/openid-connect/certs', context=context))['keys']
    key = next(key for key in keys if key['kid'] == metadata['kid'])
    public = rsa.RSAPublicNumbers(int.from_bytes(decode(key['e'])), int.from_bytes(decode(key['n']))).public_key()
    public.verify(decode(signature), (header + '.' + payload).encode(), padding.PKCS1v15(), hashes.SHA256())
    assert claims['iss'] == issuer and claims['aud'] == 'fixture' and claims['exp'] > time.time()
    assert claims['preferred_username'] == 'fixture-user'
    return claims['sub']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image')
    parser.add_argument('--previous-image', required=True)
    parser.add_argument('--postgres-image', required=True)
    parser.add_argument('--logs', required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    args.logs.mkdir(parents=True, exist_ok=True)
    name = 'keycloak-security-test-' + secrets.token_hex(5)
    database, volume, network = name + '-postgres', name + '-data', name + '-network'
    active = []
    phase = 'database startup'
    try:
        with tempfile.TemporaryDirectory(prefix=name + '-') as directory:
            private = Path(directory)
            tls_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            subject = x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, 'Disposable Keycloak Test')])
            now = datetime.now(timezone.utc)
            certificate = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                .public_key(tls_key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(days=1))
                .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
                .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                    key_encipherment=True, data_encipherment=False, key_agreement=False,
                    key_cert_sign=True, crl_sign=True, encipher_only=None, decipher_only=None), critical=True)
                .sign(tls_key, hashes.SHA256()))
            cert_file, key_file = private / 'tls.crt', private / 'tls.key'
            cert_file.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
            key_file.write_bytes(tls_key.private_bytes(serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            # The parent directory is private; only fixture containers mount these files.
            cert_file.chmod(0o644)
            key_file.chmod(0o644)
            context = ssl.create_default_context(cafile=str(cert_file))
            db_password, user_password = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
            pg_env = private / 'postgres.env'
            pg_env.write_text(f'POSTGRES_USER=fixture\nPOSTGRES_DB=keycloak\nPOSTGRES_PASSWORD={db_password}\nPGDATA=/var/lib/postgresql/data\n')
            command(['docker', 'network', 'create', network])
            command(['docker', 'volume', 'create', volume])
            command(['docker', 'run', '-d', '--name', database, '--network', network,
                     '--network-alias', 'database', '--memory=384m', '--cpus=0.5',
                     '--security-opt=no-new-privileges', '--env-file', str(pg_env),
                     '-v', volume + ':/var/lib/postgresql/data', args.postgres_image])
            active.append(database)
            wait_for(lambda: command(['docker', 'exec', database, 'psql', '-U', 'fixture',
                                      '-d', 'keycloak', '-Atc', 'SELECT 1']).strip() == b'1')
            ports = [free_port(), free_port()]
            while len(set(ports)) != 2:
                ports = [free_port(), free_port()]
            root_url = f'https://127.0.0.1:{ports[0]}/auth'
            management = f'https://127.0.0.1:{ports[1]}/auth'
            issuer = root_url + '/realms/security-fixture'
            env = private / 'keycloak.env'
            env.write_text(f'KC_DB=postgres\nKC_DB_URL=jdbc:postgresql://database:5432/keycloak\n'
                           f'KC_DB_USERNAME=fixture\nKC_DB_PASSWORD={db_password}\n'
                           f'KC_HOSTNAME={root_url}\nKC_HTTP_RELATIVE_PATH=/auth\n'
                           'KC_HTTP_ENABLED=false\nKC_HEALTH_ENABLED=true\nKC_METRICS_ENABLED=true\n'
                           'KC_HTTPS_CERTIFICATE_FILE=/fixture/tls.crt\nKC_HTTPS_CERTIFICATE_KEY_FILE=/fixture/tls.key\n')
            realm = private / 'realm.json'
            realm.write_text(json.dumps({'realm': 'security-fixture', 'enabled': True,
                'sslRequired': 'none', 'clients': [{'clientId': 'fixture', 'publicClient': True,
                    'standardFlowEnabled': True, 'directAccessGrantsEnabled': True,
                    'redirectUris': ['http://127.0.0.1:9/fixture-callback']}],
                'users': [{'username': 'fixture-user', 'enabled': True, 'emailVerified': True,
                    'email': 'fixture@example.invalid', 'firstName': 'Image', 'lastName': 'Test',
                    'credentials': [{'type': 'password', 'value': user_password, 'temporary': False}]}]}))
            realm.chmod(0o644)

            def start(image, patched):
                run = ['docker', 'run', '-d', '--name', name, '--network', network,
                       '--memory=1g', '--cpus=1', '--pids-limit=256', '--cap-drop=ALL',
                       '--security-opt=no-new-privileges', '--env-file', str(env),
                       '-p', f'127.0.0.1:{ports[0]}:8443', '-p', f'127.0.0.1:{ports[1]}:9000',
                       '-v', str(cert_file) + ':/fixture/tls.crt:ro',
                       '-v', str(key_file) + ':/fixture/tls.key:ro',
                       '-v', str(realm) + ':/opt/keycloak/data/import/realm.json:ro']
                if patched:
                    run += ['--user=10001:10001', '--read-only',
                            '--tmpfs=/tmp:rw,nosuid,size=64m,uid=10001,gid=10001',
                            '--tmpfs=/opt/keycloak/data:rw,nosuid,size=128m,uid=10001,gid=10001']
                run += [image, 'start', *(['--optimized'] if patched else []), '--import-realm']
                command(run)
                active.append(name)
                def ready():
                    state = json.loads(command(['docker', 'inspect', name]))[0]
                    if not state['State']['Running']:
                        raise RuntimeError('Keycloak fixture exited during startup')
                    if not state['NetworkSettings']['Ports'].get('9000/tcp'):
                        raise RuntimeError('Docker did not publish the fixture ports')
                    return json.loads(request(management + '/health/ready', context=context))['status'] == 'UP'
                wait_for(ready)
                discovery = json.loads(request(issuer + '/.well-known/openid-configuration', context=context))
                assert discovery['issuer'] == issuer
                assert b'jvm_' in request(management + '/metrics', context=context)

            def stop(label):
                command(['docker', 'stop', '--time', '45', name])
                with (args.logs / (label + '.log')).open('wb') as log:
                    subprocess.run(['docker', 'logs', name], stdout=log, stderr=subprocess.STDOUT, check=True)
                command(['docker', 'rm', name])
                active.remove(name)

            phase = 'previous image and browser login'
            start(args.previous_image, False)
            old_tokens = browser_login(issuer, user_password, context)
            subject = verify_id_token(issuer, old_tokens['id_token'], context)
            stop('previous')
            print('Vendor image created persistent user and a signed OIDC session', flush=True)
            phase = 'candidate and preserved sessions'
            start(args.image, True)
            refreshed = json.loads(request(issuer + '/protocol/openid-connect/token', {
                'grant_type': 'refresh_token', 'client_id': 'fixture', 'refresh_token': old_tokens['refresh_token']}, context=context))
            assert verify_id_token(issuer, refreshed['id_token'], context) == subject
            try:
                request(issuer + '/protocol/openid-connect/token', {'grant_type': 'password',
                    'client_id': 'fixture', 'username': 'fixture-user', 'password': 'deliberately-wrong'}, context=context)
            except urllib.error.HTTPError as error:
                assert error.code in (400, 401)
                assert json.loads(error.read())['error'] == 'invalid_grant'
            else:
                raise AssertionError('Invalid password accepted')
            tokens = browser_login(issuer, user_password, context)
            assert verify_id_token(issuer, tokens['id_token'], context) == subject
            stop('candidate')
            print('Read-only candidate preserved the user, signing keys and session; login and rejection checks passed', flush=True)
            phase = 'restart'
            start(args.image, True)
            tokens = browser_login(issuer, user_password, context)
            assert verify_id_token(issuer, tokens['id_token'], context) == subject
            stop('restarted')
            (args.logs / 'result.json').write_text(json.dumps({'image': args.image,
                'previousImage': args.previous_image, 'status': 'passed'}, indent=2) + '\n')
            print('Restart, persisted identity, OIDC discovery, health and metrics passed', flush=True)
    except Exception as error:
        (args.logs / 'failure.txt').write_text(str(error) + '\n')
        if isinstance(error, urllib.error.HTTPError):
            (args.logs / 'http-error-body').write_bytes(error.read())
        if isinstance(error, subprocess.CalledProcessError):
            (args.logs / 'command-stderr.log').write_bytes(error.stderr or b'')
        (args.logs / 'result.json').write_text(json.dumps({'image': args.image, 'status': 'failed',
            'phase': phase, 'errorType': type(error).__name__}, indent=2) + '\n')
        raise RuntimeError(f'Keycloak test failed during {phase}; inspect private logs at {args.logs}') from None
    finally:
        for container in reversed(active):
            with (args.logs / (container + '.log')).open('wb') as log:
                subprocess.run(['docker', 'logs', container], stdout=log, stderr=subprocess.STDOUT, check=False)
            subprocess.run(['docker', 'rm', '-f', '-v', container], capture_output=True, check=False)
        subprocess.run(['docker', 'volume', 'rm', volume], capture_output=True, check=False)
        subprocess.run(['docker', 'network', 'rm', network], capture_output=True, check=False)


if __name__ == '__main__':
    main()
