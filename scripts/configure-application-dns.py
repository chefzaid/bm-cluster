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
from deployment_environments import load_inventory, environment_context, application_hostname, uses_central_tls, InventoryError
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


def verify_hostname_owner(platform_kube, target, hostname, application):
    """Preserve routes already owned by another local Argo application.

    DNS may have no ownership comment and still serve an existing application.
    Only a self-referencing Argo tracking annotation proves which deployment owns
    an Ingress; copied annotations, untracked routes and peer environments fail.
    """
    if application is not None and not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", application):
        raise ServiceError("--application-name must be the application's Kubernetes name")
    ingresses = json.loads(run([*platform_kube, "get", "ingresses", "--all-namespaces", "-o", "json"]))
    for ingress in ingresses.get("items", []):
        if not any(rule.get("host") == hostname for rule in ingress.get("spec", {}).get("rules", [])):
            continue
        metadata = ingress.get("metadata", {})
        namespace, name = metadata.get("namespace", ""), metadata.get("name", "")
        tracking = metadata.get("annotations", {}).get("argocd.argoproj.io/tracking-id", "")
        owner, separator, reference = tracking.partition(":")
        same_resource = separator and reference == f"networking.k8s.io/Ingress:{namespace}/{name}"
        selected_owner = (application and namespace == target["namespace"] and
                          owner in {application, application + "-" + target["environment"]})
        legacy_owner = application and namespace == "apps" and owner == application
        if not same_resource or not (selected_owner or legacy_owner):
            raise ServiceError(f"Hostname {hostname} already belongs to another or unverified local Ingress; "
                               "use its exact --application-name for a same-application cutover, or migrate ownership explicitly")


def reconcile(args):
    inventory = load_inventory(args.config, allow_partial=True)
    target = environment_context(inventory, args.environment)
    label = args.host_label
    if label != "@" and not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label):
        raise ServiceError("--host-label must be one DNS label or @")
    hostname = application_hostname(target, label)
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if not token:
        raise ServiceError("Set CLOUDFLARE_API_TOKEN; it is never written to configuration")
    kube = ["kubectl", "--kubeconfig", args.target_kubeconfig]
    platform_kube = ["kubectl"]
    if getattr(args, "platform_kubeconfig", None):
        platform_kube.extend(["--kubeconfig", args.platform_kubeconfig])
    config = json.loads(run([*kube, "config", "view", "--minify", "-o", "json"]))
    actual = config["clusters"][0]["cluster"]
    expected_server = target["server"]
    if target.get("mode", "remote") == "local":
        platform = json.loads(run([*platform_kube, "config", "view", "--minify", "-o", "json"]))["clusters"][0]["cluster"]
        if platform.get("insecure-skip-tls-verify"):
            raise ServiceError("The local platform kubeconfig must verify TLS")
        expected_server = platform["server"].rstrip("/")
    if actual.get("server", "").rstrip("/") != expected_server or actual.get("insecure-skip-tls-verify"):
        raise ServiceError("Target kubeconfig does not match the selected registered cluster with verified TLS")
    namespace = json.loads(run([*kube, "get", "namespace", target["namespace"], "-o", "json"]))
    if namespace.get("metadata", {}).get("labels", {}).get("bm-cluster.io/application-environment") != args.environment:
        raise ServiceError("Target namespace does not belong to the selected application environment")
    if target.get("mode", "remote") == "local" and not args.certificate_only:
        verify_hostname_owner(platform_kube, target, hostname, getattr(args, "application_name", None))
    certificate_kube, certificate_namespace = kube, target["namespace"]
    if uses_central_tls(target):
        # A branch workload must never receive the shared platform wildcard key.
        # Only this trusted operator context can access the ingress certificate.
        certificate_kube, certificate_namespace = platform_kube, "infra"
        tls_store = json.loads(run([*platform_kube, "get", "tlsstore", "default", "-n", "infra", "-o", "json"]))
        if tls_store.get("spec", {}).get("defaultCertificate", {}).get("secretName") != target["tlsSecretName"]:
            raise ServiceError("The central Traefik default certificate does not match the registered TLS Secret")
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
        secret = json.loads(run([*certificate_kube, "get", "secret", target["tlsSecretName"], "-n", certificate_namespace,
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
                "name": target["tlsSecretName"], "namespace": certificate_namespace, "labels": {"app.kubernetes.io/managed-by": "bm-cluster"}},
                "data": {key: base64.b64encode((directory / key).read_bytes()).decode() for key in ("tls.crt", "tls.key")}}
            # Server-side apply keeps private keys out of last-applied annotations.
            run([*certificate_kube, "apply", "--server-side", "--field-manager=application-origin", "-f", "-"], data=json.dumps(resource))
    if not args.certificate_only:
        if target.get("mode", "remote") == "local":
            verify_hostname_owner(platform_kube, target, hostname, getattr(args, "application_name", None))
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
    parser.add_argument("--platform-kubeconfig", help="Central operator kubeconfig for shared TLS; defaults to the current context")
    parser.add_argument("--host-label", default="devapp")
    parser.add_argument("--application-name", help="Argo application identity required to reuse an existing local hostname")
    parser.add_argument("--certificate-only", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        reconcile(args)
    except (InventoryError, ServiceError, OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Application DNS: {error}\n")


if __name__ == "__main__":
    main()
