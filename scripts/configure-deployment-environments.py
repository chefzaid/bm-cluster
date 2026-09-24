#!/usr/bin/env python3
"""Bootstrap app foundations and register a verified target with the shared platform."""
import argparse
import base64
import copy
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

import yaml

from lib.deployment_environments import application_hostname, effective_services, environment_context, load_inventory, uses_central_tls, validate_inventory
from lib.onboarding_services import private_token_file

ROOT = Path(__file__).resolve().parents[1]
MANAGER = "application-cluster-bootstrap"
LABEL = "bm-cluster.io/application-environment"
PYTHON_IMAGE = "docker.io/library/python:3.14-alpine@sha256:c6ead215bfd31f1e433d968853b7a769989117115b728874824e6c0a27cb96fc"
NGINX_IMAGE = "docker.io/library/nginx:1.30.4-alpine@sha256:dc5069ad14f19660b141b21236140b91656bf89bbc3e2417c70ae650cd66104c"
API_AUDIENCE = "https://kubernetes.default.svc.cluster.local"
TOKEN_SECRET_ANNOTATION = "bm-cluster.io/token-secret"
PENDING_TOKENS_ANNOTATION = "bm-cluster.io/pending-token-revocations"
RESOURCES = [
    {"apiGroups": [""], "resources": ["configmaps", "secrets", "services", "serviceaccounts", "pods", "pods/log", "events", "persistentvolumeclaims"]},
    {"apiGroups": ["apps"], "resources": ["deployments", "replicasets", "statefulsets", "daemonsets"]},
    {"apiGroups": ["batch"], "resources": ["jobs", "cronjobs"]},
    {"apiGroups": ["networking.k8s.io"], "resources": ["ingresses", "networkpolicies"]},
    {"apiGroups": ["policy"], "resources": ["poddisruptionbudgets"]},
    {"apiGroups": ["autoscaling"], "resources": ["horizontalpodautoscalers"]},
    {"apiGroups": ["external-secrets.io"], "resources": ["externalsecrets"]},
    {"apiGroups": ["traefik.io"], "resources": ["middlewares", "serverstransports"]},
]


def run(command, *, data=None, timeout=300):
    result = subprocess.run([str(part) for part in command], input=data, text=True,
                            capture_output=True, timeout=timeout, check=False)
    if result.returncode:
        # kubectl errors may echo Secret payloads. Never include stdin or stdout.
        raise RuntimeError(f"{Path(str(command[0])).name} operation failed (exit {result.returncode}); inspect the affected resource with its explicit kubeconfig")
    return result.stdout


class Cluster:
    def __init__(self, path):
        self.path = str(Path(path).resolve(strict=True))
        self.prefix = ["kubectl", "--kubeconfig", self.path, "--request-timeout=30s"]

    def call(self, *args, data=None, timeout=300):
        return run([*self.prefix, *args], data=data, timeout=timeout)

    def get(self, kind, name=None, namespace=None, *, optional=False):
        args = ["get", kind]
        if name:
            args.append(name)
        if namespace:
            args += ["-n", namespace]
        if optional:
            args.append("--ignore-not-found")
        output = self.call(*args, "-o", "json")
        return json.loads(output) if output.strip() else None

    def apply(self, resources):
        if not isinstance(resources, list):
            resources = [resources]
        self.call("apply", "--server-side", "--field-manager", MANAGER, "-f", "-",
                  data=json.dumps({"apiVersion": "v1", "kind": "List", "items": resources}))

    def identity(self, expected_server=None):
        config = json.loads(self.call("config", "view", "--minify", "--raw", "--flatten", "-o", "json"))
        cluster = config["clusters"][0]["cluster"]
        if cluster.get("insecure-skip-tls-verify") or not cluster.get("certificate-authority-data"):
            raise ValueError("Cluster kubeconfigs require their CA and verified HTTPS; insecure TLS is forbidden")
        if expected_server and cluster["server"].rstrip("/") != expected_server:
            raise ValueError("Target kubeconfig server does not match the selected inventory entry")
        ca = base64.b64decode(cluster["certificate-authority-data"], validate=True)
        self.call("get", "--raw=/readyz")
        uid = self.get("namespace", "kube-system")["metadata"]["uid"]
        return {"uid": uid, "caHash": hashlib.sha256(ssl.PEM_cert_to_DER_cert(ca.decode())).hexdigest(),
                "caData": cluster["certificate-authority-data"], "server": cluster["server"].rstrip("/")}


def object_(kind, name, *, namespace=None, api="v1", **body):
    metadata = {"name": name, "labels": {"app.kubernetes.io/managed-by": MANAGER}}
    if namespace:
        metadata["namespace"] = namespace
    return {"apiVersion": api, "kind": kind, "metadata": metadata, **body}


def identity_guard(platform, target, environment, registered, *, mode="remote"):
    same_uid = platform["uid"] == target["uid"]
    same_ca = platform["caHash"] == target["caHash"]
    if mode == "local":
        if not (same_uid and same_ca):
            raise ValueError("Local targets must match the shared platform cluster UID and CA")
    elif same_uid or same_ca:
        raise ValueError("Remote targets must be separate clusters from the shared platform")
    for name, identity in registered.items():
        if name == environment:
            if identity["uid"] != target["uid"] or identity["caHash"] != target["caHash"]:
                raise ValueError("Refusing to replace a registered environment with another cluster; migrate it explicitly")
        elif identity["uid"] == target["uid"] or identity["caHash"] == target["caHash"]:
            if not (mode == "local" and identity["uid"] == platform["uid"] and identity["caHash"] == platform["caHash"]):
                raise ValueError("Remote application environments need unique cluster UIDs and CAs")


