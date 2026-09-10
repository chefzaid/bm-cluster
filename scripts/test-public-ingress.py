#!/usr/bin/env python3
"""Exercise HA ingress gates, credential handling and co-located origin routing."""
import contextlib
import importlib.util
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tunnel", ROOT / "scripts/configure-cloudflare-tunnel.py")
tunnel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tunnel)


class TunnelTest(unittest.TestCase):
    def test_verified_zone_routing_without_application_inventory(self):
        config = tunnel.tunnel_configuration("example.com")["config"]
        self.assertEqual([route.get("hostname") for route in config["ingress"]],
                         ["example.com", "*.example.com", None])
        for route in config["ingress"][:-1]:
            self.assertEqual(route["service"], "https://127.0.0.1:8444")
            self.assertEqual(route["originRequest"]["originServerName"], "example.com")
            self.assertNotIn("httpHostHeader", route["originRequest"])
            self.assertNotIn("noTLSVerify", route["originRequest"])
        self.assertEqual(config["ingress"][-1], {"service": "http_status:404"})

    def test_two_ready_servers_cannot_create_a_tunnel(self):
        nodes = [{"status": {"conditions": [{"type": "Ready", "status": ready}]}}
                 for ready in ("True", "True", "False")]
        with patch.object(tunnel, "kubectl", return_value={"items": nodes}), \
             patch.object(tunnel, "Cloudflare") as api, \
             patch.dict(os.environ, {"CLOUDFLARE_API_TOKEN": "fixture-private-token"}), \
             patch("sys.argv", ["prepare", "--domain", "example.com"]):
            with self.assertRaisesRegex(RuntimeError, "three Ready"):
                tunnel.main()
            api.assert_not_called()

    def test_token_only_enters_secret_and_preparation_does_not_publish_dns(self):
        requests, applies = [], []
        private_token = "fixture-tunnel-credential"
        class API:
            def __init__(self, _token):
                pass
            def request(self, method, path, body=None):
                requests.append((method, path, body))
                if path.startswith("/zones?"):
                    return [{"account": {"id": "a" * 32}}]
                if method == "GET" and "is_deleted=" in path:
                    return [{"id": "12345678-1234-1234-1234-123456789abc", "config_src": "cloudflare"}]
                if path.endswith("/token"):
                    return private_token
                return {}
        def kubectl(*args, data=None):
            if args[:2] == ("get", "nodes"):
                return {"items": [{"status": {"conditions": [{"type": "Ready", "status": "True"}]}}] * 3}
            applies.append(json.loads(data))
        output = io.StringIO()
        with patch.object(tunnel, "kubectl", side_effect=kubectl), patch.object(tunnel, "Cloudflare", API), \
             patch.dict(os.environ, {"CLOUDFLARE_API_TOKEN": "fixture-private-token", "CLOUDFLARE_ACCOUNT_ID": ""}), \
             patch("sys.argv", ["prepare", "--domain", "example.com"]), contextlib.redirect_stdout(output):
            tunnel.main()
        self.assertNotIn(private_token, output.getvalue())
        self.assertFalse(any("dns_records" in path for _, path, _ in requests))
        self.assertEqual(applies[0]["stringData"]["token"], private_token)
        self.assertNotIn(private_token, json.dumps(applies[1]))

    @staticmethod
    def ready_pod(name, node):
        return {'metadata': {'name': name}, 'spec': {'nodeName': node},
                'status': {'containerStatuses': [{'name': 'cloudflared', 'ready': True}],
                           'conditions': [{'type': 'Ready', 'status': 'True'}]}}

    def test_tls_gate_requires_three_distinct_hosts(self):
        pods = [self.ready_pod(str(index), 'node-' + str(index % 2)) for index in range(3)]
        with patch.object(tunnel, 'kubectl', return_value={'items': pods}), patch.object(tunnel, 'forward_origin') as forward:
            with self.assertRaisesRegex(RuntimeError, 'three distinct'):
                tunnel.verify_origins('infra', 'example.com')
            forward.assert_not_called()

    def test_tls_gate_checks_every_ready_origin_and_closes_forwards(self):
        pods = [self.ready_pod(str(index), 'node-' + str(index)) for index in range(3)]
        with patch.object(tunnel, 'kubectl', return_value={'items': pods}), \
             patch.object(tunnel, 'forward_origin', side_effect=[(str(index), 10000 + index) for index in range(3)]), \
             patch.object(tunnel, 'stop_forward') as stop, patch.object(tunnel, 'verify_origin') as verify:
            tunnel.verify_origins('infra', 'example.com')
            self.assertEqual(verify.call_count, 3)
            self.assertEqual(stop.call_count, 3)

    def test_tls_gate_fails_closed_after_certificate_reload_deadline(self):
        pods = [self.ready_pod(str(index), 'node-' + str(index)) for index in range(3)]
        with patch.object(tunnel, 'kubectl', return_value={'items': pods}), \
             patch.object(tunnel, 'forward_origin', return_value=('fixture', 10000)), \
             patch.object(tunnel, 'stop_forward') as stop, \
             patch.object(tunnel, 'verify_origin', side_effect=ssl.SSLCertVerificationError()), \
             patch.object(tunnel.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'public DNS was not changed'):
                tunnel.verify_origins('infra', 'example.com')
            stop.assert_called_once_with('fixture')

    def test_origin_handshake_verifies_certificate_hostname_and_preserves_host(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            received_host = None
            status = 404
            def do_GET(self):
                type(self).received_host = self.headers['Host']
                self.send_response(type(self).status)
                self.end_headers()
            def log_message(self, *_args):
                pass
        with tempfile.TemporaryDirectory(prefix='bm-origin-tls-test.') as directory:
            cert, key = Path(directory) / 'cert.pem', Path(directory) / 'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-keyout', str(key), '-out', str(cert), '-subj', '/CN=origin.example.com',
                '-addext', 'subjectAltName=DNS:origin.example.com'], check=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                port = server.server_address[1]
                tunnel.verify_origin(port, 'origin.example.com', cert)
                self.assertEqual(Handler.received_host, 'origin.example.com')
                with self.assertRaises(ssl.SSLCertVerificationError):
                    tunnel.verify_origin(port, 'wrong.example.com', cert)
                with self.assertRaises(ssl.SSLCertVerificationError):
                    tunnel.verify_origin(port, 'origin.example.com', ROOT / 'config/cloudflare-origin-ca.pem')
                Handler.status = 503
                with self.assertRaisesRegex(RuntimeError, 'HTTP 503'):
                    tunnel.verify_origin(port, 'origin.example.com', cert)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)


