"""Public application targets managed by one shared delivery platform."""
import copy
import ipaddress
import json
from pathlib import Path
import re
from urllib.parse import urlparse

import yaml

ENVIRONMENTS = {"int": "testing", "uat": "staging", "prod": "production"}
LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")
DOMAIN = re.compile(r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\Z")


class InventoryError(ValueError):
    pass


class PublicLoader(yaml.SafeLoader):
    pass


def mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if not isinstance(key, str) or key in result:
            raise InventoryError("Inventory keys must be unique strings")
        result[key] = loader.construct_object(value_node)
    return result


PublicLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)


def fields(value, allowed, required, label):
    if not isinstance(value, dict) or set(value) - set(allowed) or set(required) - set(value):
        raise InventoryError(f"Invalid {label} fields; expected public fields: {', '.join(sorted(allowed))}")


def host(value, label):
    if isinstance(value, str):
        try:
            ipaddress.ip_address(value)
            return value
        except ValueError:
            if DOMAIN.fullmatch(value) and len(value) <= 253:
                return value
    raise InventoryError(f"{label} must be an IP address or fully qualified DNS name")


def endpoint(value, label, *, https=False, path=False):
    if not isinstance(value, str):
        raise InventoryError(f"{label} must be a URL")
    parsed = urlparse(value)
    try:
        port = parsed.port
    except ValueError:
        raise InventoryError(f"Invalid port in {label}") from None
    if (parsed.scheme not in (("https",) if https else ("http", "https")) or
            not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or
            (not path and parsed.path not in ("", "/")) or (port is not None and not 1 <= port <= 65535)):
        raise InventoryError(f"{label} must be a {'HTTPS' if https else 'HTTP(S)'} URL without credentials")
    host(parsed.hostname, label)
    return value.rstrip("/")


def port(value, label):
    if type(value) is not int or not 1 <= value <= 65535:
        raise InventoryError(f"{label} must be an integer TCP port")
    return value