def namespace_foundation(context):
    name = context["namespace"]
    namespace = object_("Namespace", name)
    namespace["metadata"]["labels"].update({LABEL: context["environment"],
        "bm-cluster.io/application-workloads": "true",
        "pod-security.kubernetes.io/enforce": "baseline",
        "pod-security.kubernetes.io/enforce-version": "v1.36",
        "pod-security.kubernetes.io/warn": "restricted",
        "pod-security.kubernetes.io/audit": "restricted"})
    quota = {"requests.cpu": "4", "limits.cpu": "8", "requests.memory": "8Gi", "limits.memory": "16Gi",
             "pods": "40", "persistentvolumeclaims": "10", "requests.storage": "50Gi", "services": "20"}
    quota.update(context.get("resourceQuota", {}))
    resources = [namespace,
        object_("ResourceQuota", "application-budget", namespace=name, spec={"hard": quota}),
        object_("LimitRange", "application-defaults", namespace=name, spec={"limits": [{"type": "Container",
            "defaultRequest": {"cpu": "100m", "memory": "128Mi"}, "default": {"cpu": "1", "memory": "1Gi"}}]}),
        object_("NetworkPolicy", "default-deny", namespace=name, api="networking.k8s.io/v1",
            spec={"podSelector": {}, "policyTypes": ["Ingress", "Egress"]}),
        object_("NetworkPolicy", "application-connectivity", namespace=name, api="networking.k8s.io/v1", spec={
            "podSelector": {}, "policyTypes": ["Ingress", "Egress"],
            "ingress": [{"from": [{"podSelector": {}}]}, {"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infra"}},
                "podSelector": {"matchLabels": {"app.kubernetes.io/name": "traefik"}}}]},
                {"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infra"}}, "podSelector": {"matchLabels": {"app": "prometheus"}}}]}],
            "egress": [{"to": [{"podSelector": {}}]},
                {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}, "podSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}],
                 "ports": [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]},
                {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infra"}}}],
                 "ports": [{"protocol": "TCP", "port": port} for port in (80, 443, 5432, 6379, 9094, 8200, 5050)]},
                {"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infra"}},
                    "podSelector": {"matchLabels": {"app.kubernetes.io/name": "traefik"}}}],
                 "ports": [{"protocol": "TCP", "port": port} for port in (8080, 8444)]},
                {"to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8"]}}],
                 "ports": [{"protocol": "TCP", "port": 443}]}]})]
    if context.get("mode") == "local":
        for name, role, service_account in (("application-observability-reader", "application-observability-reader", "grafana"),
                ("sonar-apps-discovery", "sonar-apps-discovery-workloads", "sonar-apps-discovery")):
            resources.append(object_("RoleBinding", name, namespace=context["namespace"], api="rbac.authorization.k8s.io/v1",
                subjects=[{"kind": "ServiceAccount", "name": service_account, "namespace": "infra"}],
                roleRef={"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": role}))
    if context.get("gatewayAddress"):
        next(resource for resource in resources if resource["metadata"]["name"] == "application-connectivity")["spec"]["egress"].append({"to": [{"ipBlock": {"cidr": context["gatewayAddress"] + "/32"}}],
            "ports": [{"protocol": "TCP", "port": port} for port in context.get("gatewayPorts", [])]})
        if context.get("mode") == "local":
            next(resource for resource in resources if resource["metadata"]["name"] == "application-connectivity")["spec"]["egress"].append({
                "to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infra"}}, "podSelector": {"matchLabels": {"app": "application-service-gateway"}}}],
                "ports": [{"protocol": "TCP", "port": port - 20000} for port in context.get("gatewayPorts", [])]})
    if context.get("mode", "remote") == "remote":
        # Bootstrap alone creates remote infra. Never relabel or replace an existing platform namespace.
        resources.append(object_("Namespace", "infra"))
        resources.append(object_("ConfigMap", "application-cluster-identity", namespace="infra",
            data={"environment": context["environment"], "clusterName": context["clusterName"],
                  "podCIDR": context["podCIDR"], "platformDomain": context["platformDomain"]}))
    return resources


def node_firewall(pod_cidr):
    network = ipaddress.ip_network(pod_cidr, strict=True)
    template = (ROOT / "config/application-cluster/node-firewall.nft").read_text()
    return template.replace("__POD_FAMILY__", "ip" if network.version == 4 else "ip6").replace("__POD_CIDR__", str(network))


def token_rotation_state(old_registration, rotate=False, *, environment=None):
    annotations = (old_registration or {}).get("metadata", {}).get("annotations", {})
    prefix = "platform-argocd-" + environment + "-token" if environment else "platform-argocd-token"
    current = annotations.get(TOKEN_SECRET_ANNOTATION, prefix)
    pending = json.loads(annotations.get(PENDING_TOKENS_ANNOTATION, "[]"))
    if (not isinstance(pending, list) or any(not isinstance(name, str) or
            not re.fullmatch(r"platform-argocd-(?:(?:int|uat|prod)-)?token(?:-[0-9a-f]{8})?", name) for name in [current, *pending])):
        raise ValueError("Invalid managed Argo token rotation state")
    if current in pending:
        raise ValueError("The active Argo credential cannot be pending revocation")
    if rotate:
        if old_registration:
            pending.append(current)
        current = prefix + "-" + os.urandom(4).hex()
    return current, sorted(set(pending))


def publish_registration(platform, target, registration, current_inventory, updated_inventory, token_secret_name, pending):
    annotations = registration["metadata"]["annotations"]
    annotations[TOKEN_SECRET_ANNOTATION] = token_secret_name
    # Persist the revocation journal with the new credential before publication.
    # A failed inventory update or deletion can then be resumed on any rerun.
    annotations[PENDING_TOKENS_ANNOTATION] = json.dumps(pending)
    platform.apply(registration)
    cm = object_("ConfigMap", "deployment-environments", namespace="infra", data={"environments.json": json.dumps(updated_inventory, sort_keys=True)})
    if current_inventory:
        cm["metadata"]["resourceVersion"] = current_inventory["metadata"]["resourceVersion"]
        platform.call("replace", "-f", "-", data=json.dumps(cm))
    else:
        platform.call("create", "-f", "-", data=json.dumps(cm))
    for name in pending:
        secret = target.get("secret", name, "infra", optional=True)
        if secret and (secret.get("type") != "kubernetes.io/service-account-token" or
                       secret["metadata"].get("annotations", {}).get("kubernetes.io/service-account.name") not in {"platform-argocd", "platform-argocd-" + registration["metadata"]["labels"][LABEL]}):
            raise ValueError("Refusing to revoke a Secret that is not a managed Argo service-account credential")
        target.call("delete", "secret", name, "-n", "infra", "--ignore-not-found")
    if pending:
        # Do not erase a newer concurrent rotation's pending revocations.
        platform.call("patch", "secret", registration["metadata"]["name"], "-n", "infra", "--type=json", "-p", json.dumps([
            {"op": "test", "path": "/metadata/annotations/bm-cluster.io~1token-secret", "value": token_secret_name},
            {"op": "test", "path": "/metadata/annotations/bm-cluster.io~1pending-token-revocations", "value": json.dumps(pending)},
            {"op": "replace", "path": "/metadata/annotations/bm-cluster.io~1pending-token-revocations", "value": "[]"}]))


