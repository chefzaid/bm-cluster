#!/usr/bin/env python3
"""Fence one explicitly inventoried host before requesting non-graceful recovery."""
import argparse
import base64
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

TAINT = 'node.kubernetes.io/out-of-service'
POLICY = 'node.bm-cluster.io/fenced-detach-policy'
STALE_SECONDS = 300
SURVIVOR_FRESH_SECONDS = 60
REQUEST_TIMEOUT = 10
POWER_POLLS = 24
POWER_POLL_INTERVAL = 5
MAX_RESPONSE = 1024 * 1024


class Refusal(Exception):
    """A sanitized, operator-readable reason; never includes response bodies."""


def require(condition, reason):
    if not condition:
        raise Refusal(reason)


def identity(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError, TypeError):
        raise Refusal('Missing or invalid hardware/node UUID') from None


def https_url(value):
    try:
        require(isinstance(value, str) and not any(ord(c) < 33 for c in value), 'Invalid HTTPS URL')
        parsed = urllib.parse.urlsplit(value)
        require(parsed.scheme == 'https' and parsed.hostname and parsed.username is None and parsed.password is None,
                'A credential-free HTTPS URL is required')
        require(not parsed.query and not parsed.fragment and '%' not in parsed.path and '\\' not in value,
                'URL query, fragment, encoded path, or backslash is forbidden')
        port = parsed.port or 443
        require(1 <= port <= 65535, 'Invalid HTTPS port')
        require(not any(part in ('.', '..') for part in parsed.path.split('/')), 'Noncanonical URL path')
        return parsed, (parsed.hostname.lower(), port)
    except ValueError:
        raise Refusal('Invalid HTTPS URL') from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise Refusal('HTTP redirects are forbidden')


class HTTPS:
    def __init__(self, origin, ca_file, authorization):
        _, self.origin = https_url(origin)
        self.authorization = authorization
        try:
            context = ssl.create_default_context(cafile=str(ca_file))
            self.opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context), NoRedirect())
        except (OSError, ssl.SSLError):
            raise Refusal('Cannot load the required HTTPS CA certificate') from None

    def request(self, method, url, body=None, content_type='application/json'):
        _, origin = https_url(url)
        require(origin == self.origin, 'Cross-origin credential forwarding is forbidden')
        headers = {'Accept': 'application/json', 'Authorization': self.authorization()}
        if body is not None:
            headers['Content-Type'] = content_type
        request = urllib.request.Request(url, method=method, headers=headers,
                                         data=None if body is None else json.dumps(body).encode())
        try:
            with self.opener.open(request, timeout=REQUEST_TIMEOUT) as response:
                require(response.status in (200, 201, 202, 204), 'Unexpected HTTPS response status')
                payload = response.read(MAX_RESPONSE + 1)
                require(len(payload) <= MAX_RESPONSE, 'HTTPS response exceeds the size limit')
                return json.loads(payload) if payload else {}
        except urllib.error.HTTPError as error:
            raise Refusal(f'HTTPS request failed with status {error.code}') from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            raise Refusal('HTTPS request failed or returned invalid JSON') from None


class Kubernetes:
    def __init__(self, service_account_dir):
        directory = Path(service_account_dir)
        self.base = 'https://kubernetes.default.svc'
        self.http = HTTPS(self.base, directory / 'ca.crt',
                          lambda: 'Bearer ' + (directory / 'token').read_text().strip())

    def snapshot(self):
        # Default resourceVersion requests current API data, not an explicitly
        # stale cache read. An unreachable/quorumless API fails the entire run.
        nodes = self.http.request('GET', self.base + '/api/v1/nodes')
        leases = self.http.request('GET', self.base + '/apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases')
        require(isinstance(nodes.get('items'), list) and isinstance(leases.get('items'), list), 'Incomplete Kubernetes inventory')
        return nodes['items'], leases['items']

    def taint(self, node):
        metadata = node['metadata']
        taints = list(node.get('spec', {}).get('taints', []))
        require(not any(t.get('key') == TAINT and t.get('effect') == 'NoExecute' for t in taints), 'Node is already out of service')
        taints.append({'key': TAINT, 'value': 'redfish-fenced', 'effect': 'NoExecute'})
        patch = [
            {'op': 'test', 'path': '/metadata/uid', 'value': metadata['uid']},
            {'op': 'test', 'path': '/metadata/resourceVersion', 'value': metadata['resourceVersion']},
            {'op': 'test', 'path': '/status/nodeInfo/systemUUID', 'value': node['status']['nodeInfo']['systemUUID']},
            {'op': 'add', 'path': '/spec/taints', 'value': taints},
        ]
        self.http.request('PATCH', self.base + '/api/v1/nodes/' + urllib.parse.quote(metadata['name'], safe=''),
                          patch, 'application/json-patch+json')


