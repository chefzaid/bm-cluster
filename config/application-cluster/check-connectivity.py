"""Bounded in-cluster dependency checks. Never log response bodies or tokens."""
import json
from pathlib import Path
import socket
import ssl
import urllib.error
import urllib.request

settings = json.loads(Path("/check/config.json").read_text())


def request(url, *, token=None, ca=None, accept=(200,)):
    context = ssl.create_default_context(cafile=ca)
    headers = {"Authorization": "Bearer " + token} if token else {}
    req = urllib.request.Request(url, headers=headers)
    try:
        response = urllib.request.urlopen(req, context=context, timeout=10)
        status = response.status
        data = response.read(1024 * 1024)
    except urllib.error.HTTPError as error:
        status, data = error.code, b""
    if status not in accept:
        raise SystemExit("Dependency HTTP status failed validation")
    return data


if settings["mode"] == "api":
    token = Path("/credentials/token").read_text()
    request(settings["server"] + "/apis/apps/v1/namespaces/apps/deployments?limit=1", token=token, ca="/credentials/ca.crt")
    request(settings["server"] + "/api/v1/namespaces/infra/secrets?limit=1", token=token, ca="/credentials/ca.crt", accept=(403,))
    request(settings["server"] + "/api/v1/nodes?limit=1", token=token, ca="/credentials/ca.crt", accept=(403,))
elif settings["mode"] == "ingress":
    context = ssl.create_default_context(cafile="/credentials/ca.crt")
    with socket.create_connection((settings["address"], 443), timeout=10) as connection:
        with context.wrap_socket(connection, server_hostname=settings["hostname"]) as tls:
            tls.sendall(("GET / HTTP/1.1\r\nHost: " + settings["hostname"] + "\r\nConnection: close\r\n\r\n").encode())
            if not tls.recv(1024).startswith(b"HTTP/"):
                raise SystemExit("Target ingress did not serve HTTPS")
else:
    services = settings["services"]
    endpoints = [services["postgres"], services["redis"], *services["kafka"]["brokers"]]
    for endpoint in endpoints:
        with socket.create_connection((endpoint["host"], endpoint["port"]), timeout=10):
            pass
    # Refuse an accidentally exposed anonymous Redis listener.
    with socket.create_connection((services["redis"]["host"], services["redis"]["port"]), timeout=10) as redis:
        redis.sendall(b"*1\r\n$4\r\nPING\r\n")
        if not redis.recv(1024).startswith(b"-NOAUTH"):
            raise SystemExit("Remote Redis must reject anonymous commands")
    ca = "/credentials/ca.crt" if Path("/credentials/ca.crt").is_file() else None
    request(services["vault"]["url"] + "/v1/sys/health?standbyok=true", ca=ca)
    request(services["registry"]["mirrorEndpoint"] + "/v2/", accept=(200, 401))
    discovery = services["keycloak"]["url"] + "/realms/" + services["keycloak"]["realm"] + "/.well-known/openid-configuration"
    document = json.loads(request(discovery))
    if document.get("issuer") != services["keycloak"]["url"] + "/realms/" + services["keycloak"]["realm"]:
        raise SystemExit("Shared Keycloak issuer differs from inventory")
    request(document["jwks_uri"])
print("Cluster connectivity and authentication boundaries verified")