def argo_rbac(context=None):
    context = context or {"namespace": "apps"}
    namespace = context["namespace"]
    name = "platform-argocd" + ("-" + context["environment"] if "environment" in context else "")
    rules = [{**rule, "resources": [resource for resource in rule["resources"] if not (context.get("mode") == "local" and resource == "networkpolicies")],
              "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"]} for rule in RESOURCES]
    subject = [{"kind": "ServiceAccount", "name": name, "namespace": "infra"}]
    return [object_("ServiceAccount", name, namespace="infra", automountServiceAccountToken=False),
            object_("Role", name, namespace=namespace, api="rbac.authorization.k8s.io/v1", rules=rules),
            object_("RoleBinding", name, namespace=namespace, api="rbac.authorization.k8s.io/v1",
                    subjects=subject, roleRef={"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": name}),
            object_("ClusterRole", name + "-discovery", api="rbac.authorization.k8s.io/v1", rules=[
                {"apiGroups": [""], "resources": ["namespaces"], "resourceNames": [namespace], "verbs": ["get"]},
                {"apiGroups": ["apiextensions.k8s.io"], "resources": ["customresourcedefinitions"], "verbs": ["get", "list", "watch"]}]),
            object_("ClusterRoleBinding", name + "-discovery", api="rbac.authorization.k8s.io/v1", subjects=subject,
                    roleRef={"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": name + "-discovery"})]


def vault_policy(environment):
    # + matches one app name; the environment segment cannot cross its boundary.
    return "\n".join(f'path "secret/{kind}/{path}" {{ capabilities = ["read"] }}'
        for kind in ("data", "metadata")
        for path in (f"apps/+/{environment}/*", "apps/+/registry")) + "\n"


