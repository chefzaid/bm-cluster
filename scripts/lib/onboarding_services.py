"""Bounded platform primitives for app-owned declarative onboarding contracts.

No application code is executed. Public outcomes never contain credentials.
"""

import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import subprocess
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlparse
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


class ServiceError(RuntimeError):
    """An operator-facing failure that does not expose request/response secrets."""


class HTTPFailure(ServiceError):
    def __init__(self, status, cas=False):
        super().__init__(f"Service request failed with HTTP {status}")
        self.status, self.cas = status, cas


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


class HTTP:
    def __init__(self, base, headers=None):
        self.base, self.headers = base.rstrip("/"), headers or {}
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def request(self, method, path, data=None, *, missing=False, form=False, raw=False):
        headers = dict(self.headers)
        body = None
        if data is not None:
            body = (urlencode(data) if form else json.dumps(data)).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
        try:
            request = Request(self.base + path, data=body, headers=headers, method=method)
            with self.opener.open(request, timeout=30) as response:
                content = response.read(4 * 1024 * 1024 + 1)
                if len(content) > 4 * 1024 * 1024:
                    raise ServiceError("Service response exceeded the onboarding size limit")
                return content if raw else json.loads(content) if content else None
        except HTTPError as error:
            status = error.code
            # Inspect only the known Vault CAS marker; never expose error bodies.
            detail = error.read(16384)
            error.close()
            if missing and status == 404:
                return None
            raise HTTPFailure(status, status == 400 and b"check-and-set parameter did not match" in detail) from None
        except (URLError, TimeoutError, OSError, ValueError):
            raise ServiceError("Service request failed; check connectivity, credentials and response format") from None