def validate_inventory(document, *, allow_partial=False):
    data = copy.deepcopy(document)
    fields(data, {"version", "platform", "environments"}, {"version", "platform", "environments"}, "inventory")
    if type(data["version"]) is not int or data["version"] != 1:
        raise InventoryError("Unsupported deployment inventory version")
    platform = data["platform"]
    fields(platform, {"domain", "internalDomain", "services", "gateway"}, {"domain", "internalDomain", "services", "gateway"}, "platform")
    if not all(isinstance(platform[key], str) and DOMAIN.fullmatch(platform[key]) for key in ("domain", "internalDomain")):
        raise InventoryError("Platform domains must be fully qualified DNS names")
    if platform["domain"] == platform["internalDomain"]:
        raise InventoryError("Public and private platform domains must differ")
    gateway = platform["gateway"]
    fields(gateway, {"address", "nodeCIDRs", "transport", "interface", "nodeName"},
           {"address", "nodeCIDRs", "transport"}, "private service gateway")
    try:
        address = ipaddress.ip_address(gateway["address"])
        if address.version != 4 or address not in ipaddress.ip_network("100.64.0.0/10"):
            raise ValueError()
        if not isinstance(gateway["nodeCIDRs"], list) or not gateway["nodeCIDRs"]:
            raise ValueError()
        networks = [ipaddress.ip_network(cidr, strict=True) for cidr in gateway["nodeCIDRs"]]
        if any(network.version != 4 or not network.subnet_of(ipaddress.ip_network("100.64.0.0/10")) for network in networks):
            raise ValueError()
        if not any(address in network for network in networks):
            raise ValueError()
    except (ValueError, TypeError):
        raise InventoryError("Gateway address and nodeCIDRs must identify the platform's Tailscale nodes") from None
    if gateway["transport"] != "tailscale" or gateway.setdefault("interface", "tailscale0") != "tailscale0":
        raise InventoryError("Shared plaintext services require the verified Tailscale transport")
    if "nodeName" in gateway and (not isinstance(gateway["nodeName"], str) or not LABEL.fullmatch(gateway["nodeName"])):
        raise InventoryError("Gateway nodeName must identify a registered Kubernetes node")
    services = platform["services"]
    fields(services, {"postgres", "redis", "kafka", "vault", "registry", "keycloak"},
           {"postgres", "redis", "kafka", "vault", "registry", "keycloak"}, "shared services")
    for name in ("postgres", "redis"):
        fields(services[name], {"host", "port", "tls"}, {"host", "port"}, name)
        host(services[name]["host"], name)
        port(services[name]["port"], name)
        if "tls" in services[name] and type(services[name]["tls"]) is not bool:
            raise InventoryError(f"{name}.tls must be boolean")
        if services[name].get("tls"):
            raise InventoryError("Managed datastore listeners use authenticated plaintext inside Tailscale; TLS listeners are not configured")
    fields(services["kafka"], {"bootstrapServers", "brokers", "securityProtocol"}, {"bootstrapServers"}, "kafka")
    bootstrap = services["kafka"]["bootstrapServers"]
    if not isinstance(bootstrap, str) or not bootstrap:
        raise InventoryError("Kafka requires reachable authenticated bootstrap servers")
    for address in bootstrap.split(","):
        parsed = urlparse("//" + address)
        try:
            if not parsed.hostname or parsed.port is None or parsed.path or parsed.username:
                raise ValueError()
            host(parsed.hostname, "Kafka broker")
            port(parsed.port, "Kafka broker")
        except ValueError:
            raise InventoryError("Kafka bootstrapServers must contain comma-separated host:port endpoints") from None
    protocol = services["kafka"].setdefault("securityProtocol", "SASL_PLAINTEXT")
    if protocol != "SASL_PLAINTEXT":
        raise InventoryError("The managed Kafka listener requires SASL_PLAINTEXT inside the verified Tailscale transport")
    if "brokers" in services["kafka"]:
        brokers = services["kafka"]["brokers"]
        if not isinstance(brokers, list) or not brokers:
            raise InventoryError("Kafka brokers must be a nonempty list")
        identities = set()
        for broker in brokers:
            fields(broker, {"id", "host", "port"}, {"id", "host", "port"}, "Kafka broker")
            if type(broker["id"]) is not int or broker["id"] < 0 or broker["id"] in identities:
                raise InventoryError("Kafka broker IDs must be unique nonnegative integers")
            identities.add(broker["id"])
            host(broker["host"], "Kafka broker")
            port(broker["port"], "Kafka broker")
    fields(services["vault"], {"url", "caSecretName"}, {"url"}, "vault")
    services["vault"]["url"] = endpoint(services["vault"]["url"], "Vault")
    if urlparse(services["vault"]["url"]).scheme == "http" and urlparse(services["vault"]["url"]).hostname != gateway["address"]:
        raise InventoryError("Plain HTTP Vault must use the encrypted private gateway")
    if services["vault"].get("caSecretName") and not LABEL.fullmatch(services["vault"]["caSecretName"]):
        raise InventoryError("Vault caSecretName must be a Kubernetes name")
    fields(services["registry"], {"host", "mirrorEndpoint"}, {"host", "mirrorEndpoint"}, "registry")
    host(services["registry"]["host"], "Registry hostname")
    services["registry"]["mirrorEndpoint"] = endpoint(services["registry"]["mirrorEndpoint"], "Registry mirror")
    fields(services["keycloak"], {"url", "realm"}, {"url", "realm"}, "keycloak")
    services["keycloak"]["url"] = endpoint(services["keycloak"]["url"], "Keycloak", https=True, path=True)
    if not isinstance(services["keycloak"]["realm"], str) or not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*", services["keycloak"]["realm"]) or services["keycloak"]["realm"] == "master":
        raise InventoryError("Use an application Keycloak realm")
    targets = data["environments"]
    if not isinstance(targets, dict) or not targets or set(targets) - ENVIRONMENTS.keys() or (not allow_partial and set(targets) != ENVIRONMENTS.keys()):
        raise InventoryError("Declare int, uat and prod deployment targets")
    names, servers = set(), set()
    allocated = [("platform", network) for network in networks]
    for environment, target in targets.items():
        fields(target, {"clusterName", "server", "namespace", "domain", "ingressAddress", "podCIDR", "nodeCIDRs", "tlsSecretName", "encryptedTransportInterface"},
               {"clusterName", "server", "ingressAddress", "podCIDR", "nodeCIDRs"}, environment)
        if not isinstance(target["clusterName"], str) or not LABEL.fullmatch(target["clusterName"]) or target["clusterName"] in names:
            raise InventoryError("Each deployment target needs a distinct clusterName")
        names.add(target["clusterName"])
        target["server"] = endpoint(target["server"], environment + " API", https=True)
        if target["server"] in servers or urlparse(target["server"]).hostname == "kubernetes.default.svc":
            raise InventoryError("Deployment environments require distinct explicit cluster API endpoints")
        servers.add(target["server"])
        if target.setdefault("namespace", "apps") != "apps":
            raise InventoryError("Application targets use namespace apps")
        domain = platform["domain"] if environment == "prod" else environment + "." + platform["domain"]
        if target.setdefault("domain", domain) != domain:
            raise InventoryError(f"{environment} domain must be {domain}; shared service domains remain unchanged")
        target.setdefault("tlsSecretName", domain.replace(".", "-") + "-tls")
        if target.setdefault("encryptedTransportInterface", "tailscale0") != "tailscale0":
            raise InventoryError("Application nodes must reach shared services over tailscale0")
        if not isinstance(target["tlsSecretName"], str) or not LABEL.fullmatch(target["tlsSecretName"]):
            raise InventoryError("TLS Secret names must be Kubernetes DNS labels")
        host(target["ingressAddress"], environment + " ingress")
        try:
            ipaddress.ip_network(target["podCIDR"], strict=True)
            if not isinstance(target["nodeCIDRs"], list) or not target["nodeCIDRs"]:
                raise ValueError()
            for cidr in target["nodeCIDRs"]:
                network = ipaddress.ip_network(cidr, strict=True)
                if network.version != 4 or not network.subnet_of(ipaddress.ip_network("100.64.0.0/10")):
                    raise ValueError()
                if any(owner != environment and network.overlaps(existing) for owner, existing in allocated):
                    raise InventoryError("Platform and application environments must have disjoint Tailscale nodeCIDRs")
                allocated.append((environment, network))
        except (ValueError, TypeError):
            raise InventoryError(f"{environment} requires explicit podCIDR and limited nodeCIDRs") from None
    return data


def load_inventory(path, *, allow_partial=False):
    path = Path(path)
    if not path.is_file() or path.stat().st_size > 65536:
        raise InventoryError("Choose a public deployment inventory of at most 64 KiB")
    try:
        return validate_inventory(yaml.load(path.read_text(), Loader=PublicLoader), allow_partial=allow_partial)
    except yaml.YAMLError:
        raise InventoryError("Deployment inventory must be plain YAML or JSON data") from None


def environment_context(inventory, name):
    if name not in ENVIRONMENTS or name not in inventory["environments"]:
        raise InventoryError("The selected deployment environment is not registered")
    return {**inventory["environments"][name], "environment": name, "tier": ENVIRONMENTS[name],
            "project": "applications-" + name, "vaultMount": "kubernetes-" + name}


def inventory_json(inventory):
    return json.dumps(inventory, sort_keys=True, separators=(",", ":"))