def vault_foundation(context, services):
    sa = "external-secrets-" + context["environment"]
    provider = {"server": services["vault"]["url"], "path": "secret", "version": "v2",
        "auth": {"kubernetes": {"mountPath": context["vaultMount"], "role": "external-secrets",
            "serviceAccountRef": {"name": sa, "namespace": "infra", "audiences": ["vault", API_AUDIENCE]}}}}
    if services["vault"].get("caSecretName"):
        provider["caProvider"] = {"type": "Secret", "name": services["vault"]["caSecretName"], "key": "ca.crt", "namespace": "infra"}
    return [object_("ServiceAccount", sa, namespace="infra", automountServiceAccountToken=False),
        object_("ClusterRoleBinding", sa + "-vault-reviewer", api="rbac.authorization.k8s.io/v1",
        subjects=[{"kind": "ServiceAccount", "name": sa, "namespace": "infra"}],
        roleRef={"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "system:auth-delegator"}),
        object_("ClusterSecretStore", context["secretStoreName"], api="external-secrets.io/v1",
            spec={"conditions": [{"namespaces": [context["namespace"]]}], "provider": {"vault": provider}})]


def cluster_registration(context, identity, token):
    result = object_("Secret", "application-cluster-" + context["environment"], namespace="infra", type="Opaque",
        stringData={"name": context["clusterName"], "server": context["server"], "namespaces": context["namespace"],
            "clusterResources": "false", "project": context["project"],
            "config": json.dumps({"bearerToken": token, "tlsClientConfig": {"insecure": False, "caData": identity["caData"]}})})
    result["metadata"]["labels"][LABEL] = context["environment"]
    if context.get("mode", "remote") == "remote":
        result["metadata"]["labels"]["argocd.argoproj.io/secret-type"] = "cluster"
    else:
        # Registering the in-cluster server with Argo would replace platform-wide credentials.
        result["stringData"]["apiServer"] = identity["server"]
    result["metadata"]["annotations"] = {"bm-cluster.io/cluster-uid": identity["uid"], "bm-cluster.io/ca-sha256": identity["caHash"]}
    return result


def argo_project(context, platform_domain, internal_domain=None):
    repositories = [f"https://gitlab.{platform_domain}/**"]
    if internal_domain:
        repositories.append(f"http://gitlab.{internal_domain}/**")
    return object_("AppProject", context["project"], namespace="infra", api="argoproj.io/v1alpha1", spec={
        "description": f"Application workloads in {context['environment']}; foundation is managed separately",
        "sourceRepos": repositories,
        "destinations": [{"server": context["server"], "namespace": context["namespace"]}],
            "clusterResourceWhitelist": [], "namespaceResourceBlacklist": [
            {"group": "rbac.authorization.k8s.io", "kind": "*"},
            {"group": "external-secrets.io", "kind": "SecretStore"},
            {"group": "external-secrets.io", "kind": "PushSecret"},
            *[{"group": "traefik.io", "kind": kind} for kind in ("IngressRoute", "IngressRouteTCP", "IngressRouteUDP", "TLSStore", "TLSOption", "TraefikService")],
            *([{ "group": "", "kind": kind} for kind in ("ResourceQuota", "LimitRange", "Endpoints")] + [{"group": "discovery.k8s.io", "kind": "EndpointSlice"}, {"group": "networking.k8s.io", "kind": "NetworkPolicy"}] if context.get("mode") == "local" else [])],
        "orphanedResources": {"warn": True}})


def publish_inventory(existing, desired, environment):
    result = copy.deepcopy(existing) if existing else {"version": 1, "platform": desired["platform"], "environments": {}}
    if existing and existing["platform"] != desired["platform"]:
        raise ValueError("Shared endpoint inventory changed; reconcile registered targets before replacing the shared contract")
    result["environments"][environment] = desired["environments"][environment]
    return validate_inventory(result, allow_partial=True)


def gateway_routes(inventory):
    services = inventory["platform"]["services"]
    routes = [("postgres", services["postgres"]["host"], services["postgres"]["port"], "postgres.infra.svc.cluster.local", 5432),
              ("redis", services["redis"]["host"], services["redis"]["port"], "redis.infra.svc.cluster.local", 6379)]
    for broker in services["kafka"]["brokers"]:
        routes.append((f"kafka-{broker['id']}", broker["host"], broker["port"], f"kafka-{broker['id']}.kafka.infra.svc.cluster.local", 9094))
    for name, service, endpoint, destination, port in (
            ("vault", "vault", "url", "vault.infra.svc.cluster.local", 8200),
            ("registry", "registry", "mirrorEndpoint", "gitlab-registry.infra.svc.cluster.local", 5050)):
        parsed = urlparse(services[service][endpoint])
        if parsed.scheme == "http":
            routes.append((name, parsed.hostname, parsed.port or 80, destination, port))
    ports = [item[2] for item in routes]
    if len(ports) != len(set(ports)) or any(not 30000 <= port <= 32767 for port in ports):
        raise ValueError("Managed gateway endpoints require unique NodePorts in 30000..32767")
    if services["postgres"].get("tls") or services["redis"].get("tls") or services["kafka"]["securityProtocol"] != "SASL_PLAINTEXT":
        raise ValueError("The managed TCP gateway uses authenticated datastore listeners over Tailscale; TLS datastore gateways need a separate migration")
    return routes


def gateway_resources(inventory, node_name):
    routes = gateway_routes(inventory)
    cidrs = sorted({cidr for target in inventory["environments"].values() for cidr in target.get("nodeCIDRs", [])}
                   | set(inventory["platform"]["gateway"]["nodeCIDRs"]))
    config = ["pid /tmp/nginx.pid;", "error_log /dev/stderr warn;", "events {}", "stream {"]
    config.append("  resolver kube-dns.kube-system.svc.cluster.local valid=10s ipv6=off;")
    config.append("  log_format connection '$remote_addr $server_port $status'; access_log /dev/stdout connection;")
    ports = []
    for name, _, public_port, upstream, upstream_port in routes:
        port = public_port - 20000
        ports.append({"name": name, "containerPort": port})
        source_cidrs = set(cidrs)
        if name.startswith("kafka-"):
            source_cidrs.update(target["podCIDR"] for target in inventory["environments"].values() if target.get("mode") == "local")
        config += [f"  server {{ listen {port};", *[f"    allow {cidr};" for cidr in sorted(source_cidrs)],
                   "    deny all; proxy_connect_timeout 10s; proxy_timeout 1h;",
                   f"    set $upstream {upstream}:{upstream_port}; proxy_pass $upstream;", "  }"]
    config.append("}")
    text = "\n".join(config) + "\n"
    config_hash = hashlib.sha256(text.encode()).hexdigest()
    labels = {"app": "application-service-gateway"}
    resources = [object_("ConfigMap", "application-service-gateway", namespace="infra", data={"nginx.conf": text}),
        object_("Deployment", "application-service-gateway", namespace="infra", api="apps/v1", spec={
            "replicas": 1, "strategy": {"type": "Recreate"}, "selector": {"matchLabels": labels},
            "template": {"metadata": {"labels": labels, "annotations": {"config-sha256": config_hash}}, "spec": {
                "nodeSelector": {"kubernetes.io/hostname": node_name},
                "tolerations": [{"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"}],
                "automountServiceAccountToken": False,
                "securityContext": {"runAsNonRoot": True, "runAsUser": 101, "runAsGroup": 101, "fsGroup": 101, "seccompProfile": {"type": "RuntimeDefault"}},
                "containers": [{"name": "gateway", "image": NGINX_IMAGE, "command": ["nginx", "-g", "daemon off;"],
                    "ports": ports, "resources": {"requests": {"cpu": "20m", "memory": "32Mi"}, "limits": {"cpu": "500m", "memory": "128Mi"}},
                    "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                    "readinessProbe": {"tcpSocket": {"port": ports[0]["containerPort"]}},
                    "volumeMounts": [{"name": "config", "mountPath": "/etc/nginx/nginx.conf", "subPath": "nginx.conf", "readOnly": True},
                                     {"name": "tmp", "mountPath": "/tmp"}]}],
                "volumes": [{"name": "config", "configMap": {"name": "application-service-gateway"}}, {"name": "tmp", "emptyDir": {"sizeLimit": "16Mi"}}]}}}),
        object_("NetworkPolicy", "application-service-gateway", namespace="infra", api="networking.k8s.io/v1", spec={
            "podSelector": {"matchLabels": labels}, "policyTypes": ["Ingress"],
            "ingress": [{"from": [{"ipBlock": {"cidr": cidr}} for cidr in cidrs],
                         "ports": [{"protocol": "TCP", "port": port["containerPort"]} for port in ports]}]})]
    local_namespaces = [target["namespace"] for target in inventory["environments"].values() if target.get("mode") == "local"]
    if local_namespaces:
        resources[-1]["spec"]["ingress"].append({"from": [{"namespaceSelector": {"matchExpressions": [{"key": "kubernetes.io/metadata.name", "operator": "In", "values": local_namespaces}]}}],
            "ports": [{"protocol": "TCP", "port": public_port - 20000} for name, _, public_port, _, _ in routes if name.startswith("kafka-")]})
    for name, _, node_port, _, _ in routes:
        resources.append(object_("Service", "application-gateway-" + name, namespace="infra", spec={
            "type": "NodePort", "externalTrafficPolicy": "Local", "selector": labels,
            "ports": [{"name": name, "port": node_port, "targetPort": node_port - 20000, "nodePort": node_port}]}))
    return resources


def probe(cluster, namespace, script, config, *, secret=None, node=None, host_network=False):
    """Run bounded, ephemeral checks in the network namespace that consumes a route."""
    name = "application-route-check-" + os.urandom(4).hex()
    cluster.apply(object_("ConfigMap", name, namespace=namespace, data={"check.py": script, "config.json": json.dumps(config)}))
    volumes = [{"name": "check", "configMap": {"name": name}}]
    mounts = [{"name": "check", "mountPath": "/check", "readOnly": True}]
    if secret:
        encoded = {key: base64.b64encode(value.encode()).decode() for key, value in secret.items()}
        cluster.apply(object_("Secret", name, namespace=namespace, data=encoded))
        volumes.append({"name": "credentials", "secret": {"secretName": name}})
        mounts.append({"name": "credentials", "mountPath": "/credentials", "readOnly": True})
    spec = {"restartPolicy": "Never", "automountServiceAccountToken": False,
        "activeDeadlineSeconds": 120, "volumes": volumes,
        "securityContext": {"runAsNonRoot": True, "runAsUser": 65532, "runAsGroup": 65532, "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{"name": "check", "image": PYTHON_IMAGE, "command": ["python3", "/check/check.py"],
            "volumeMounts": mounts, "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
            "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"cpu": "250m", "memory": "96Mi"}}}]}
    if node:
        spec["nodeName"] = node
    if host_network:
        spec.update(hostNetwork=True, dnsPolicy="ClusterFirstWithHostNet")
    job = object_("Job", name, namespace=namespace, api="batch/v1", spec={"backoffLimit": 0, "ttlSecondsAfterFinished": 300,
        "template": {"metadata": {"labels": {"app": "application-route-check"}}, "spec": spec}})
    try:
        cluster.apply(job)
        cluster.call("wait", "--for=condition=complete", "job/" + name, "-n", namespace, "--timeout=150s", timeout=180)
        return cluster.call("logs", "job/" + name, "-n", namespace).strip()
    finally:
        cluster.call("delete", "job,configmap,secret", name, "-n", namespace, "--ignore-not-found", "--wait=false")


def vault_call(platform, pod, token, args, payload=None):
    # Root/admin credentials travel only over the platform kubeconfig, via stdin.
    script = 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200; exec vault "$@"'
    data = token + "\n" + (json.dumps(payload) if payload is not None else "")
    return platform.call("exec", "-i", "-n", "infra", pod, "--", "sh", "-ceu", script, "sh", *args, data=data)


def configure_vault(platform, context, identity, token):
    pods = platform.get("pods", namespace="infra")["items"]
    candidates = [pod["metadata"]["name"] for pod in pods if pod["metadata"].get("labels", {}).get("app.kubernetes.io/name") == "vault"
                  and any(c.get("type") == "Ready" and c.get("status") == "True" for c in pod.get("status", {}).get("conditions", []))]
    if not candidates:
        raise ValueError("The central Vault has no Ready server")
    pod = candidates[0]
    mounts = json.loads(vault_call(platform, pod, token, ["auth", "list", "-format=json"]))
    mount = context["vaultMount"]
    if mount + "/" not in mounts:
        vault_call(platform, pod, token, ["auth", "enable", "-path=" + mount, "kubernetes"])
    elif mounts[mount + "/"]["type"] != "kubernetes":
        raise ValueError("Existing Vault auth mount has an incompatible type")
    vault_call(platform, pod, token, ["write", "auth/" + mount + "/config", "-"], {
        "kubernetes_host": context["server"], "kubernetes_ca_cert": base64.b64decode(identity["caData"]).decode(),
        "token_reviewer_jwt": "", "disable_local_ca_jwt": True})
    policy = "application-" + context["environment"]
    vault_call(platform, pod, token, ["write", "sys/policies/acl/" + policy, "-"], {"policy": vault_policy(context["environment"])})
    vault_call(platform, pod, token, ["write", "auth/" + mount + "/role/external-secrets", "-"], {
        "bound_service_account_names": ["external-secrets-" + context["environment"]], "bound_service_account_namespaces": ["infra"],
        "audience": "vault", "token_policies": [policy], "token_ttl": "1h", "token_max_ttl": "2h"})


def helm_foundation(target, context):
    env = dict(os.environ, KUBECONFIG=target.path, HIGH_AVAILABILITY_ENABLED="false")
    result = subprocess.run([str(ROOT / "scripts/reconcile-platform-release.sh"), "external-secrets"], env=env, check=False)
    if result.returncode:
        raise RuntimeError("Target External Secrets installation failed")
    versions = dict(line.split("=", 1) for line in (ROOT / "config/platform.env").read_text().splitlines() if line and not line.startswith("#"))
    values = yaml.safe_load((ROOT / "config/traefik-values.yaml").read_text())
    values["tlsStore"]["default"]["defaultCertificate"]["secretName"] = context["tlsSecretName"]
    values["nodeSelector"] = {"kubernetes.io/os": "linux"}
    values["providers"]["kubernetesIngress"]["allowExternalNameServices"] = False
    values["ports"]["websecure"]["forwardedHeaders"] = {"trustedIPs": []}
    with tempfile.TemporaryDirectory(prefix="application-foundation-") as directory:
        path = Path(directory) / "traefik.yaml"
        path.write_text(yaml.safe_dump(values))
        run(["helm", "repo", "add", "traefik", "https://traefik.github.io/charts", "--force-update"])
        run(["helm", "repo", "update", "traefik", "--fail-on-repo-update-fail"])
        run(["helm", "--kubeconfig", target.path, "upgrade", "--install", "traefik", "traefik/traefik", "-n", "infra",
             "--version", versions["DEFAULT_TRAEFIK_CHART_VERSION"], "--values", path, "--wait", "--timeout", "300s"], timeout=360)


def tls_secret(target, context, cert, key):
    certificate = Path(cert).read_bytes()
    private_key = Path(key).read_bytes()
    run(["openssl", "x509", "-in", cert, "-noout", "-checkend", "86400"])
    for host in (context["domain"], application_hostname(context, "devapp")):
        run(["openssl", "x509", "-in", cert, "-noout", "-checkhost", host])
    if run(["openssl", "x509", "-in", cert, "-pubkey", "-noout"]) != run(["openssl", "pkey", "-in", key, "-pubout"]):
        raise ValueError("Ingress certificate and private key do not match")
    data = {"tls.crt": base64.b64encode(certificate).decode(), "tls.key": base64.b64encode(private_key).decode()}
    if uses_central_tls(context):
        existing = target.get("secret", context["tlsSecretName"], "infra", optional=True)
        if not existing or any(existing.get("data", {}).get(key) != value for key, value in data.items()):
            raise ValueError("Shared TLS is platform-owned; supplied certificate must match the existing platform certificate")
        return
    for namespace in ([context["namespace"]] if context.get("mode") == "local" else [context["namespace"], "infra"]):
        target.apply(object_("Secret", context["tlsSecretName"], namespace=namespace, type="kubernetes.io/tls", data=data))


def ingress_boundary(context):
    name = "application-domain-" + context["environment"]
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    suffix = context.get("hostnameSuffix", "")
    if suffix:
        pattern = "^(?:" + label + re.escape(suffix) + r"\." + re.escape(context["domain"]) + "|" + re.escape(application_hostname(context, "@")) + ")$"
    else:
        pattern = "^(?:" + label + r"\.)?" + re.escape(context["domain"]) + "$"
    defaults = dict(line.split("=", 1) for line in (ROOT / "config/platform.env").read_text().splitlines() if line and not line.startswith("#"))
    reserved = [label + "." + context["domain"] for label in [*defaults["DEFAULT_CLOUDFLARE_HOST_LABELS"].split(","), "int", "uat", "www"]]
    host_rule = "has(r.host) && r.host.matches(" + json.dumps(pattern) + ")"
    if context["environment"] == "prod":
        host_rule += " && !(r.host in " + json.dumps(reserved) + ")"
        if context.get("hostnameStyle") == "suffix":
            host_rule += " && !r.host.endsWith(" + json.dumps("-int." + context["domain"]) + ") && !r.host.endsWith(" + json.dumps("-uat." + context["domain"]) + ")"
    tls_secret_rule = "!has(t.secretName)" if uses_central_tls(context) else "has(t.secretName) && t.secretName == " + json.dumps(context["tlsSecretName"])
    validations = [
        {"expression": "!has(object.spec.defaultBackend) && has(object.spec.rules) && size(object.spec.rules) > 0 && object.spec.rules.all(r, " + host_rule + ")",
         "message": "Ingress hosts must stay inside this application environment and cannot claim platform hostnames."},
        {"expression": "has(object.spec.tls) && size(object.spec.tls) > 0 && object.spec.tls.all(t, " + tls_secret_rule + " && has(t.hosts) && size(t.hosts) > 0 && t.hosts.all(h, object.spec.rules.exists(r, r.host == h)))",
         "message": "Ingress TLS must use the registered certificate source and matching application hosts."}]
    return [object_("ValidatingAdmissionPolicy", name, api="admissionregistration.k8s.io/v1", spec={
        "failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": ["networking.k8s.io"], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE"], "resources": ["ingresses"]}]},
        "validations": validations}),
        object_("ValidatingAdmissionPolicyBinding", name, api="admissionregistration.k8s.io/v1", spec={
            "policyName": name, "validationActions": ["Deny"],
            "matchResources": {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": context["namespace"]}}}})]


def service_boundary(context):
    name = "application-service-" + context["environment"]
    return [object_("ValidatingAdmissionPolicy", name, api="admissionregistration.k8s.io/v1", spec={
        "failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": [""], "apiVersions": ["v1"], "operations": ["CREATE", "UPDATE"], "resources": ["services"]}]},
        "validations": [{"expression": "has(object.spec.selector) && size(object.spec.selector) > 0 && (!has(object.spec.type) || object.spec.type == 'ClusterIP') && (!has(object.spec.externalIPs) || size(object.spec.externalIPs) == 0) && !has(object.spec.externalName) && !has(object.spec.loadBalancerIP)",
            "message": "Application services must select local pods and remain ClusterIP services; public access uses the environment ingress."}]}),
        object_("ValidatingAdmissionPolicyBinding", name, api="admissionregistration.k8s.io/v1", spec={
            "policyName": name, "validationActions": ["Deny"],
            "matchResources": {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": context["namespace"]}}}})]


def middleware_boundary(context):
    # Traefik preserves arbitrary plugin configuration; dyn keeps its presence check
    # available when the CRD type checker omits that schemaless property.
    name = "application-middleware-" + context["environment"]
    return [object_("ValidatingAdmissionPolicy", name, api="admissionregistration.k8s.io/v1", spec={
        "failurePolicy": "Fail", "matchConstraints": {"resourceRules": [{"apiGroups": ["traefik.io"], "apiVersions": ["v1alpha1"], "operations": ["CREATE", "UPDATE"], "resources": ["middlewares"]}]},
        "validations": [{"expression": "!has(object.spec.forwardAuth) && !has(object.spec.errors) && !has(dyn(object.spec).plugin)",
            "message": "Application middleware cannot make controller requests to arbitrary services; authentication proxies are platform-managed."}]}),
        object_("ValidatingAdmissionPolicyBinding", name, api="admissionregistration.k8s.io/v1", spec={
            "policyName": name, "validationActions": ["Deny"],
            "matchResources": {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": context["namespace"]}}}})]


def prepare_mixed_gateway(platform, inventory, nodes):
    """Make the single advertised Kafka listener reachable regardless of target registration order."""
    gateway = inventory["platform"]["gateway"]
    routes = gateway_routes(inventory)
    for _, host, _, _, _ in routes:
        if {str(ipaddress.ip_address(item[4][0])) for item in socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)} != {gateway["address"]}:
            raise ValueError("Managed gateway service endpoints must resolve only to the declared Tailscale address")
    selected = [node for node in nodes if (node["metadata"]["name"] == gateway["nodeName"] if gateway.get("nodeName") else
        any(address["address"] == gateway["address"] for address in node["status"]["addresses"]))]
    if len(selected) != 1:
        raise ValueError("The gateway must identify exactly one platform node")
    selected = selected[0]
    remote = next(target for target in inventory["environments"].values() if target["mode"] == "remote")
    namespace = "application-route-verification-" + os.urandom(4).hex()
    try:
        platform.apply(object_("Namespace", namespace))
        script = (ROOT / "config/application-cluster/check-host-route.py").read_text()
        for node in nodes:
            own_gateway = node["metadata"]["name"] == selected["metadata"]["name"]
            settings = {"address": urlparse(remote["server"]).hostname if own_gateway else gateway["address"], "interface": gateway["interface"]}
            if own_gateway:
                settings["localAddress"] = gateway["address"]
            probe(platform, namespace, script, settings, node=node["metadata"]["name"], host_network=True)
    finally:
        platform.call("delete", "namespace", namespace, "--ignore-not-found", "--wait=false")
    platform.apply(gateway_resources(inventory, selected["metadata"]["labels"]["kubernetes.io/hostname"]))
    platform.call("rollout", "status", "deployment/application-service-gateway", "-n", "infra", "--timeout=180s")


def register_local(args, inventory, context, platform, target, identity):
    """Add namespaces to an existing platform without replacing any shared controller."""
    current = platform.get("configmap", "deployment-environments", "infra", optional=True)
    updated = publish_inventory(json.loads(current["data"]["environments.json"]) if current else None, inventory, args.environment)
    services = effective_services(inventory, args.environment)
    nodes = target.get("nodes")["items"]
    if not nodes or any(not any(c.get("type") == "Ready" and c.get("status") == "True" for c in node.get("status", {}).get("conditions", [])) for node in nodes):
        raise ValueError("All platform nodes must be Ready before registering local environments")
    for node in nodes:
        for cidr in node.get("spec", {}).get("podCIDRs", []):
            if not ipaddress.ip_network(cidr).subnet_of(ipaddress.ip_network(context["podCIDR"])):
                raise ValueError("Declared local podCIDR must contain every platform node pod allocation")
    # Controller ownership remains with the platform; these operations are read-only.
    target.get("customresourcedefinition", "clustersecretstores.external-secrets.io")
    target.call("rollout", "status", "deployment/traefik", "-n", "infra", "--timeout=180s")
    if uses_central_tls(context):
        store = target.get("tlsstore", "default", "infra")
        if store.get("spec", {}).get("defaultCertificate", {}).get("secretName") != context["tlsSecretName"]:
            raise ValueError("The shared Traefik TLSStore must use the inventory platform certificate")
    run(["env", "KUBECONFIG=" + platform.path, "python3", ROOT / "scripts/configure-application-data.py", "--inventory", args.config, "--check"], timeout=300)
    if inventory["platform"].get("gateway") and any(t["mode"] == "remote" for t in inventory["environments"].values()):
        prepare_mixed_gateway(platform, inventory, nodes)
        context["gatewayAddress"] = inventory["platform"]["gateway"]["address"]
        context["gatewayPorts"] = [broker["port"] for broker in services["kafka"].get("brokers", [])]
    target.apply(namespace_foundation(context))
    target.apply(argo_rbac(context))
    target.apply(ingress_boundary(context))
    target.apply(service_boundary(context))
    target.apply(middleware_boundary(context))
    if bool(args.tls_cert) != bool(args.tls_key):
        raise ValueError("Supply both --tls-cert and --tls-key")
    if args.tls_cert:
        tls_secret(target, context, args.tls_cert, args.tls_key)
    else:
        run(["python3", ROOT / "scripts/configure-application-dns.py", "--config", args.config, "--environment", args.environment,
             "--target-kubeconfig", target.path, "--platform-kubeconfig", platform.path, "--certificate-only"], timeout=180)
    if args.vault_ca:
        name = services["vault"].get("caSecretName")
        if not name:
            raise ValueError("Set the effective vault.caSecretName when supplying --vault-ca")
        target.apply(object_("Secret", name, namespace="infra", data={"ca.crt": base64.b64encode(Path(args.vault_ca).read_bytes()).decode()}))
    token = private_token_file(args.vault_token_file)
    if not token or any(c.isspace() for c in token):
        raise ValueError("Vault token file must contain one nonempty token")
    configure_vault(platform, context, identity, token)
    del token
    target.apply(vault_foundation(context, services))
    target.call("wait", "--for=condition=Ready", "clustersecretstore/" + context["secretStoreName"], "--timeout=180s")
    old = platform.get("secret", "application-cluster-" + args.environment, "infra", optional=True)
    token_name, pending = token_rotation_state(old, args.rotate_argocd_token, environment=args.environment)
    credential = object_("Secret", token_name, namespace="infra", type="kubernetes.io/service-account-token")
    credential["metadata"]["annotations"] = {"kubernetes.io/service-account.name": "platform-argocd-" + args.environment}
    target.apply(credential)
    target.call("wait", "--for=jsonpath={.data.token}", "secret/" + token_name, "-n", "infra", "--timeout=60s")
    argo_token = base64.b64decode(target.get("secret", token_name, "infra")["data"]["token"]).decode()
    check = (ROOT / "config/application-cluster/check-connectivity.py").read_text()
    probe(platform, "infra", check, {"mode": "api", "server": context["server"], "namespace": context["namespace"]},
          secret={"token": argo_token, "ca.crt": base64.b64decode(identity["caData"]).decode()})
    ca = None
    if services["vault"].get("caSecretName"):
        ca = base64.b64decode(target.get("secret", services["vault"]["caSecretName"], "infra")["data"]["ca.crt"]).decode()
    probe(target, context["namespace"], check, {"mode": "dependencies", "services": services}, secret={"ca.crt": ca} if ca else None)
    # Check this namespace's certificate without modifying Traefik's global default.
    hostname = application_hostname(context, "registration-check")
    ingress_name = "registration-check-" + os.urandom(4).hex()
    tls = {"hosts": [hostname]}
    if not uses_central_tls(context):
        tls["secretName"] = context["tlsSecretName"]
    ingress = object_("Ingress", ingress_name, namespace=context["namespace"], api="networking.k8s.io/v1", spec={
        "ingressClassName": "traefik", "tls": [tls],
        "rules": [{"host": hostname, "http": {"paths": [{"path": "/", "pathType": "Prefix", "backend": {"service": {"name": ingress_name, "port": {"number": 80}}}}]}}]})
    trust = (ROOT / "config/cloudflare-origin-ca.pem").read_text()
    if args.tls_cert:
        trust += "\n" + Path(args.tls_cert).read_text()
    try:
        target.apply(ingress)
        probe(platform, "infra", check, {"mode": "ingress", "address": context["ingressAddress"], "hostname": hostname}, secret={"ca.crt": trust})
    finally:
        target.call("delete", "ingress", ingress_name, "-n", context["namespace"], "--ignore-not-found", "--wait=false")
    platform.apply(argo_project(context, inventory["platform"]["domain"], inventory["platform"]["internalDomain"]))
    registration = cluster_registration(context, identity, argo_token)
    publish_registration(platform, target, registration, current, updated, token_name, pending)
    print(f"Registered {args.environment}: existing platform / {context['namespace']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--environment", choices=("int", "uat", "prod"), required=True)
    parser.add_argument("--platform-kubeconfig", required=True)
    parser.add_argument("--target-kubeconfig", help="Required for remote targets; defaults to the platform kubeconfig for local targets")
    parser.add_argument("--vault-token-file", required=True, help="Local central Vault administrator token; never copied to the target")
    parser.add_argument("--tls-cert")
    parser.add_argument("--tls-key")
    parser.add_argument("--vault-ca", help="Public CA PEM for an explicitly configured HTTPS Vault endpoint")
    parser.add_argument("--rotate-argocd-token", action="store_true")
    args = parser.parse_args()
    inventory = load_inventory(args.config)
    context = environment_context(inventory, args.environment)
    context["platformDomain"] = inventory["platform"]["domain"]
    services = effective_services(inventory, args.environment)
    local = context["mode"] == "local"
    if not local and not args.target_kubeconfig:
        raise ValueError("Remote targets require --target-kubeconfig")
    platform, target = Cluster(args.platform_kubeconfig), Cluster(args.target_kubeconfig or args.platform_kubeconfig)
    platform_id, target_id = platform.identity(), target.identity(None if local else context["server"])
    platform_identity = platform.get("configmap", "bm-cluster-identity", "infra")
    if platform_identity["data"]["PLATFORM_DOMAIN"] != inventory["platform"]["domain"]:
        raise ValueError("Platform kubeconfig identity does not match the inventory domain")
    registered = {}
    for secret in platform.get("secrets", namespace="infra")["items"]:
        environment = secret["metadata"].get("labels", {}).get(LABEL)
        if environment:
            annotations = secret["metadata"].get("annotations", {})
            registered[environment] = {"uid": annotations["bm-cluster.io/cluster-uid"], "caHash": annotations["bm-cluster.io/ca-sha256"]}
    identity_guard(platform_id, target_id, args.environment, registered, mode=context["mode"])
    if local:
        register_local(args, inventory, context, platform, target, target_id)
        return
    installed = target.get("configmap", "application-cluster-identity", "infra", optional=True)
    expected = {"environment": args.environment, "clusterName": context["clusterName"], "podCIDR": context["podCIDR"], "platformDomain": context["platformDomain"]}
    if not installed or installed.get("data") != expected:
        raise ValueError("Target is not the matching bootstrapped application cluster; run install-application-cluster.sh on that host first")
    current = platform.get("configmap", "deployment-environments", "infra", optional=True)
    updated = publish_inventory(json.loads(current["data"]["environments.json"]) if current else None, inventory, args.environment)
    routes = gateway_routes(inventory)
    gateway = inventory["platform"]["gateway"]
    for _, host, _, _, _ in routes:
        if {str(ipaddress.ip_address(item[4][0])) for item in socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)} != {gateway["address"]}:
            raise ValueError("All managed service endpoints must resolve only to the declared Tailscale gateway")
    nodes = target.get("nodes")["items"]
    if not nodes or any(not any(c.get("type") == "Ready" and c.get("status") == "True" for c in node.get("status", {}).get("conditions", [])) for node in nodes):
        raise ValueError("Every declared target node must be Ready")
    for node in nodes:
        addresses = [a["address"] for a in node["status"]["addresses"] if a["type"] == "InternalIP"]
        if not addresses or not all(any(ipaddress.ip_address(address) in ipaddress.ip_network(cidr) for cidr in context["nodeCIDRs"]) for address in addresses):
            raise ValueError("Target node InternalIPs fall outside the selected environment nodeCIDRs")
    platform_nodes = platform.get("nodes")["items"]
    matches = [node["metadata"]["name"] for node in platform_nodes if
               (node["metadata"]["name"] == gateway["nodeName"] if gateway.get("nodeName") else
                any(a["address"] == gateway["address"] for a in node["status"]["addresses"]))]
    if len(matches) != 1:
        raise ValueError("The declared gateway address must identify exactly one registered platform node")
    # Data auth migration must finish before exposing a single remote port.
    run(["env", "KUBECONFIG=" + platform.path, "python3", ROOT / "scripts/configure-application-data.py", "--inventory", args.config, "--check"], timeout=300)
    context["gatewayAddress"] = gateway["address"]
    context["gatewayPorts"] = [item[2] for item in routes]
    target.apply(namespace_foundation(context))
    target.apply(argo_rbac(context))
    # Host-network probes need a short-lived privileged namespace, never apps/infra.
    route_namespace = "application-route-verification-" + os.urandom(4).hex()
    route_clusters = []
    try:
        for cluster in (platform, target):
            cluster.apply(object_("Namespace", route_namespace))
            route_clusters.append(cluster)
        host_check = (ROOT / "config/application-cluster/check-host-route.py").read_text()
        for node in nodes:
            probe(target, route_namespace, host_check, {"address": gateway["address"], "interface": context["encryptedTransportInterface"]},
                  node=node["metadata"]["name"], host_network=True)
        probe(platform, route_namespace, host_check, {"address": urlparse(context["server"]).hostname, "interface": gateway["interface"], "localAddress": gateway["address"]},
              node=matches[0], host_network=True)
    finally:
        for cluster in route_clusters:
            cluster.call("delete", "namespace", route_namespace, "--ignore-not-found", "--wait=false")
    gateway_node = next(node for node in platform_nodes if node["metadata"]["name"] == matches[0])
    platform.apply(gateway_resources(inventory, gateway_node["metadata"]["labels"]["kubernetes.io/hostname"]))
    platform.call("rollout", "status", "deployment/application-service-gateway", "-n", "infra", "--timeout=180s")
    if bool(args.tls_cert) != bool(args.tls_key):
        raise ValueError("Supply both --tls-cert and --tls-key")
    if args.tls_cert:
        tls_secret(target, context, args.tls_cert, args.tls_key)
    else:
        run(["python3", ROOT / "scripts/configure-application-dns.py", "--config", args.config, "--environment", args.environment,
             "--target-kubeconfig", target.path, "--platform-kubeconfig", platform.path, "--certificate-only"], timeout=180)
        certificate = target.get("secret", context["tlsSecretName"], context["namespace"])
        target.apply(object_("Secret", context["tlsSecretName"], namespace="infra", type="kubernetes.io/tls", data=certificate["data"]))
    if args.vault_ca:
        name = services["vault"].get("caSecretName")
        if not name:
            raise ValueError("Set platform.services.vault.caSecretName when supplying --vault-ca")
        target.apply(object_("Secret", name, namespace="infra", data={"ca.crt": base64.b64encode(Path(args.vault_ca).read_bytes()).decode()}))
    helm_foundation(target, context)
    token = private_token_file(args.vault_token_file)
    if not token or any(c.isspace() for c in token):
        raise ValueError("Vault token file must contain one nonempty token")
    configure_vault(platform, context, target_id, token)
    del token
    target.apply(vault_foundation(context, services))
    target.call("wait", "--for=condition=Ready", "clustersecretstore/" + context["secretStoreName"], "--timeout=180s")
    old_registration = platform.get("secret", "application-cluster-" + args.environment, "infra", optional=True)
    token_secret_name, pending_tokens = token_rotation_state(old_registration, args.rotate_argocd_token, environment=args.environment)
    secret = object_("Secret", token_secret_name, namespace="infra", type="kubernetes.io/service-account-token")
    secret["metadata"]["annotations"] = {"kubernetes.io/service-account.name": "platform-argocd-" + args.environment}
    target.apply(secret)
    target.call("wait", "--for=jsonpath={.data.token}", "secret/" + token_secret_name, "-n", "infra", "--timeout=60s")
    argo_token = base64.b64decode(target.get("secret", token_secret_name, "infra")["data"]["token"]).decode()
    check = (ROOT / "config/application-cluster/check-connectivity.py").read_text()
    probe(platform, "infra", check, {"mode": "api", "server": context["server"], "namespace": context["namespace"]},
          secret={"token": argo_token, "ca.crt": base64.b64decode(target_id["caData"]).decode()})
    ca = None
    if services["vault"].get("caSecretName"):
        ca = base64.b64decode(target.get("secret", services["vault"]["caSecretName"], "infra")["data"]["ca.crt"]).decode()
    probe(target, "infra", check, {"mode": "dependencies", "services": services}, secret={"ca.crt": ca} if ca else None)
    certificate = target.get("secret", context["tlsSecretName"], context["namespace"])
    trust = (ROOT / "config/cloudflare-origin-ca.pem").read_text()
    if args.tls_cert:
        trust += "\n" + Path(args.tls_cert).read_text()
    probe(platform, "infra", check, {"mode": "ingress", "address": context["ingressAddress"], "hostname": application_hostname(context, "devapp")},
          secret={"ca.crt": trust})
    platform.call("patch", "configmap", "argocd-cm", "-n", "infra", "--type=merge", "-p", json.dumps({"data": {"resource.respectRBAC": "normal"}}))
    platform.apply(argo_project(context, inventory["platform"]["domain"], inventory["platform"]["internalDomain"]))
    registration = cluster_registration(context, target_id, argo_token)
    # Optimistic concurrency prevents simultaneous registration from dropping a peer.
    publish_registration(platform, target, registration, current, updated, token_secret_name, pending_tokens)
    print(f"Registered {args.environment}: {context['clusterName']} / {context['namespace']} with the shared platform")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError, subprocess.TimeoutExpired) as exc:
        print(f"Registration stopped: {exc}", file=sys.stderr)
        sys.exit(1)