@contextmanager
def forward(resource, port):
    process = subprocess.Popen([
        "kubectl", "--request-timeout=15s", "-n", "infra", "port-forward",
        "--address=127.0.0.1", resource, f":{port}",
    ], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 30
            while process.poll() is None and time.monotonic() < deadline:
                if not selector.select(timeout=1):
                    continue
                match = re.search(r"Forwarding from 127\.0\.0\.1:(\d+) ->", process.stdout.readline())
                if match:
                    yield "http://127.0.0.1:" + match[1]
                    return
        raise ServiceError("A private service port-forward could not become ready")
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdout.close()


def public_host(value):
    return isinstance(value, str) and len(value) <= 253 and re.fullmatch(
        r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}", value) is not None


def private_token_file(path):
    try:
        if os.geteuid() == 0:
            value = Path(path).read_text()
        else:
            value = subprocess.run(["sudo", "-n", "cat", "--", str(path)], check=True,
                                   capture_output=True, text=True, timeout=15).stdout
        value = value.strip()
        if not value or any(character.isspace() for character in value):
            raise ValueError()
        return value
    except (OSError, ValueError, subprocess.SubprocessError):
        raise ServiceError("The existing private Vault bootstrap token could not be read") from None


class Services:
    def __init__(self, gitlab, kubectl, context, secret_inputs=None):
        self.gitlab, self.kubectl, self.context = gitlab, kubectl, dict(context)
        self.secret_inputs = dict(secret_inputs or {})
        self.app = str(context["APPLICATION_NAME"])
        self.project = str(context["GITLAB_PROJECT_ID"])
        self.project_path = str(context["GITLAB_PROJECT_PATH"])
        self.owner = f"bm-cluster-onboarding:{self.project}"
        self.registry_name = "onboarding-" + hashlib.sha256(self.project_path.encode()).hexdigest()[:16]

    def _path(self, value):
        prefix = "apps/" + self.app + "/"
        if (not isinstance(value, str) or not value.startswith(prefix)
                or not re.fullmatch(r"[A-Za-z0-9_./-]+", value)
                or any(part in ("", ".", "..") for part in value.split("/"))):
            raise ServiceError("Vault paths must remain within this application's apps/ prefix")
        return value

    @contextmanager
    def _vault(self):
        helper = Path(__file__).with_name("vault-access.sh")
        try:
            result = subprocess.run(["bash", "-c", 'source "$1"; vault_runtime_pod infra',
                                     "onboarding", str(helper)], check=True, capture_output=True,
                                    text=True, timeout=45)
            pod = result.stdout.strip()
            if not re.fullmatch(r"vault-[0-9]+", pod):
                raise ValueError()
        except (OSError, ValueError, subprocess.SubprocessError):
            raise ServiceError("No initialized and unsealed Vault peer is available") from None
        token = private_token_file(os.environ.get("VAULT_BOOTSTRAP_TOKEN_FILE", "/var/lib/bm-cluster/vault-bootstrap-token"))
        with forward("pod/" + pod, 8200) as origin:
            api = HTTP(origin, {"X-Vault-Token": token})
            health = api.request("GET", "/v1/sys/health?standbyok=true&perfstandbyok=true")
            if not health.get("initialized") or health.get("sealed"):
                raise ServiceError("Vault is not initialized and unsealed")
            mounts = api.request("GET", "/v1/sys/mounts")
            mount = mounts.get("data", {}).get("secret/", {})
            if mount.get("type") != "kv" or mount.get("options", {}).get("version") != "2":
                raise ServiceError("The platform secret/ mount must use Vault KV version 2")
            yield api

    @contextmanager
    def _keycloak(self):
        secret = self.kubectl("get", "secret", "keycloak-admin-secret", "-n", "infra", "-o", "json", "--request-timeout=15s")
        try:
            values = {key: base64.b64decode(secret["data"][key], validate=True).decode()
                      for key in ("KC_BOOTSTRAP_ADMIN_USERNAME", "KC_BOOTSTRAP_ADMIN_PASSWORD")}
            if not all(values.values()):
                raise ValueError()
        except (KeyError, TypeError, ValueError):
            raise ServiceError("Keycloak administrator credentials are missing or malformed") from None
        with forward("service/keycloak", 8080) as origin:
            api = HTTP(origin + "/auth")
            token = api.request("POST", "/realms/master/protocol/openid-connect/token", {
                "client_id": "admin-cli", "grant_type": "password",
                "username": values["KC_BOOTSTRAP_ADMIN_USERNAME"], "password": values["KC_BOOTSTRAP_ADMIN_PASSWORD"],
            }, form=True)
            if not isinstance(token, dict) or not token.get("access_token"):
                raise ServiceError("Keycloak did not issue an administrator access token")
            api.headers["Authorization"] = "Bearer " + token["access_token"]
            yield api

    def _cf(self):
        token = self.secret_inputs.get("CLOUDFLARE_API_TOKEN") or os.environ.get("CLOUDFLARE_API_TOKEN")
        if not isinstance(token, str) or not token or any(character.isspace() for character in token):
            raise ServiceError("CLOUDFLARE_API_TOKEN is required for application DNS")
        return HTTP("https://api.cloudflare.com/client/v4", {"Authorization": "Bearer " + token})

    @staticmethod
    def _cf_call(api, method, path, data=None):
        value = api.request(method, path, data)
        if not isinstance(value, dict) or value.get("success") is not True:
            raise ServiceError("Cloudflare rejected the operation; check permissions and record ownership")
        return value.get("result")

    @staticmethod
    def _kv_get(api, path):
        encoded = quote(path, safe="/")
        value = api.request("GET", "/v1/secret/data/" + encoded, missing=True)
        if value is None:
            metadata = api.request("GET", "/v1/secret/metadata/" + encoded, missing=True)
            if metadata and metadata.get("data", {}).get("current_version", 0):
                raise ServiceError("A deleted Vault value requires explicit recovery before onboarding")
            return {}, 0
        try:
            data, metadata = value["data"]["data"], value["data"]["metadata"]
            version = metadata["version"]
            if not isinstance(data, dict) or not isinstance(version, int) or version < 1:
                raise ValueError()
            if metadata.get("destroyed") or metadata.get("deletion_time"):
                raise ValueError()
            return data, version
        except (KeyError, TypeError, ValueError):
            raise ServiceError("Vault returned an unavailable or malformed KV-v2 value") from None

    @staticmethod
    def _kv_write(api, path, data, version):
        api.request("POST", "/v1/secret/data/" + quote(path, safe="/"),
                    {"data": data, "options": {"cas": version}})
        actual, observed_version = Services._kv_get(api, path)
        if observed_version <= version or any(actual.get(key) != value for key, value in data.items()):
            raise ServiceError("Vault credential publication did not converge")

    def _fields(self, declarations, existing, generate=False):
        values = dict(existing)
        for name, source in declarations.items():
            present = name in values and values[name] not in (None, "")
            if "input" in source:
                supplied = self.secret_inputs.get(source["input"])
                if supplied not in (None, "") and not isinstance(supplied, str):
                    raise ServiceError("Secret inputs must be nonempty strings")
                if present:
                    if supplied not in (None, "", values[name]):
                        raise ServiceError("An existing secret differs from the supplied input; rotate it explicitly")
                    continue
                if not supplied:
                    raise ServiceError("Missing secret input: " + source["input"])
                values[name] = supplied
            elif "value" in source:
                # Literals are seed defaults, including empty optional fields.
                # Existing operator configuration always wins on a rerun.
                if not present:
                    values[name] = source["value"]
            elif not present and generate:
                data = secrets.token_bytes(source["generate"])
                values[name] = data.hex() if source.get("encoding", "hex") == "hex" else base64.b64encode(data).decode()
        return values

    def _fill_vault(self, api, path, fields):
        for _ in range(3):
            old, version = self._kv_get(api, path)
            desired = self._fields(fields, old, generate=True)
            if old == desired:
                return "retained"
            try:
                self._kv_write(api, path, desired, version)
                return "filled"
            except HTTPFailure as error:
                if not error.cas:
                    raise
        raise ServiceError("Concurrent Vault updates prevented onboarding; rerun with the same inputs")

    def _tokens(self):
        values = []
        for page in range(1, 101):
            batch = self.gitlab.call("GET", f"projects/{self.project}/deploy_tokens?per_page=100&page={page}")
            if not isinstance(batch, list):
                raise ServiceError("GitLab returned malformed deployment token metadata")
            values.extend(batch)
            if len(batch) < 100:
                return values
        raise ServiceError("GitLab deployment token inventory exceeded the onboarding limit")

    def _registry_valid(self, stored, tokens):
        if not all(isinstance(stored.get(key), str) and stored[key] for key in ("username", "password")):
            return False
        matching = [token for token in tokens if token.get("username") == stored["username"]]
        if len(matching) != 1:
            return False
        token = matching[0]
        if token.get("revoked") or token.get("expired") or not {"read_repository", "read_registry"} <= set(token.get("scopes", [])):
            return False
        if token.get("expires_at"):
            try:
                expiry = datetime.fromisoformat(token["expires_at"].replace("Z", "+00:00"))
                if expiry.tzinfo is None:
                    expiry = expiry.replace(tzinfo=timezone.utc)
                if expiry <= datetime.now(timezone.utc):
                    return False
            except (TypeError, ValueError):
                raise ServiceError("GitLab returned an invalid deployment token expiry") from None
        auth = base64.b64encode((stored["username"] + ":" + stored["password"]).encode()).decode()
        control = getattr(self.gitlab, "url", "")
        origin = control.removesuffix("/api/v4") if isinstance(control, str) and control.endswith("/api/v4") else self.context["GITLAB_INTERNAL_URL"]
        api = HTTP(origin, {"Authorization": "Basic " + auth})
        try:
            # Public Git reads can succeed without usable credentials. Require
            # an authenticated Registry login as well as the declared scopes.
            ticket = api.request("GET", "/jwt/auth?service=container_registry")
            if not isinstance(ticket, dict) or not isinstance(ticket.get("token"), str) or not ticket["token"]:
                raise ServiceError("GitLab did not issue a Registry authentication token")
            data = api.request("GET", "/" + quote(self.project_path, safe="/") +
                               ".git/info/refs?service=git-upload-pack", raw=True)
            return bool(data and b"git-upload-pack" in data[:200])
        except HTTPFailure as error:
            if error.status == 401:
                return False
            # A 403 may be an IP abuse-protection block; do not churn tokens.
            raise

    def _registry(self, api, path):
        for _ in range(3):
            stored, version = self._kv_get(api, path)
            if self._registry_valid(stored, self._tokens()):
                if stored.get("registry") != self.context["REGISTRY_HOST"]:
                    try:
                        self._kv_write(api, path, {**stored, "registry": self.context["REGISTRY_HOST"]}, version)
                    except HTTPFailure as error:
                        if error.cas:
                            continue
                        raise
                return "retained"
            token = self.gitlab.call("POST", f"projects/{self.project}/deploy_tokens", {
                "name": self.registry_name, "scopes": ["read_repository", "read_registry"],
            })
            if not isinstance(token, dict) or not all(token.get(key) for key in ("id", "username", "token")):
                raise ServiceError("GitLab did not return usable project deployment credentials")
            candidate = {**stored, "registry": self.context["REGISTRY_HOST"],
                         "username": token["username"], "password": token["token"], "token_id": str(token["id"])}
            retain_token, write_started = False, False
            try:
                if not self._registry_valid(candidate, self._tokens()):
                    raise ServiceError("New project deployment credentials failed verification")
                write_started = True
                self._kv_write(api, path, candidate, version)
                retain_token = True
                # Old active tokens are retained until projected consumers refresh.
                return "replaced; previous credentials retained for safe consumer refresh"
            except HTTPFailure as error:
                if not error.cas:
                    # A 5xx after POST can occur after the server committed the
                    # value. Never revoke a credential that may now be in use.
                    retain_token = write_started and error.status >= 500
                    raise
            except ServiceError:
                # Lost POST responses/readback failures are ambiguous. A rerun
                # reads the published value; an unused token is safer than
                # revoking a credential already projected into running pods.
                retain_token = write_started
                raise
            finally:
                if not retain_token:
                    self.gitlab.call("DELETE", f"projects/{self.project}/deploy_tokens/{token['id']}")
        raise ServiceError("Concurrent registry credential updates prevented onboarding; rerun")

    def _client(self, contract, checkout):
        specification = contract.get("keycloak")
        if not specification:
            return None
        realm = specification.get("realm", self.context.get("KEYCLOAK_REALM"))
        if not isinstance(realm, str) or realm == "master" or not re.fullmatch(r"[A-Za-z0-9_.-]+", realm):
            raise ServiceError("An existing application Keycloak realm is required")
        root = Path(checkout).resolve()
        relative = Path(specification.get("file", ""))
        path = root / relative
        if relative.is_absolute() or not relative.parts or ".." in relative.parts or not path.is_file():
            raise ServiceError("The Keycloak client file must be a regular file within the checkout")
        if not path.resolve().is_relative_to(root) or any(item.is_symlink() for item in [path, *path.parents] if item != root):
            raise ServiceError("The Keycloak client file cannot traverse symlinks")
        try:
            if path.stat().st_size > 1024 * 1024:
                raise ValueError()
            desired = json.loads(path.read_text())
            if not isinstance(desired, dict) or not re.fullmatch(r"[A-Za-z0-9_.-]+", desired.get("clientId", "")):
                raise ValueError()
            if (desired.get("publicClient") is not True or desired.get("protocol") != "openid-connect"
                    or desired.get("attributes", {}).get("pkce.code.challenge.method") != "S256"
                    or desired.get("implicitFlowEnabled", False) or desired.get("directAccessGrantsEnabled", False)
                    or desired.get("serviceAccountsEnabled", False) or "secret" in desired
                    or desired.get("authorizationServicesEnabled", False)):
                raise ValueError()
            allowed_fields = {"clientId", "name", "enabled", "protocol", "publicClient", "standardFlowEnabled",
                              "implicitFlowEnabled", "directAccessGrantsEnabled", "serviceAccountsEnabled",
                              "rootUrl", "baseUrl", "redirectUris", "webOrigins", "attributes",
                              "defaultClientScopes", "optionalClientScopes", "protocolMappers"}
            if set(desired) - allowed_fields or not desired.get("enabled", True) or not desired.get("standardFlowEnabled", True):
                raise ValueError()
            if set(desired["attributes"]) - {"pkce.code.challenge.method", "post.logout.redirect.uris"}:
                raise ValueError()
            hosts = set(contract.get("dns", {}).get("hosts", [])) | {self.context["APP_HOST"]}
            logout = desired["attributes"].get("post.logout.redirect.uris", "+")
            if logout != "+":
                for url in logout.split("##"):
                    parsed = urlparse(url)
                    if parsed.scheme != "https" or parsed.hostname not in hosts or parsed.username or parsed.password:
                        raise ValueError()
            for mapper in desired.get("protocolMappers", []):
                if not isinstance(mapper, dict) or mapper.get("protocol") != "openid-connect" or not mapper.get("name"):
                    raise ValueError()
                kind, settings = mapper.get("protocolMapper"), mapper.get("config", {})
                if kind == "oidc-audience-mapper":
                    if settings.get("included.client.audience") != desired["clientId"] or settings.get("included.custom.audience"):
                        raise ValueError()
                elif kind != "oidc-group-membership-mapper":
                    raise ValueError()
            for key in ("rootUrl", "baseUrl", "redirectUris", "webOrigins"):
                urls = desired.get(key, [])
                if isinstance(urls, str):
                    urls = [urls]
                for url in urls:
                    parsed = urlparse(url)
                    if parsed.scheme != "https" or parsed.hostname not in hosts or parsed.username or parsed.password or parsed.port not in (None, 443):
                        raise ValueError()
            if not desired.get("redirectUris"):
                raise ValueError()
            for mode in ("defaultClientScopes", "optionalClientScopes"):
                if not isinstance(desired.get(mode, []), list) or not all(isinstance(x, str) and x for x in desired.get(mode, [])):
                    raise ValueError()
        except (OSError, ValueError, TypeError, AttributeError):
            raise ServiceError("The production Keycloak file must define a public PKCE client limited to this application's HTTPS hosts") from None
        desired = {**desired, "enabled": True, "standardFlowEnabled": True,
                   "implicitFlowEnabled": False, "directAccessGrantsEnabled": False,
                   "serviceAccountsEnabled": False, "attributes": {**desired["attributes"], "bm-cluster.onboarding.project": self.project_path}}
        return realm, desired

    def _identity_state(self, api, client):
        realm, desired = client
        base = "/admin/realms/" + quote(realm, safe="")
        api.request("GET", base)
        scopes = {item["name"]: item["id"] for item in api.request("GET", base + "/client-scopes")}
        defaults, optional = set(desired.get("defaultClientScopes", [])), set(desired.get("optionalClientScopes", []))
        if defaults & optional or (defaults | optional) - set(scopes):
            raise ServiceError("The declared Keycloak scopes are missing or assigned in both modes")
        matching = [item for item in api.request("GET", base + "/clients?" + urlencode({"clientId": desired["clientId"]}))
                    if item.get("clientId") == desired["clientId"]]
        if len(matching) > 1:
            raise ServiceError("The Keycloak client identity is ambiguous")
        if matching:
            existing = api.request("GET", base + "/clients/" + quote(matching[0]["id"], safe=""))
            owner = existing.get("attributes", {}).get("bm-cluster.onboarding.project")
            if owner and owner != self.project_path:
                raise ServiceError("The Keycloak client belongs to another project")
            if not owner:
                allowed = {self.context["APP_HOST"], *self.context.get("PREVIOUS_HOSTS", [])}
                previous_urls = [existing.get("rootUrl", ""), *existing.get("redirectUris", [])]
                previous_hosts = {urlparse(url).hostname for url in previous_urls if url}
                if not previous_hosts or not previous_hosts <= allowed or existing.get("publicClient") is not True:
                    raise ServiceError("An existing Keycloak client has no matching application ownership")
        return base, scopes, matching

    def _identity(self, api, client):
        base, scopes, matching = self._identity_state(api, client)
        desired = client[1]
        if not matching:
            api.request("POST", base + "/clients", desired)
            _, _, matching = self._identity_state(api, client)
        if len(matching) != 1:
            raise ServiceError("Keycloak client creation did not converge")
        path = base + "/clients/" + quote(matching[0]["id"], safe="")
        api.request("PUT", path, {**{key: value for key, value in desired.items()
                                    if key not in ("protocolMappers", "defaultClientScopes", "optionalClientScopes")}, "id": matching[0]["id"]})
        wanted = {"default": set(desired.get("defaultClientScopes", [])), "optional": set(desired.get("optionalClientScopes", []))}
        def assignments(mode):
            return {item["name"]: item["id"] for item in api.request("GET", path + f"/{mode}-client-scopes")}
        current = {mode: assignments(mode) for mode in wanted}
        for mode, other in (("default", "optional"), ("optional", "default")):
            removed = set(current[mode]) & wanted[other]
            if mode == "default" and "roles" not in wanted[mode]:
                removed |= set(current[mode]) & {"roles"}
            for name in sorted(removed):
                api.request("DELETE", path + f"/{mode}-client-scopes/" + quote(current[mode][name], safe=""))
        for mode in wanted:
            for name in sorted(wanted[mode] - set(current[mode])):
                api.request("PUT", path + f"/{mode}-client-scopes/" + quote(scopes[name], safe=""))
        actual = {mode: set(assignments(mode)) for mode in wanted}
        if (any(not wanted[mode] <= actual[mode] for mode in wanted)
                or wanted["default"] & actual["optional"] or wanted["optional"] & actual["default"]
                or ("roles" not in wanted["default"] and "roles" in actual["default"])):
            raise ServiceError("Keycloak scope assignments did not converge")
        mapper_path = path + "/protocol-mappers/models"
        existing = api.request("GET", mapper_path)
        for mapper in desired.get("protocolMappers", []):
            same = [item for item in existing if item.get("name") == mapper.get("name")]
            if len(same) > 1:
                raise ServiceError("A managed Keycloak mapper is ambiguous")
            if same:
                mapper_id = same[0]["id"]
                api.request("PUT", mapper_path + "/" + quote(mapper_id, safe=""), {**mapper, "id": mapper_id})
            else:
                api.request("POST", mapper_path, mapper)
        return "reconciled existing client identity"

    def _dns_target(self):
        state = self.kubectl("get", "configmap", "bm-cluster-public-ingress", "-n", "infra", "--ignore-not-found", "-o", "json", "--request-timeout=15s")
        if state:
            values = state.get("data", {})
            if values.get("mode") == "tunnel":
                tunnel = values.get("tunnelID", "")
                if (not re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", tunnel)
                        or values.get("domain") != self.context["PUBLIC_DOMAIN"] or values.get("publishedTunnelID") != tunnel):
                    raise ServiceError("The HA Tunnel has not been published for the selected zone")
                return "CNAME", tunnel + ".cfargotunnel.com"
            if values.get("mode") != "direct":
                raise ServiceError("Unknown platform public ingress mode")
        service = self.kubectl("get", "service", "ingress-nginx-controller", "-n", "infra", "-o", "json", "--request-timeout=15s")
        addresses = service.get("status", {}).get("loadBalancer", {}).get("ingress", [])
        public = []
        for address in addresses:
            try:
                ip = ipaddress.ip_address(address.get("ip", ""))
                if ip.version == 4 and ip.is_global:
                    public.append(str(ip))
            except ValueError:
                continue
        if len(set(public)) != 1:
            raise ServiceError("A unique public IPv4 ingress target is required before DNS publication")
        return "A", public[0]

    def _hosts(self, contract):
        hosts = contract.get("dns", {}).get("hosts", [])
        zone = self.context["PUBLIC_DOMAIN"]
        if (not isinstance(hosts, list) or len(hosts) > 100 or not all(isinstance(host, str) for host in hosts)
                or len(hosts) != len(set(hosts)) or not public_host(zone) or any(
                    not public_host(host) or not (host == zone or host.endswith("." + zone)) for host in hosts)):
            raise ServiceError("DNS hosts must be unique explicit names inside the selected public zone")
        return hosts

    def _dns_read(self, contract):
        hosts = self._hosts(contract)
        if not hosts:
            return None
        zone = self.context["PUBLIC_DOMAIN"]
        target = self._dns_target()
        owned = set()
        for ingress in self.kubectl("get", "ingresses", "--all-namespaces", "-o", "json", "--request-timeout=15s").get("items", []):
            matched = {rule.get("host") for rule in ingress.get("spec", {}).get("rules", [])} & set(hosts)
            if not matched:
                continue
            metadata = ingress.get("metadata", {})
            owner = metadata.get("annotations", {}).get("argocd.argoproj.io/tracking-id", "").split(":")[0]
            owner = owner or metadata.get("labels", {}).get("argocd.argoproj.io/instance") or metadata.get("labels", {}).get("app.kubernetes.io/instance")
            if metadata.get("namespace") != "apps" or owner != self.app:
                raise ServiceError("A requested DNS hostname is routed by a different or unowned Ingress")
            owned |= matched
        api = self._cf()
        zones = self._cf_call(api, "GET", "/zones?" + urlencode({"name": zone, "per_page": 100}))
        if not isinstance(zones, list) or len(zones) != 1 or zones[0].get("name") != zone:
            raise ServiceError("Cloudflare did not return exactly the selected DNS zone")
        base = "/zones/" + quote(zones[0]["id"], safe="") + "/dns_records"
        records = {}
        for host in hosts:
            values = self._cf_call(api, "GET", base + "?" + urlencode({"name": host, "per_page": 100}))
            address = [item for item in values if item.get("type") in ("A", "AAAA", "CNAME")]
            if len(address) > 1:
                raise ServiceError("A requested hostname has conflicting DNS address records")
            existing = address[0] if address else None
            if existing:
                managed = existing.get("comment", "")
                allowed_comment = managed == self.owner or (host in owned and (
                    managed == "Managed by bm-cluster/scripts/configure-cloudflare.sh"
                    or managed.startswith("Managed by " + self.app + "/")))
                if (existing.get("type"), existing.get("content", "").rstrip(".")) != target and not allowed_comment:
                    raise ServiceError("An existing DNS record targets another origin; explicit ownership recovery is required")
            records[host] = existing
        return api, base, target, records

    def _validate(self, contract, checkout):
        paths = []
        if contract.get("registry"):
            paths.append(self._path(contract["registry"]["path"]))
        for item in contract.get("vault", []):
            paths.append(self._path(item["path"]))
            if not isinstance(item.get("fields"), dict) or not item["fields"]:
                raise ServiceError("Vault declarations need a nonempty fields mapping")
            for name, declaration in item["fields"].items():
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) or not isinstance(declaration, dict):
                    raise ServiceError("Invalid Vault field declaration")
                if len(set(declaration) & {"generate", "value", "input"}) != 1:
                    raise ServiceError("Each Vault field requires exactly one value source")
                if "generate" in declaration and (type(declaration["generate"]) is not int
                        or not 16 <= declaration["generate"] <= 256 or declaration.get("encoding", "hex") not in ("hex", "base64")):
                    raise ServiceError("Generated secrets require 16–256 bytes and hex or base64 encoding")
                if "value" in declaration and not isinstance(declaration["value"], str):
                    raise ServiceError("Literal Vault fields must be strings")
                if "input" in declaration and (not isinstance(declaration["input"], str) or not re.fullmatch(r"[A-Z][A-Z0-9_]*", declaration["input"])):
                    raise ServiceError("Secret input names must be uppercase identifiers")
        if len(paths) != len(set(paths)):
            raise ServiceError("Registry and Vault declarations must own distinct paths")
        self._hosts(contract)
        return paths, self._client(contract, checkout)

    def preflight(self, contract, checkout):
        paths, client = self._validate(contract, checkout)
        if contract.get("registry"):
            project = self.gitlab.call("GET", "projects/" + self.project)
            if project.get("path_with_namespace") != self.project_path:
                raise ServiceError("The GitLab project identity differs from the onboarding context")
            self._tokens()
        if paths:
            with self._vault() as api:
                capabilities = api.request("POST", "/v1/sys/capabilities-self", {
                    "paths": ["secret/data/" + path for path in paths],
                })
                for path in paths:
                    permissions = capabilities.get("secret/data/" + path, capabilities.get("capabilities", []))
                    if "root" not in permissions and not {"read", "create", "update"} <= set(permissions):
                        raise ServiceError("Vault credentials lack read/create/update access to the declared application path")
                    stored, _ = self._kv_get(api, path)
                    if contract.get("registry", {}).get("path") == path:
                        self._registry_valid(stored, self._tokens())
                    for item in contract.get("vault", []):
                        if item["path"] == path:
                            self._fields(item["fields"], stored)
        if client:
            with self._keycloak() as api:
                self._identity_state(api, client)
        dns = self._dns_read(contract)
        return {"status": "ready", "vault_paths": paths, "identity": bool(client),
                "dns_hosts": list(contract.get("dns", {}).get("hosts", [])), "dns_type": dns[2][0] if dns else None}

    def provision(self, contract, checkout):
        paths, client = self._validate(contract, checkout)
        outcomes = {}
        if paths:
            with self._vault() as api:
                if contract.get("registry"):
                    outcomes["registry"] = self._registry(api, contract["registry"]["path"])
                outcomes["vault"] = {item["path"]: self._fill_vault(api, item["path"], item["fields"])
                                     for item in contract.get("vault", [])}
        if client:
            with self._keycloak() as api:
                outcomes["identity"] = self._identity(api, client)
        return outcomes

    def publish_dns(self, contract):
        dns = self._dns_read(contract)
        if dns is None:
            return {"dns": "not requested"}
        api, base, target, records = dns
        changed = []
        for host, existing in records.items():
            if self._dns_target() != target:
                raise ServiceError("The public ingress target changed during DNS reconciliation; rerun")
            desired = {"type": target[0], "name": host, "content": target[1], "ttl": 1,
                       "proxied": True, "comment": self.owner}
            if existing and all(existing.get(key) == value for key, value in desired.items()):
                continue
            if existing:
                self._cf_call(api, "PUT", base + "/" + quote(existing["id"], safe=""), desired)
            else:
                self._cf_call(api, "POST", base, desired)
            changed.append(host)
        # Acknowledged writes must also be visible through the provider API.
        for host in records:
            actual = self._cf_call(api, "GET", base + "?" + urlencode({"name": host, "per_page": 100}))
            actual = [item for item in actual if item.get("type") in ("A", "AAAA", "CNAME")]
            if len(actual) != 1 or any(actual[0].get(key) != value for key, value in
                                       {"type": target[0], "content": target[1], "proxied": True}.items()):
                raise ServiceError("Cloudflare DNS publication did not converge")
        return {"dns": "published", "hosts": list(records), "changed": changed, "type": target[0]}
