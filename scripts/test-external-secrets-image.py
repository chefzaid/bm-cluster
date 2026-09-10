#!/usr/bin/env python3
"""Exercise the final ESO image against disposable Kubernetes and Vault fixtures.

Only local, already-built images and verified envtest binaries are used. Every
container runs on a newly created internal Docker network, without published
ports, host namespaces, privileged mode, or production Kubernetes credentials.
"""
import argparse
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid


SOURCE_COMMIT = "279f56c84d5d4058c3bfdeeaf5b1c2febb8851c0"


def run(command, data=None, timeout=90, check=True):
    return subprocess.run(command, input=data, capture_output=True, timeout=timeout, check=check)


def wait_for(check, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError, urllib.error.URLError, subprocess.CalledProcessError,
                subprocess.TimeoutExpired):
            pass
        time.sleep(2)
    raise TimeoutError("Fixture did not reach the expected state; see private logs")


def encoded(data):
    return base64.b64encode(data).decode()


class Canary:
    def __init__(self, args):
        self.args = args
        self.prefix = "eso-security-" + uuid.uuid4().hex[:12]
        self.network = None
        self.containers = []
        self.checks = []
        self.namespace = "eso-fixture"
        self.root_token = secrets.token_urlsafe(32)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.tmp = tempfile.TemporaryDirectory(prefix="fixture-", dir=args.logs)
        self.directory = Path(self.tmp.name)
        for name in ("authority", "api", "webhook", "client"):
            (self.directory / name).mkdir(mode=0o755)
            (self.directory / name).chmod(0o755)
        self.ca = self.directory / "authority/ca.crt"
        self.ca_key = self.directory / "authority/ca.key"
        self.kubeconfig = self.directory / "client/config"

    def kubectl(self, arguments, obj=None, check=True):
        payload = json.dumps(obj).encode() if obj is not None else None
        return run([str(self.args.kubectl), "--kubeconfig", str(self.kubeconfig),
                    "--request-timeout=20s", *arguments], data=payload, check=check, timeout=120)

    def apply(self, obj):
        self.kubectl(["apply", "-f", "-"], obj)

    def get(self, kind, name, namespaced=True):
        command = ["get", kind, name, "-o", "json"]
        if namespaced:
            command += ["-n", self.namespace]
        return json.loads(self.kubectl(command).stdout)

    def ready(self, kind, name, namespaced=True, expected=True):
        obj = self.get(kind, name, namespaced)
        return any(c["type"] == "Ready" and c["status"] == str(expected)
                   for c in obj.get("status", {}).get("conditions", []))

    def value_matches(self, name, expected):
        obj = self.get("secret", name)
        return base64.b64decode(obj.get("data", {}).get("value", "")) == expected.encode()

    def http(self, url, obj=None, headers=None, method=None):
        request = urllib.request.Request(url, data=json.dumps(obj).encode() if obj is not None else None,
                                         headers={"Content-Type": "application/json", **(headers or {})},
                                         method=method)
        with self.opener.open(request, timeout=15) as response:
            body = response.read()
            return json.loads(body) if body else None

    def vault(self, path, obj=None, method=None):
        return self.http(f"http://{self.ips['vault']}:8200/v1/{path}", obj,
                         {"X-Vault-Token": self.root_token}, method)

    def certificate(self, name, common_name, extensions):
        folder = self.directory / "authority"
        key, csr, crt = (folder / f"{name}.{suffix}" for suffix in ("key", "csr", "crt"))
        ext = folder / f"{name}.ext"
        ext.write_text("basicConstraints=critical,CA:FALSE\n"
                       "keyUsage=critical,digitalSignature,keyEncipherment\n" + extensions + "\n")
        run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key),
             "-out", str(csr), "-subj", common_name])
        run(["openssl", "x509", "-req", "-in", str(csr), "-CA", str(self.ca),
             "-CAkey", str(self.ca_key), "-CAcreateserial", "-days", "7", "-sha256",
             "-extfile", str(ext), "-out", str(crt)])
        return crt, key

    @staticmethod
    def copy_for_container(source, destination):
        # The enclosing fixture directory is 0700. Only the specific child
        # directory is bind-mounted; UID 10001 can read these synthetic keys.
        shutil.copyfile(source, destination)
        destination.chmod(0o644)

    def start(self, component, image, entrypoint, arguments, memory, mounts=(), environment=None, tmpfs=()):
        name = self.prefix + "-" + component
        command = ["docker", "run", "-d", "--pull=never", "--name", name,
                   "--label", "bm-cluster.security-canary=" + self.prefix,
                   "--network", self.network, "--network-alias", component,
                   "--ip", self.ips[component], "--memory", memory, "--memory-swap", memory,
                   "--cpus=0.5", "--pids-limit=256", "--user=10001:10001", "--read-only",
                   "--cap-drop=ALL", "--security-opt=no-new-privileges", "--entrypoint", entrypoint]
        for source, destination in mounts:
            command += ["--mount", f"type=bind,src={source},dst={destination},readonly"]
        for destination, size in tmpfs:
            command += ["--tmpfs", f"{destination}:uid=10001,gid=10001,mode=0700,size={size}"]
        if environment:
            env_file = self.directory / (component + ".env")
            env_file.write_text("".join(f"{key}={value}\n" for key, value in environment.items()))
            command += ["--env-file", str(env_file)]
        # Record the owned name before Docker runs so partial failures clean up.
        self.containers.append(name)
        run([*command, image, *arguments], timeout=120)
        return name

    def prepare(self):
        # Let Docker select an unused subnet, then configure it explicitly:
        # fixed container IPs require a user-configured IPAM subnet.
        self.network = self.prefix
        network_command = ["docker", "network", "create", "--internal", "--driver=bridge",
                           "--label", "bm-cluster.security-canary=" + self.prefix]
        run([*network_command, self.network])
        allocated = json.loads(run(["docker", "network", "inspect", self.network]).stdout)[0]["IPAM"]["Config"][0]
        run(["docker", "network", "rm", self.network])
        run([*network_command, "--subnet", allocated["Subnet"], "--gateway", allocated["Gateway"], self.network])
        network = json.loads(run(["docker", "network", "inspect", self.network]).stdout)[0]
        if not network.get("Internal"):
            raise ValueError("Canary network must be internal")
        subnet = ipaddress.ip_network(network["IPAM"]["Config"][0]["Subnet"])
        self.ips = {name: str(subnet.network_address + number) for number, name in
                    enumerate(("api", "etcd", "vault", "controller", "webhook"), start=10)}
        run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "7",
             "-sha256", "-keyout", str(self.ca_key), "-out", str(self.ca),
             "-subj", "/CN=ESO disposable fixture CA", "-addext", "basicConstraints=critical,CA:TRUE",
             "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
        api_crt, api_key = self.certificate("api", "/CN=eso-fixture-api",
                                          f"subjectAltName=IP:{self.ips['api']}\nextendedKeyUsage=serverAuth")
        client_crt, client_key = self.certificate("client", "/CN=eso-fixture-admin/O=system:masters",
                                                "extendedKeyUsage=clientAuth")
        for source, name in ((api_crt, "tls.crt"), (api_key, "tls.key"), (self.ca, "ca.crt")):
            self.copy_for_container(source, self.directory / "api" / name)
        signing_key = self.directory / "authority/service-account.key"
        run(["openssl", "genrsa", "-out", str(signing_key), "2048"])
        self.copy_for_container(signing_key, self.directory / "api/service-account.key")
        self.rotate_webhook_certificate()
        config = {
            "apiVersion": "v1", "kind": "Config", "current-context": "fixture",
            "clusters": [{"name": "fixture", "cluster": {
                "server": f"https://{self.ips['api']}:6443", "certificate-authority-data": encoded(self.ca.read_bytes())}}],
            "users": [{"name": "fixture", "user": {"client-certificate-data": encoded(client_crt.read_bytes()),
                                                         "client-key-data": encoded(client_key.read_bytes())}}],
            "contexts": [{"name": "fixture", "context": {"cluster": "fixture", "user": "fixture"}}],
        }
        self.kubeconfig.write_text(json.dumps(config))
        self.kubeconfig.chmod(0o644)

    def rotate_webhook_certificate(self):
        cert, key = self.certificate("webhook-" + uuid.uuid4().hex[:8], "/CN=webhook",
                                    f"subjectAltName=DNS:webhook,IP:{self.ips['webhook']}\nextendedKeyUsage=serverAuth")
        for source, name in ((cert, "tls.crt"), (key, "tls.key"), (self.ca, "ca.crt")):
            self.copy_for_container(source, self.directory / "webhook" / name)

    def infrastructure(self):
        image = self.args.image_id
        assets = self.args.assets
        self.start("etcd", image, "/tools/etcd", ["--name=fixture", "--data-dir=/data",
                   "--listen-client-urls=http://0.0.0.0:2379", "--advertise-client-urls=http://etcd:2379",
                   "--listen-peer-urls=http://127.0.0.1:2380", "--initial-advertise-peer-urls=http://127.0.0.1:2380",
                   "--initial-cluster=fixture=http://127.0.0.1:2380", "--initial-cluster-token=" + self.prefix],
                   "256m", mounts=[(assets / "etcd", "/tools/etcd")], tmpfs=[("/data", "128m"), ("/tmp", "32m")])
        self.start("api", image, "/tools/kube-apiserver", ["--etcd-servers=http://etcd:2379",
                   "--bind-address=0.0.0.0", "--advertise-address=" + self.ips["api"], "--secure-port=6443",
                   "--tls-cert-file=/fixture/tls.crt", "--tls-private-key-file=/fixture/tls.key",
                   "--client-ca-file=/fixture/ca.crt", "--authorization-mode=RBAC", "--anonymous-auth=false",
                   "--service-account-issuer=https://kubernetes.fixture.invalid",
                   "--service-account-key-file=/fixture/service-account.key",
                   "--service-account-signing-key-file=/fixture/service-account.key",
                   "--service-cluster-ip-range=10.97.0.0/24", "--allow-privileged=false"],
                   "1024m", mounts=[(assets / "kube-apiserver", "/tools/kube-apiserver"),
                                    (self.directory / "api", "/fixture")], tmpfs=[("/tmp", "128m")])
        wait_for(lambda: self.kubectl(["get", "--raw=/readyz"]).stdout.strip() == b"ok")
        version = json.loads(self.kubectl(["get", "--raw=/version"]).stdout)
        if not version["gitVersion"].startswith("v1.36."):
            raise ValueError("The disposable API must use Kubernetes 1.36")
        self.api_version = version["gitVersion"]
        crds = run(["git", "-C", str(self.args.source), "show", "HEAD:deploy/crds/bundle.yaml"]).stdout
        crd_file = self.directory / "crds.yaml"
        crd_file.write_bytes(crds)
        self.kubectl(["apply", "--server-side", "-f", str(crd_file)])
        self.kubectl(["wait", "--for=condition=Established", "--timeout=90s", "-f", str(crd_file)])
        self.apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": self.namespace}})
        for name in ("vault-reviewer", "eso-auth", "unbound-auth"):
            self.apply({"apiVersion": "v1", "kind": "ServiceAccount",
                        "metadata": {"name": name, "namespace": self.namespace}})
        self.apply({"apiVersion": "rbac.authorization.k8s.io/v1", "kind": "ClusterRoleBinding",
                    "metadata": {"name": "fixture-vault-reviewer"},
                    "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "system:auth-delegator"},
                    "subjects": [{"kind": "ServiceAccount", "name": "vault-reviewer", "namespace": self.namespace}]})
        self.start("vault", self.args.vault_image_id, "/bin/vault",
                   ["server", "-dev", "-dev-no-store-token", "-dev-listen-address=0.0.0.0:8200"], "512m",
                   environment={"VAULT_DEV_ROOT_TOKEN_ID": self.root_token},
                   tmpfs=[("/tmp", "64m"), ("/vault/file", "32m"), ("/vault/logs", "32m")])
        wait_for(lambda: self.vault("sys/health").get("sealed") is False)
        reviewer = self.kubectl(["create", "token", "vault-reviewer", "-n", self.namespace, "--duration=1h"]).stdout.decode().strip()
        self.vault("sys/auth/kubernetes", {"type": "kubernetes"})
        self.vault("auth/kubernetes/config", {
            "kubernetes_host": f"https://{self.ips['api']}:6443", "kubernetes_ca_cert": self.ca.read_text(),
            "token_reviewer_jwt": reviewer})
        self.vault("sys/policies/acl/fixture", {"policy": 'path "secret/data/fixture/allowed" { capabilities = ["read"] }'})
        self.vault("auth/kubernetes/role/fixture", {"bound_service_account_names": ["eso-auth"],
                   "bound_service_account_namespaces": [self.namespace], "audience": "vault",
                   "token_policies": ["fixture"], "token_ttl": 300, "token_max_ttl": 600})
        self.checks.append("Disposable Kubernetes API and Vault Kubernetes authentication configured")

    def start_operator(self):
        mounts = [(self.directory / "client", "/fixture-client")]
        environment = {"KUBECONFIG": "/fixture-client/config"}
        self.controller = self.start("controller", self.args.image_id, "/bin/external-secrets",
                                     ["--metrics-addr=0", "--live-addr=:8082", "--store-requeue-interval=5s"],
                                     "512m", mounts=mounts, environment=environment, tmpfs=[("/tmp", "32m")])
        self.webhook = self.start("webhook", self.args.image_id, "/bin/external-secrets",
                                  ["webhook", "--port=9443", "--dns-name=webhook", "--cert-dir=/fixture-certs",
                                   "--metrics-addr=0", "--healthz-addr=:8081", "--lookahead-interval=1h"],
                                  "256m", mounts=[*mounts, (self.directory / "webhook", "/fixture-certs")],
                                  environment=environment, tmpfs=[("/tmp", "32m")])
        self.wait_webhook()
        webhooks = []
        for resource, kind, scope in (("secretstores", "secretstore", "Namespaced"),
                                     ("clustersecretstores", "clustersecretstore", "Cluster"),
                                     ("externalsecrets", "externalsecret", "Namespaced")):
            webhooks.append({"name": f"validate.{kind}.external-secrets.io",
                             "clientConfig": {"url": f"https://{self.ips['webhook']}:9443/validate-external-secrets-io-v1-{kind}",
                                              "caBundle": encoded(self.ca.read_bytes())},
                             "rules": [{"apiGroups": ["external-secrets.io"], "apiVersions": ["v1"],
                                        "operations": ["CREATE", "UPDATE", "DELETE"], "resources": [resource], "scope": scope}],
                             "admissionReviewVersions": ["v1"], "sideEffects": "None", "failurePolicy": "Fail", "timeoutSeconds": 5})
        self.apply({"apiVersion": "admissionregistration.k8s.io/v1", "kind": "ValidatingWebhookConfiguration",
                    "metadata": {"name": "fixture-eso-validation"}, "webhooks": webhooks})

    def wait_webhook(self):
        context = ssl.create_default_context(cafile=str(self.ca))
        expected_certificate = ssl.PEM_cert_to_DER_cert((self.directory / "webhook/tls.crt").read_text())
        def ready():
            with self.opener.open(f"http://{self.ips['webhook']}:8081/readyz", timeout=5) as response:
                if response.status != 200:
                    return False
            # ESO /readyz validates files, not the listener. Complete a verified
            # TLS handshake and require the current certificate before admission.
            with socket.create_connection((self.ips["webhook"], 9443), timeout=5) as connection:
                with context.wrap_socket(connection, server_hostname=self.ips["webhook"]) as tls:
                    return tls.getpeercert(binary_form=True) == expected_certificate
        wait_for(ready)

    def store(self, name="vault", cluster=False):
        service_account = {"name": "eso-auth", "audiences": ["vault"]}
        metadata = {"name": name}
        if cluster:
            service_account["namespace"] = self.namespace
        else:
            metadata["namespace"] = self.namespace
        return {"apiVersion": "external-secrets.io/v1", "kind": "ClusterSecretStore" if cluster else "SecretStore",
                "metadata": metadata, "spec": {"provider": {"vault": {"server": f"http://{self.ips['vault']}:8200",
                "path": "secret", "version": "v2", "auth": {"kubernetes": {"mountPath": "kubernetes",
                "role": "fixture", "serviceAccountRef": service_account}}}}}}

    def external_secret(self, name, key="fixture/allowed", cluster=False):
        return {"apiVersion": "external-secrets.io/v1", "kind": "ExternalSecret",
                "metadata": {"name": name, "namespace": self.namespace}, "spec": {
                    "refreshInterval": "2s", "secretStoreRef": {"name": "cluster-vault" if cluster else "vault",
                    "kind": "ClusterSecretStore" if cluster else "SecretStore"},
                    "target": {"name": name, "creationPolicy": "Owner"},
                    "data": [{"secretKey": "value", "remoteRef": {"key": key, "property": "value"}}]}}

    def rejection_checks(self):
        invalid = self.store("invalid-namespace")
        invalid["spec"]["provider"]["vault"]["auth"]["kubernetes"]["serviceAccountRef"]["namespace"] = "unrelated-namespace"
        invalid_es = self.external_secret("invalid-policy")
        invalid_es["spec"]["target"].update({"creationPolicy": "Merge", "deletionPolicy": "Delete"})
        for obj, webhook_name in ((invalid, "validate.secretstore.external-secrets.io"),
                                  (invalid_es, "validate.externalsecret.external-secrets.io")):
            result = self.kubectl(["create", "-f", "-"], obj, check=False)
            message = result.stderr.decode()
            if result.returncode == 0 or webhook_name not in message or "denied the request" not in message:
                (self.args.logs / "unexpected-admission.txt").write_bytes(result.stderr)
                raise AssertionError("Invalid resource was not rejected by the candidate admission webhook")

    def exercise(self):
        first, second, third = (secrets.token_urlsafe(24) for _ in range(3))
        self.vault("secret/data/fixture/allowed", {"data": {"value": first}})
        self.vault("secret/data/fixture/denied", {"data": {"value": secrets.token_urlsafe(24)}})
        self.apply(self.store())
        self.apply(self.store("cluster-vault", cluster=True))
        wait_for(lambda: self.ready("secretstore", "vault"))
        wait_for(lambda: self.ready("clustersecretstore", "cluster-vault", namespaced=False))
        self.rejection_checks()
        self.checks.append("Candidate admission rejects cross-namespace credentials and invalid deletion policies")
        for name, cluster in (("namespaced-value", False), ("cluster-value", True)):
            self.apply(self.external_secret(name, cluster=cluster))
            wait_for(lambda name=name: self.value_matches(name, first))
        self.checks.append("Namespaced and cluster-scoped Vault stores reconcile actual KV values")
        self.vault("secret/data/fixture/allowed", {"data": {"value": second}})
        for name in ("namespaced-value", "cluster-value"):
            wait_for(lambda name=name: self.value_matches(name, second))
        self.checks.append("KV rotation updates both destination Secrets")
        self.apply(self.external_secret("denied-value", key="fixture/denied"))
        wait_for(lambda: self.ready("externalsecret", "denied-value", expected=False))
        denied = self.kubectl(["get", "secret", "denied-value", "-n", self.namespace], check=False)
        if denied.returncode == 0 or b"NotFound" not in denied.stderr:
            raise AssertionError("Unauthorized Vault path created a destination Secret")
        self.checks.append("Vault ACL rejects unauthorized paths without creating a Secret")
        token = self.kubectl(["create", "token", "eso-auth", "-n", self.namespace,
                              "--duration=10m", "--audience=vault"]).stdout.decode().strip()
        header, claims, signature = token.split(".")
        forged = ".".join((header, claims, ("a" if signature[0] != "a" else "b") + signature[1:]))
        try:
            self.http(f"http://{self.ips['vault']}:8200/v1/auth/kubernetes/login",
                      {"role": "fixture", "jwt": forged})
        except urllib.error.HTTPError as error:
            if error.code not in (400, 403):
                raise AssertionError("Forged token failed for an unexpected reason") from error
        else:
            raise AssertionError("Vault accepted a token with a forged signature")
        self.checks.append("Vault Kubernetes authentication rejects a forged JWT signature")
        bad_store = self.store()
        bad_store["spec"]["provider"]["vault"]["auth"]["kubernetes"]["serviceAccountRef"]["name"] = "unbound-auth"
        self.apply(bad_store)
        wait_for(lambda: self.ready("secretstore", "vault", expected=False))
        self.apply(self.store())
        wait_for(lambda: self.ready("secretstore", "vault"))
        self.checks.append("Unbound service-account identity is rejected and valid authentication recovers")
        run(["docker", "restart", "--time=20", self.controller])
        run(["docker", "stop", "--time=20", self.webhook])
        previous_certificate = (self.directory / "webhook/tls.crt").read_bytes()
        self.rotate_webhook_certificate()
        if (self.directory / "webhook/tls.crt").read_bytes() == previous_certificate:
            raise AssertionError("Webhook certificate did not rotate")
        run(["docker", "start", self.webhook])
        self.wait_webhook()
        self.rejection_checks()
        self.apply(self.store("post-restart-valid"))
        self.vault("secret/data/fixture/allowed", {"data": {"value": third}})
        for name in ("namespaced-value", "cluster-value"):
            wait_for(lambda name=name: self.value_matches(name, third))
        self.checks.append("Controller restart and webhook certificate replacement preserve admission and reconciliation")
        for component in ("controller", "webhook"):
            inspect = json.loads(run(["docker", "inspect", self.prefix + "-" + component]).stdout)[0]
            if not inspect["State"]["Running"] or inspect["State"].get("OOMKilled"):
                raise AssertionError("Candidate process is not healthy")

    def cleanup(self):
        errors = []
        for name in reversed(self.containers):
            try:
                logs = run(["docker", "logs", name], check=False, timeout=30)
                body = (logs.stdout + logs.stderr).replace(self.root_token.encode(), b"[fixture token redacted]")
                (self.args.logs / (name + ".log")).write_bytes(body)
            except (OSError, subprocess.TimeoutExpired):
                # Logging failure must never skip container removal.
                pass
            try:
                # Remove inherited image-declared anonymous volumes as well.
                removal = run(["docker", "rm", "-f", "-v", name], check=False, timeout=30)
                if removal.returncode and b"No such container" not in removal.stderr:
                    errors.append(name)
            except (OSError, subprocess.TimeoutExpired):
                errors.append(name)
        if self.network:
            try:
                removal = run(["docker", "network", "rm", self.network], check=False, timeout=30)
                if removal.returncode and b"not found" not in removal.stderr.lower():
                    errors.append(self.network)
            except (OSError, subprocess.TimeoutExpired):
                errors.append(self.network)
        self.tmp.cleanup()
        return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", help="Already-built candidate image; resolved to its immutable local ID")
    parser.add_argument("--vault-image", required=True, help="Already-cached Vault image for synthetic dev-mode data")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True, help="Verified Kubernetes 1.36 envtest binary directory")
    parser.add_argument("--asset-checksums", type=Path, required=True, help="JSON with trusted SHA-256 values for kube-apiserver and etcd")
    parser.add_argument("--kubectl", type=Path, default=Path(shutil.which("kubectl") or "kubectl"))
    parser.add_argument("--logs", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    args.logs = args.logs.resolve()
    workspace = Path(__file__).resolve().parents[2]
    if args.logs == workspace or workspace in args.logs.parents:
        parser.error("Private logs must be outside the workspace")
    args.logs.mkdir(parents=True, exist_ok=False)
    args.source, args.assets = args.source.resolve(), args.assets.resolve()
    if run(["git", "-C", str(args.source), "rev-parse", "HEAD"]).stdout.decode().strip() != SOURCE_COMMIT:
        parser.error("Unexpected ESO source commit")
    expected = json.loads(args.asset_checksums.read_text())
    for name in ("kube-apiserver", "etcd"):
        binary = args.assets / name
        if not os.access(binary, os.X_OK) or hashlib.sha256(binary.read_bytes()).hexdigest() != expected[name]:
            parser.error("An envtest binary failed its checksum or executable check")
    args.image_id = json.loads(run(["docker", "image", "inspect", args.image]).stdout)[0]["Id"]
    args.vault_image_id = json.loads(run(["docker", "image", "inspect", args.vault_image]).stdout)[0]["Id"]
    for name in ("KUBECONFIG", "KUBERNETES_SERVICE_HOST", "KUBERNETES_SERVICE_PORT"):
        os.environ.pop(name, None)
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        os.environ.pop(name, None)
    os.environ.update({"NO_PROXY": "*", "no_proxy": "*"})
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt("Canary interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    fixture = Canary(args)
    result = {"image": args.image, "imageID": args.image_id, "vaultImageID": args.vault_image_id,
              "sourceCommit": SOURCE_COMMIT, "assetChecksums": expected, "status": "failed"}
    failed = None
    try:
        fixture.prepare()
        fixture.infrastructure()
        fixture.start_operator()
        fixture.exercise()
        result.update({"status": "passed", "kubernetesVersion": fixture.api_version})
    except BaseException as error:
        failed = error
        (args.logs / "failure.txt").write_text(f"{type(error).__name__}: {error}\n")
    finally:
        # A second interrupt must not abandon fixture containers during cleanup.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        cleanup_errors = fixture.cleanup()
        result.update({"checks": fixture.checks, "cleanupErrors": cleanup_errors})
        if cleanup_errors:
            result["status"] = "failed"
        (args.logs / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    if failed or cleanup_errors:
        raise SystemExit("ESO image canary failed; inspect the private log directory")
    print("ESO image passed Vault authentication, reconciliation, rotation, admission and restart checks")


if __name__ == "__main__":
    main()
