#!/usr/bin/env python3
"""Reconcile one application's DNS and origin certificate on its selected cluster."""
import argparse
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlencode, quote

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from deployment_environments import load_inventory, environment_context, InventoryError
from onboarding_services import HTTP, ServiceError


def run(arguments, *, data=None):
    result = subprocess.run(arguments, input=data, text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise ServiceError(f"{arguments[0]} failed; check target access and certificate configuration")
    return result.stdout


def covers(pattern, hostname):
    return pattern == hostname or (pattern.startswith("*.") and hostname.count(".") == pattern.count(".")
                                   and hostname.endswith(pattern[1:]))


def cf(api, method, path, data=None):
    response = api.request(method, path, data)
    if not response.get("success"):
        raise ServiceError("Cloudflare rejected the request; check token permissions for the parent zone")
    return response


def edge_ready(api, zone_id, hostname):
    for page in range(1, 101):
        response = cf(api, "GET", f"/zones/{zone_id}/ssl/certificate_packs?" + urlencode({
            "status": "all", "deployment": "production", "per_page": 50, "page": page}))
        packs = response["result"]
        for pack in packs:
            if pack.get("status") == "active" and any(covers(item, hostname) for item in pack.get("hosts", [])):
                return
        if page >= response.get("result_info", {}).get("total_pages", 1):
            break
    raise ServiceError(f"Cloudflare has no active edge certificate covering {hostname}; provision Advanced/Custom edge coverage before publishing DNS (new Total TLS coverage requires DNS first)")


def certificate_valid(directory, domain):
    cert, key = directory / "tls.crt", directory / "tls.key"
    try:
        run(["openssl", "x509", "-in", str(cert), "-noout", "-checkend", "2592000"])
        for name in (domain, "probe." + domain):
            run(["openssl", "x509", "-in", str(cert), "-noout", "-checkhost", name])
        try:
            run(["openssl", "verify", "-CAfile", str(Path(__file__).resolve().parents[1] / "config/cloudflare-origin-ca.pem"), str(cert)])
        except ServiceError:
            # Publicly trusted custom certificates are supported and remain externally managed.
            run(["openssl", "verify", "-untrusted", str(cert), str(cert)])
        return run(["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"]) == run([
            "openssl", "pkey", "-in", str(key), "-pubout"])
    except ServiceError:
        return False


def reconcile(args):
    inventory = load_inventory(args.config, allow_partial=True)
    target = environment_context(inventory, args.environment)
    label = args.host_label
    if label != "@" and not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label):
        raise ServiceError("--host-label must be one DNS label or @")
    hostname = target["domain"] if label == "@" else label + "." + target["domain"]
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if not token:
        raise ServiceError("Set CLOUDFLARE_API_TOKEN; it is never written to configuration")
    kube = ["kubectl", "--kubeconfig", args.target_kubeconfig]
    config = json.loads(run([*kube, "config", "view", "--minify", "-o", "json"]))
    actual = config["clusters"][0]["cluster"]
    if actual.get("server", "").rstrip("/") != target["server"] or actual.get("insecure-skip-tls-verify"):
        raise ServiceError("Target kubeconfig does not match the selected registered cluster with verified TLS")
    namespace = json.loads(run([*kube, "get", "namespace", "apps", "-o", "json"]))
    if namespace.get("metadata", {}).get("labels", {}).get("bm-cluster.io/application-environment") != args.environment:
        raise ServiceError("Target namespace does not belong to the selected application environment")
    api = HTTP("https://api.cloudflare.com/client/v4", {"Authorization": "Bearer " + token})
    zones = cf(api, "GET", "/zones?" + urlencode({"name": inventory["platform"]["domain"], "status": "active"}))["result"]
    if len(zones) != 1:
        raise ServiceError("Cloudflare token must expose exactly one active parent zone")
    zone_id = quote(zones[0]["id"], safe="")
    if not args.certificate_only:
        edge_ready(api, zone_id, hostname)
    record_path = f"/zones/{zone_id}/dns_records"
    records = [] if args.certificate_only else cf(api, "GET", record_path + "?" + urlencode({"name": hostname, "per_page": 100}))["result"]
    addresses = [record for record in records if record.get("type") in ("A", "AAAA", "CNAME")]
    address = target["ingressAddress"]
    try:
        kind = "AAAA" if ipaddress.ip_address(address).version == 6 else "A"
    except ValueError:
        kind = "CNAME"
    owner = "bm-cluster:application:" + args.environment + ":" + label
    if len(addresses) > 1 or any(item.get("comment") not in (None, "", owner) or
                                  item.get("content") != address for item in addresses):
        raise ServiceError("Existing DNS points elsewhere or has another owner; migrate that record explicitly before onboarding")
    with tempfile.TemporaryDirectory(prefix="application-origin-") as temporary:
        directory = Path(temporary)
        secret = json.loads(run([*kube, "get", "secret", target["tlsSecretName"], "-n", "apps",
                                 "--ignore-not-found", "-o", "json"]) or "{}")
        for key in ("tls.crt", "tls.key"):
            path = directory / key
            path.write_bytes(base64.b64decode(secret.get("data", {}).get(key, "")))
            path.chmod(0o600)
        valid = certificate_valid(directory, target["domain"])
        if not valid and secret and secret.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/managed-by") != "bm-cluster":
            raise ServiceError("The externally managed origin certificate is invalid or expires within 30 days; renew it explicitly before onboarding")
        if args.check:
            print(f"[READY] Cloudflare prerequisites for {hostname}")
            return
        if not valid:
            run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(directory / "tls.key")])
            csr = run(["openssl", "req", "-new", "-key", str(directory / "tls.key"), "-subj", "/CN=*." + target["domain"]])
            issued = cf(api, "POST", "/certificates", {"hostnames": [target["domain"], "*." + target["domain"]],
                "requested_validity": 365, "request_type": "origin-rsa", "csr": csr})["result"]
            (directory / "tls.crt").write_text(issued["certificate"])
            if not certificate_valid(directory, target["domain"]):
                raise ServiceError("Cloudflare returned an invalid origin certificate")
            resource = {"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/tls", "metadata": {
                "name": target["tlsSecretName"], "namespace": "apps", "labels": {"app.kubernetes.io/managed-by": "bm-cluster"}},
                "data": {key: base64.b64encode((directory / key).read_bytes()).decode() for key in ("tls.crt", "tls.key")}}
            # Server-side apply keeps private keys out of last-applied annotations.
            run([*kube, "apply", "--server-side", "--field-manager=application-origin", "-f", "-"], data=json.dumps(resource))
    if not args.certificate_only:
        desired = {"name": hostname, "type": kind, "content": address, "proxied": True, "ttl": 1, "comment": owner}
        path = record_path + ("/" + quote(addresses[0]["id"], safe="") if addresses else "")
        cf(api, "PUT" if addresses else "POST", path, desired)
        verified = cf(api, "GET", record_path + "?" + urlencode({"name": hostname, "per_page": 100}))["result"]
        verified = [item for item in verified if item.get("type") in ("A", "AAAA", "CNAME")]
        if len(verified) != 1 or any(verified[0].get(key) != value for key, value in desired.items()):
            raise ServiceError("Cloudflare DNS did not converge")
    print(f"[READY] {'Origin certificate' if args.certificate_only else 'DNS and origin certificate'}: {hostname} -> {target['clusterName']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--environment", required=True, choices=("int", "uat", "prod"))
    parser.add_argument("--target-kubeconfig", required=True)
    parser.add_argument("--host-label", default="devapp")
    parser.add_argument("--certificate-only", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        reconcile(args)
    except (InventoryError, ServiceError, OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Application DNS: {error}\n")


if __name__ == "__main__":
    main()