class Redfish:
    def __init__(self, entry, secret_dir):
        self.entry = entry
        self.url = entry['computerSystemURL'].rstrip('/')
        self.parsed, self.origin = https_url(self.url)
        credential = base64.b64encode((entry['username'] + ':' + entry['password']).encode()).decode()
        self.http = HTTPS(self.url, secret_dir / entry['caFile'], lambda: 'Basic ' + credential)

    def system(self):
        result = self.http.request('GET', self.url)
        require(identity(result.get('UUID')) == self.entry['systemUUID'], 'Redfish ComputerSystem UUID does not match the allowed host')
        require(result.get('@odata.id', self.parsed.path).rstrip('/') == self.parsed.path,
                'Redfish returned a different ComputerSystem resource')
        return result

    def force_off(self, system):
        action = system.get('Actions', {}).get('#ComputerSystem.Reset', {})
        allowed = action.get('ResetType@Redfish.AllowableValues', [])
        require(isinstance(allowed, list) and 'ForceOff' in allowed, 'BMC does not explicitly advertise ForceOff support')
        target = urllib.parse.urljoin(self.url, action.get('target', ''))
        parsed, origin = https_url(target)
        require(origin == self.origin and parsed.path == self.parsed.path + '/Actions/ComputerSystem.Reset',
                'Reset action must target the same HTTPS ComputerSystem')
        self.http.request('POST', target, {'ResetType': 'ForceOff'})

    def wait_off(self):
        for attempt in range(POWER_POLLS):
            if self.system().get('PowerState') == 'Off':
                return
            if attempt + 1 < POWER_POLLS:
                time.sleep(POWER_POLL_INTERVAL)
        raise Refusal('BMC did not confirm PowerState Off; no recovery taint was applied')