MOCK = '''#!/usr/bin/env python3
import json, os, pathlib, sys, yaml
tool, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
if tool == 'kubectl':
    if 'configmap' in args:
        print(json.dumps({'data': {'mode': os.environ['STORED_MODE']}}))
    sys.exit(0)
if '--install' in args:
    values = [args[i+1] for i,a in enumerate(args) if a == '--values']
    pathlib.Path(os.environ['RESULT']).write_text(json.dumps({'args': args, 'values': [yaml.safe_load(pathlib.Path(p).read_text()) for p in values]}))
'''


class InstallerTest(unittest.TestCase):
    def exercise(self, requested, stored):
        with tempfile.TemporaryDirectory(prefix="bm-ingress-test.") as directory:
            root = Path(directory)
            for folder in ("config", "scripts", "bin"):
                (root / folder).mkdir()
            for source in ("config/platform.env", "config/ingress-nginx-values.yaml", "config/ingress-nginx-ha-values.yaml", "scripts/configure-ingress.sh"):
                shutil.copy(ROOT / source, root / source)
            reconciler = root / "scripts/reconcile-cluster-topology.sh"
            reconciler.write_text("#!/bin/sh\n[ \"$HIGH_AVAILABILITY_ENABLED\" = true ]\n")
            reconciler.chmod(0o700)
            for name in ("kubectl", "helm"):
                path = root / "bin" / name
                path.write_text(MOCK)
                path.chmod(0o700)
            result_file = root / "result.json"
            env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
                   "STORED_MODE": stored, "HIGH_AVAILABILITY_ENABLED": requested,
                   "RESULT": str(result_file)}
            env.pop("CLOUDFLARE_API_TOKEN", None)
            run = subprocess.run(["bash", str(root / "scripts/configure-ingress.sh")], env=env,
                                 text=True, capture_output=True, timeout=30)
            result = json.loads(result_file.read_text()) if result_file.exists() else None
            return run, result

    def test_ha_inherits_and_preserves_writable_security_mounts(self):
        run, result = self.exercise("", "tunnel")
        self.assertEqual(run.returncode, 0, run.stderr)
        base, overlay = result["values"]
        original_volumes = {volume["name"] for volume in base["controller"]["extraVolumes"]}
        combined_volumes = {volume["name"] for volume in overlay["controller"]["extraVolumes"]}
        self.assertTrue(original_volumes < combined_volumes)
        self.assertIn("cloudflare-tunnel", combined_volumes)
        self.assertEqual(overlay["controller"]["kind"], "DaemonSet")
        self.assertIsNone(overlay["controller"]["nodeSelector"]["svccontroller.k3s.cattle.io/enablelb"])
        self.assertEqual(overlay["controller"]["config"]["proxy-real-ip-cidr"], "127.0.0.1/32,::1/128")
        self.assertEqual(overlay["controller"]["config"]["use-forwarded-headers"], "false")
        self.assertIn("controller.extraArgs.default-ssl-certificate=infra/swirlit-dev-tls", result['args'])
        sidecar = overlay["controller"]["extraContainers"][-1]
        self.assertEqual(sidecar["livenessProbe"]["httpGet"]["port"], 10254)
        self.assertEqual(sidecar["readinessProbe"]["httpGet"]["port"], 2000)

    def test_accidental_downgrade_and_invalid_mode_never_call_helm(self):
        for mode in ("false", "yes"):
            run, result = self.exercise(mode, "tunnel")
            self.assertNotEqual(run.returncode, 0)
            self.assertIsNone(result)

    def test_single_server_keeps_direct_ingress(self):
        run, result = self.exercise("false", "direct")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(result["values"]), 1)
        self.assertIn("controller.service.type=LoadBalancer", result["args"])


if __name__ == "__main__":
    unittest.main()
