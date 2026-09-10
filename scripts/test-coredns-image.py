#!/usr/bin/env python3
"""Compare CoreDNS plugins and exercise DNS in an isolated, restricted container."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import tempfile
import time
import urllib.request


def command(args, timeout=90):
    return subprocess.run(args, capture_output=True, text=True, check=True, timeout=timeout).stdout


def read_exact(stream, length):
    data = b''
    while len(data) < length:
        part = stream.recv(length - len(data))
        if not part:
            raise ValueError('Truncated DNS TCP response')
        data += part
    return data


def skip_name(data, offset):
    for _ in range(128):
        length = data[offset]
        offset += 1
        if length == 0:
            return offset
        if length & 0xc0 == 0xc0:
            assert offset < len(data)
            return offset + 1
        assert length <= 63 and offset + length <= len(data)
        offset += length
    raise ValueError('Invalid DNS name')


def query(host, port, name, kind=1, tcp=False):
    identifier = secrets.randbelow(65536)
    encoded = b''.join(bytes([len(part)]) + part.encode('ascii') for part in name.rstrip('.').split('.')) + b'\0'
    packet = struct.pack('!HHHHHH', identifier, 0x0100, 1, 0, 0, 0) + encoded + struct.pack('!HH', kind, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as stream:
        stream.settimeout(3)
        stream.connect((host, port))
        if tcp:
            stream.sendall(struct.pack('!H', len(packet)) + packet)
            data = read_exact(stream, struct.unpack('!H', read_exact(stream, 2))[0])
        else:
            stream.send(packet)
            data = stream.recv(65535)
    actual_id, flags, questions, answers, _, _ = struct.unpack('!HHHHHH', data[:12])
    assert actual_id == identifier and flags & 0x8000 and not flags & 0x0200
    assert questions == 1
    offset = skip_name(data, 12) + 4
    found = []
    for _ in range(answers):
        offset = skip_name(data, offset)
        answer_kind, answer_class, _, length = struct.unpack('!HHIH', data[offset:offset + 10])
        offset += 10
        payload = data[offset:offset + length]
        assert len(payload) == length and answer_class == 1
        if answer_kind in (1, 28):
            found.append(str(ipaddress.ip_address(payload)))
        elif answer_kind == 33:
            found.append({'priority': struct.unpack('!H', payload[:2])[0],
                          'weight': struct.unpack('!H', payload[2:4])[0],
                          'port': struct.unpack('!H', payload[4:6])[0]})
        offset += length
    return flags & 15, found


def wait(check, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            value = check()
            if value:
                return value
        except (OSError, ValueError, AssertionError):
            pass
        time.sleep(1)
    raise TimeoutError('CoreDNS fixture did not reach the expected state')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image')
    parser.add_argument('--previous-image', required=True)
    parser.add_argument('--logs', required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    args.logs.mkdir(mode=0o700, parents=True, exist_ok=False)
    result = {'image': args.image, 'previousImage': args.previous_image, 'checks': []}
    name = 'coredns-security-' + secrets.token_hex(5)
    network_created = container_created = False
    temporary = tempfile.TemporaryDirectory(prefix='coredns-security-')
    root = Path(temporary.name)
    root.chmod(0o755)

    def zone(address, serial):
        text = f'''$ORIGIN fixture.test.
$TTL 1
@ IN SOA ns.fixture.test. hostmaster.fixture.test. ({serial} 60 60 3600 1)
@ IN NS ns.fixture.test.
ns IN A 192.0.2.2
api IN A {address}
api IN AAAA 2001:db8::7
_https._tcp.api IN SRV 10 5 443 api.fixture.test.
'''
        path = root / 'zone.next'
        path.write_text(text)
        path.chmod(0o644)
        path.replace(root / 'zone')

    try:
        for label, image in [('previous', args.previous_image), ('candidate', args.image)]:
            info = json.loads(command(['docker', 'image', 'inspect', image]))[0]
            assert not info['Config'].get('Volumes'), 'Unexpected anonymous image volumes'
            result[label + 'ImageId'] = info['Id']
            output = command(['docker', 'run', '--rm', '--network=none', '--read-only',
                              '--user=65534:65534', '--cap-drop=ALL', '--cap-add=NET_BIND_SERVICE',
                              '--security-opt=no-new-privileges',
                              '--memory=128m', '--memory-swap=128m', '--cpus=0.5', '--pids-limit=64',
                              '--entrypoint=/coredns', image, '-plugins'])
            (args.logs / (label + '-plugins.txt')).write_text(output)
            if label == 'previous':
                previous_plugins = output
            else:
                assert output == previous_plugins, 'Compiled plugin inventory changed'
        result['checks'].append('all compiled plugins match the previous image')
        (root / 'Corefile').write_text('''.:1053 {
    errors
    health :8080
    ready :8181
    file /config/zone fixture.test {
        reload 2s
    }
}
''')
        (root / 'Corefile').chmod(0o644)
        zone('192.0.2.7', 1)
        command(['docker', 'network', 'create', '--internal', name])
        network_created = True
        command(['docker', 'create', '--name', name, '--network', name, '--read-only',
                 '--user=65534:65534', '--cap-drop=ALL', '--cap-add=NET_BIND_SERVICE',
                 '--security-opt=no-new-privileges',
                 '--memory=256m', '--memory-swap=256m', '--cpus=0.5', '--pids-limit=128',
                 '-v', str(root) + ':/config:ro', '--entrypoint=/coredns', args.image,
                 '-conf', '/config/Corefile'])
        container_created = True
        command(['docker', 'start', name])
        info = json.loads(command(['docker', 'inspect', name]))[0]
        assert info['HostConfig']['ReadonlyRootfs'] and info['Config']['User'] == '65534:65534'
        assert info['HostConfig']['CapDrop'] == ['ALL'] and not info['HostConfig']['PortBindings']
        assert {cap.removeprefix('CAP_') for cap in info['HostConfig']['CapAdd']} == {'NET_BIND_SERVICE'}
        assert json.loads(command(['docker', 'network', 'inspect', name]))[0]['Internal']
        host = info['NetworkSettings']['Networks'][name]['IPAddress']
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def healthy():
            for port, path in [(8080, '/health'), (8181, '/ready')]:
                with opener.open(f'http://{host}:{port}{path}', timeout=3) as response:
                    assert response.status == 200
            return True

        wait(healthy)
        for tcp in (False, True):
            assert query(host, 1053, 'api.fixture.test', tcp=tcp) == (0, ['192.0.2.7'])
            assert query(host, 1053, 'api.fixture.test', 28, tcp) == (0, ['2001:db8::7'])
            assert query(host, 1053, '_https._tcp.api.fixture.test', 33, tcp) == (0, [{'priority': 10, 'weight': 5, 'port': 443}])
            assert query(host, 1053, 'absent.fixture.test', tcp=tcp)[0] == 3
        result['checks'].append('UDP and TCP A, AAAA, SRV and NXDOMAIN replies; health and readiness')
        zone('192.0.2.8', 2)
        wait(lambda: query(host, 1053, 'api.fixture.test') == (0, ['192.0.2.8']))
        result['checks'].append('zone reload publishes changed data')
        command(['docker', 'restart', '--time', '30', name])
        info = json.loads(command(['docker', 'inspect', name]))[0]
        host = info['NetworkSettings']['Networks'][name]['IPAddress']
        wait(healthy)
        assert query(host, 1053, 'api.fixture.test', tcp=True) == (0, ['192.0.2.8'])
        command(['docker', 'stop', '--time', '30', name])
        state = json.loads(command(['docker', 'inspect', name]))[0]['State']
        assert state['ExitCode'] == 0 and not state['OOMKilled']
        result['checks'].append('read-only non-root restart and clean shutdown')
        result['status'] = 'passed'
    finally:
        if container_created:
            logs = subprocess.run(['docker', 'logs', name], capture_output=True, text=True, timeout=30)
            (args.logs / 'container.log').write_text(logs.stdout + logs.stderr)
            command(['docker', 'rm', '-f', '-v', name])
        if network_created:
            command(['docker', 'network', 'rm', name])
        temporary.cleanup()
        result.setdefault('status', 'failed')
        (args.logs / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('CoreDNS image canary passed')


if __name__ == '__main__':
    main()
