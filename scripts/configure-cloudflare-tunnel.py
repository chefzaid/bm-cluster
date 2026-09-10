#!/usr/bin/env python3
"""Prepare a named Cloudflare Tunnel; DNS switches only after ingress is ready."""

import argparse
import http.client
import json
import os
from pathlib import Path
import re
import selectors
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
API = "https://api.cloudflare.com/client/v4"


def kubectl(*args, data=None):
    result = subprocess.run(["kubectl", *args], input=data, text=True,
                            capture_output=True, check=False)
    if result.returncode:
        # Secret apply output is intentionally not included in failures.
        raise RuntimeError("kubectl failed: " + " ".join(args[:3]))
    return json.loads(result.stdout) if result.stdout.strip().startswith("{") else result.stdout


class Cloudflare:
    def __init__(self, token):
        self.token = token

    def request(self, method, path, body=None):
        payload = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(API + path, data=payload, method=method,
            headers={"Authorization": "Bearer " + self.token,
                     "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"Cloudflare {method} failed with HTTP {error.code}; "
                               "check account Tunnel Edit and Zone Read permissions") from None
        if not result.get("success"):
            raise RuntimeError(f"Cloudflare {method} failed; inspect token permissions and account ownership")
        return result["result"]


def tunnel_configuration(domain):
    # The platform transports its zone; application repositories own DNS and
    # Kubernetes Ingress routes. Adding an app never changes this configuration.
    hosts = [domain, f"*.{domain}"]
    return {"config": {"ingress": [
        {"hostname": host, "service": "https://127.0.0.1:8444",
         "originRequest": {"originServerName": domain,
                           "caPool": "/etc/cloudflared/ca.pem",
                           "connectTimeout": 10}}
        for host in dict.fromkeys(hosts)
    ] + [{"service": "http_status:404"}]}}


def verify_origin(port, domain, ca_file):
    """Match cloudflared's CA/SNI/Host verification over a local port-forward."""
    context = ssl.create_default_context(cafile=str(ca_file))
    with socket.create_connection(('127.0.0.1', port), timeout=5) as connection:
        with context.wrap_socket(connection, server_hostname=domain) as tls:
            tls.sendall(f'GET /__bm_tunnel_origin_probe__ HTTP/1.1\r\nHost: {domain}\r\nConnection: close\r\n\r\n'.encode())
            response = http.client.HTTPResponse(tls)
            response.begin()
            # An unowned apex returns the catch-all 404. Authentication redirects
            # are also valid: this gate needs a verified working TLS listener.
            if not 200 <= response.status < 500:
                raise RuntimeError(f'Origin returned HTTP {response.status}')


def forward_origin(namespace, pod):
    process = subprocess.Popen(['kubectl', 'port-forward', '--address=127.0.0.1',
        '-n', namespace, 'pod/' + pod, ':8444'], stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True)
    try:
        deadline = time.monotonic() + 15
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline and process.poll() is None:
                if not selector.select(timeout=1):
                    continue
                line = process.stdout.readline()
                match = re.search(r'Forwarding from 127\.0\.0\.1:(\d+) -> 8444', line)
                if match:
                    return process, int(match[1])
        raise RuntimeError('Unable to forward the ingress TLS listener')
    except BaseException:
        stop_forward(process)
        raise


def stop_forward(process):
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    process.stdout.close()


def verify_origins(namespace, domain):
    pods = kubectl('get', 'pods', '-n', namespace, '-l',
        'app.kubernetes.io/component=controller,app.kubernetes.io/name=ingress-nginx', '-o', 'json')['items']
    ready = [pod for pod in pods if not pod['metadata'].get('deletionTimestamp')
        and pod.get('spec', {}).get('nodeName')
        and any(c.get('name') == 'cloudflared' and c.get('ready') for c in pod.get('status', {}).get('containerStatuses', []))
        and any(c['type'] == 'Ready' and c['status'] == 'True' for c in pod.get('status', {}).get('conditions', []))]
    if len({pod['spec']['nodeName'] for pod in ready}) < 3:
        raise RuntimeError('Public DNS was not changed: three distinct ready ingress hosts are required')
    for pod in ready:
        process, port = forward_origin(namespace, pod['metadata']['name'])
        try:
            # Secret propagation and NGINX reload are asynchronous. Retry the
            # verified handshake briefly; never weaken verification to proceed.
            for attempt in range(10):
                try:
                    verify_origin(port, domain, ROOT / 'config/cloudflare-origin-ca.pem')
                    break
                except (OSError, http.client.HTTPException, RuntimeError):
                    if attempt == 9:
                        raise RuntimeError(f"Ingress TLS verification failed on {pod['spec']['nodeName']}; public DNS was not changed") from None
                    time.sleep(2)
        finally:
            stop_forward(process)
    print('All ready tunnel origins passed CA, hostname and HTTPS verification.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--domain", default=os.environ.get("PLATFORM_DOMAIN", ""))
    parser.add_argument("--namespace", default="infra")
    parser.add_argument("--verify-origins", action="store_true", help="verify ready ingress TLS listeners without Cloudflare API changes")
    args = parser.parse_args()
    if not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}", args.domain):
        parser.error("PLATFORM_DOMAIN/--domain must be a public DNS domain")
    if args.verify_origins:
        verify_origins(args.namespace, args.domain)
        return
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if not token:
        parser.error("set CLOUDFLARE_API_TOKEN (Account Cloudflare Tunnel Edit, Zone Read)")
    nodes = kubectl("get", "nodes", "-l", "node-role.kubernetes.io/control-plane", "-o", "json")["items"]
    ready = [node for node in nodes if any(c["type"] == "Ready" and c["status"] == "True"
             for c in node.get("status", {}).get("conditions", []))]
    if len(ready) < 3:
        raise RuntimeError("HA ingress needs at least three Ready control planes; no Cloudflare changes made")
    cf = Cloudflare(token)
    zones = cf.request("GET", "/zones?" + urllib.parse.urlencode({"name": args.domain}))
    if len(zones) != 1:
        raise RuntimeError("Create the public Cloudflare zone first, using configure-cloudflare.sh")
    account = zones[0]["account"]["id"]
    configured_account = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")
    if configured_account and account != configured_account:
        raise RuntimeError("CLOUDFLARE_ACCOUNT_ID does not own the selected zone")
    name = "bm-cluster-" + args.domain.replace(".", "-")
    base = f"/accounts/{account}/cfd_tunnel"
    matches = cf.request("GET", base + "?" + urllib.parse.urlencode({"name": name, "is_deleted": "false"}))
    if len(matches) > 1:
        raise RuntimeError("Multiple managed tunnels match; resolve the duplicate names")
    tunnel = matches[0] if matches else cf.request("POST", base, {"name": name, "config_src": "cloudflare"})
    if tunnel.get("config_src") != "cloudflare":
        raise RuntimeError("The existing named tunnel is locally managed; refusing to replace it")
    tunnel_id = tunnel["id"]
    cf.request("PUT", base + f"/{tunnel_id}/configurations", tunnel_configuration(args.domain))
    tunnel_token = cf.request("GET", base + f"/{tunnel_id}/token")
    if not isinstance(tunnel_token, str) or not tunnel_token:
        raise RuntimeError("Cloudflare returned no tunnel token")
    secret = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "cloudflare-tunnel", "namespace": args.namespace},
              "type": "Opaque", "stringData": {"token": tunnel_token, "ca.pem": (ROOT / "config/cloudflare-origin-ca.pem").read_text()}}
    kubectl("apply", "-f", "-", data=json.dumps(secret))
    # A candidate is deliberately not active: configure-cloudflare.sh must see
    # three ready co-located connectors before it changes public DNS.
    state = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "bm-cluster-public-ingress", "namespace": args.namespace},
             "data": {"mode": "tunnel", "domain": args.domain, "tunnelID": tunnel_id, "publishedTunnelID": ""}}
    kubectl("apply", "-f", "-", data=json.dumps(state))
    print("Tunnel prepared. Install HA ingress and verify three connectors before publishing DNS.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, urllib.error.URLError) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        sys.exit(1)