def load_inventory(path, allowed_nodes):
    try:
        raw = path.read_bytes()
        require(len(raw) <= MAX_RESPONSE, 'Fencing inventory exceeds the size limit')
        inventory = json.loads(raw)
    except (OSError, ValueError):
        raise Refusal('Mounted fencing inventory is missing or invalid') from None
    require(inventory.get('version') == 1 and isinstance(inventory.get('nodes'), list), 'Unsupported fencing inventory format')
    entries = inventory['nodes']
    require(entries and len(entries) <= 100, 'Explicit, nonempty fencing inventory is required')
    names, uuids, systems = set(), set(), set()
    for entry in entries:
        require(isinstance(entry, dict) and
                {'name', 'nodeUID', 'systemUUID', 'computerSystemURL', 'username', 'password', 'caFile'} <= entry.keys(),
                'Fencing target is incomplete')
        name = entry['name']
        require(isinstance(name, str) and re.fullmatch(r'[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?', name), 'Invalid node name')
        require(name not in names, 'Duplicate fencing target name')
        names.add(name)
        entry['nodeUID'], entry['systemUUID'] = identity(entry['nodeUID']), identity(entry['systemUUID'])
        require(entry['systemUUID'] not in uuids, 'Duplicate hardware UUID in fencing inventory')
        uuids.add(entry['systemUUID'])
        parsed, origin = https_url(entry['computerSystemURL'])
        require(re.fullmatch(r'/redfish/v1/Systems/[^/]+/?', parsed.path), 'Expected an exact Redfish ComputerSystem URL')
        require((origin, parsed.path.rstrip('/')) not in systems, 'Duplicate ComputerSystem URL in inventory')
        systems.add((origin, parsed.path.rstrip('/')))
        for field in ('username', 'password'):
            value = entry[field]
            require(isinstance(value, str) and value and not any(ord(c) < 32 for c in value), 'Invalid mounted BMC credentials')
        require(':' not in entry['username'], 'BMC Basic authentication username cannot contain a colon')
        ca = entry['caFile']
        require(isinstance(ca, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', ca), 'CA reference must be a mounted Secret key')
        require((path.parent / ca).resolve().is_relative_to(path.parent.resolve()) and (path.parent / ca).is_file(),
                'CA file is missing or escapes the mounted Secret')
    require(names == set(allowed_nodes) and len(allowed_nodes) == len(names), 'Inventory must exactly match the explicit allowed node names')
    planes = inventory.get('controlPlanes')
    require(isinstance(planes, dict) and len(planes) >= 3 and len(planes) % 2 == 1,
            'Pin an odd membership of at least three control-plane name/UID pairs')
    inventory['controlPlanes'] = {name: identity(uid) for name, uid in planes.items()}
    require(len(set(inventory['controlPlanes'].values())) == len(planes), 'Duplicate control-plane UID')
    return inventory


def lease_age(node, leases, now):
    name, uid = node['metadata']['name'], node['metadata']['uid']
    matches = [lease for lease in leases if lease.get('metadata', {}).get('name') == name]
    require(len(matches) == 1, 'Node Lease is missing or ambiguous')
    lease = matches[0]
    require(any(owner.get('kind') == 'Node' and owner.get('uid') == uid
                for owner in lease.get('metadata', {}).get('ownerReferences', [])), 'Node Lease belongs to a different node UID')
    require(lease.get('spec', {}).get('holderIdentity') == name, 'Node Lease holder does not match the node')
    try:
        renewed = datetime.fromisoformat(lease['spec']['renewTime'].replace('Z', '+00:00'))
        require(renewed.tzinfo is not None, 'Node Lease timestamp lacks a timezone')
        age = (now - renewed).total_seconds()
        require(age >= 0, 'Node Lease timestamp is in the future')
        return age
    except (KeyError, TypeError, ValueError):
        raise Refusal('Invalid Node Lease timestamp') from None


def ready(node):
    conditions = [c.get('status') for c in node.get('status', {}).get('conditions', []) if c.get('type') == 'Ready']
    require(len(conditions) == 1 and conditions[0] in ('True', 'False', 'Unknown'), 'Node Ready condition is missing or ambiguous')
    return conditions[0] == 'True'


def validate_current_inventory(inventory, nodes, require_policy=False):
    by_name = {node['metadata']['name']: node for node in nodes}
    require(len(by_name) == len(nodes), 'Duplicate Kubernetes node names')
    planes = {name: identity(node['metadata']['uid']) for name, node in by_name.items()
              if any(role in node['metadata'].get('labels', {}) for role in
                     ('node-role.kubernetes.io/control-plane', 'node-role.kubernetes.io/master'))}
    require(planes == inventory['controlPlanes'], 'Registered control-plane membership differs from the pinned inventory')
    if require_policy:
        require(all(by_name[name]['metadata'].get('annotations', {}).get(POLICY) == 'verified' for name in planes),
                'All control planes require a verified fencing-based storage detach policy')
    for entry in inventory['nodes']:
        require(entry['name'] in by_name, 'Allowed node no longer exists')
        target = by_name[entry['name']]
        require(identity(target['metadata']['uid']) == entry['nodeUID'], 'Target Kubernetes node UID changed')
        require(identity(target.get('status', {}).get('nodeInfo', {}).get('systemUUID')) == entry['systemUUID'], 'Target systemUUID changed')
    return by_name, planes


def eligible(entry, inventory, nodes, leases, now):
    by_name, planes = validate_current_inventory(inventory, nodes, require_policy=True)
    target = by_name[entry['name']]
    require(identity(target['metadata']['uid']) == entry['nodeUID'], 'Target Kubernetes node UID changed')
    require(identity(target.get('status', {}).get('nodeInfo', {}).get('systemUUID')) == entry['systemUUID'], 'Target systemUUID changed')
    require(not target['metadata'].get('deletionTimestamp'), 'Target node is being deleted')
    if ready(target) or any(t.get('key') == TAINT and t.get('effect') == 'NoExecute' for t in target.get('spec', {}).get('taints', [])):
        return None
    if lease_age(target, leases, now) < STALE_SECONDS:
        return None
    condition = next(c for c in target['status']['conditions'] if c.get('type') == 'Ready')
    try:
        changed = datetime.fromisoformat(condition['lastTransitionTime'].replace('Z', '+00:00'))
        require(changed.tzinfo is not None, 'Node Ready transition timestamp lacks a timezone')
        age = (now - changed).total_seconds()
        require(age >= 0, 'Node Ready transition timestamp is in the future')
    except (KeyError, TypeError, ValueError):
        raise Refusal('Invalid Node Ready transition timestamp') from None
    if age < STALE_SECONDS:
        return None
    survivors = [node for name, node in by_name.items() if name in planes and name != entry['name'] and
                 not node['metadata'].get('deletionTimestamp') and ready(node) and
                 lease_age(node, leases, now) < SURVIVOR_FRESH_SECONDS]
    require(len(survivors) >= len(planes) // 2 + 1, 'Fresh Ready control-plane survivors do not form an etcd majority')
    return target


def run(inventory, secret_dir, kubernetes, provider=Redfish, apply=False, now=None):
    clock = now or (lambda: datetime.now(timezone.utc))
    for entry in inventory['nodes']:
        nodes, leases = kubernetes.snapshot()
        target = eligible(entry, inventory, nodes, leases, clock())
        if target is None:
            continue
        redfish = provider(entry, secret_dir)
        system = redfish.system()  # UUID and CA validation before any power request.
        if not apply:
            print(f"Eligible host verified (check only): {entry['name']}")
            continue
        nodes, leases = kubernetes.snapshot()
        require(eligible(entry, inventory, nodes, leases, clock()) is not None, 'Target recovered before the power request')
        if system.get('PowerState') != 'Off':
            # Refresh the physical identity immediately before ForceOff as well.
            system = redfish.system()
            nodes, leases = kubernetes.snapshot()
            require(eligible(entry, inventory, nodes, leases, clock()) is not None, 'Target recovered before ForceOff')
            if system.get('PowerState') != 'Off':
                redfish.force_off(system)
        redfish.wait_off()
        nodes, leases = kubernetes.snapshot()
        target = eligible(entry, inventory, nodes, leases, clock())
        require(target is not None, 'Target identity, liveness, or quorum changed after fencing')
        require(redfish.system().get('PowerState') == 'Off', 'Power-off confirmation changed before recovery')
        kubernetes.taint(target)  # UID/resourceVersion tests make this a guarded patch.
        print(f"Power-off verified; out-of-service recovery requested: {entry['name']}")
        return 1  # At most one fenced host per run.
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, default=Path('/etc/node-fencing/inventory.json'))
    parser.add_argument('--allowed-nodes', required=True, help='Explicit comma-separated Kubernetes node names')
    parser.add_argument('--service-account-dir', type=Path, default=Path('/var/run/secrets/kubernetes.io/serviceaccount'))
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--apply', action='store_true', help='Permit ForceOff and the guarded recovery taint')
    modes.add_argument('--check-inventory', action='store_true', help='Use local kubectl to check shape and live identities; never contact Redfish')
    args = parser.parse_args()
    try:
        inventory = load_inventory(args.inventory, args.allowed_nodes.split(','))
        if args.check_inventory:
            result = subprocess.run(['kubectl', '--request-timeout=10s', 'get', 'nodes', '-o', 'json'],
                                    check=True, capture_output=True, text=True, timeout=20)
            validate_current_inventory(inventory, json.loads(result.stdout)['items'])
            print('Fencing inventory matches current node and control-plane identities; no Redfish requests made')
        else:
            run(inventory, args.inventory.parent, Kubernetes(args.service_account_dir), apply=args.apply)
    except Refusal as error:
        print(f'Fencing refused: {error}', file=sys.stderr)
        return 1
    except Exception:
        # Inventory/HTTP exceptions may carry credentials or provider response
        # bodies. Do not emit traceback or repr for this privileged automation.
        print('Fencing refused: unexpected input or provider failure; no further actions attempted', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
