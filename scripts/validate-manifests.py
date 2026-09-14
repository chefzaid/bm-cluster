#!/usr/bin/env python3
"""Offline deployment validation: source inputs and installer/GitOps rendering."""

import argparse
import copy
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
GROUPS = ("base", "datastores", "platform", "corp", "addons")
TOKEN = re.compile(r"__[A-Z][A-Z0-9_]+__")
DIGEST = re.compile(r"@sha256:[a-f0-9]{64}$")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*command, **kwargs):
    return subprocess.check_output(command, text=True, cwd=ROOT, **kwargs)


def documents(text):
    return [doc for doc in yaml.safe_load_all(text) if isinstance(doc, dict) and doc.get("kind")]


def identity(doc):
    meta = doc.get("metadata", {})
    return doc.get("apiVersion"), doc["kind"], meta.get("namespace", ""), meta.get("name", meta.get("generateName"))


def index(resources):
    result = {}
    for doc in resources:
        key = identity(doc)
        require(key not in result, f"Duplicate resource: {key}")
        result[key] = doc
    return result


def comparable(doc):
    if not doc:
        return doc
    if doc["kind"] == "Application":
        doc = copy.deepcopy(doc)
        helm = doc["spec"]["source"]["helm"]
        defaults = yaml.safe_load((ROOT / "k8s/values.yaml").read_text())

        def merge(base, override):
            for key, value in override.items():
                if isinstance(value, dict) and isinstance(base.get(key), dict):
                    merge(base[key], value)
                else:
                    base[key] = value

        merge(defaults, helm.get("valuesObject", {}))
        helm["valuesObject"] = defaults
        return doc
    if doc["kind"] != "ConfigMap":
        return doc
    # JSON/YAML encoders can escape the same value differently (e.g. &).
    data = dict(doc.get("data", {}))
    for name, content in data.items():
        if name.endswith((".yaml", ".yml", ".json")):
            data[name] = list(yaml.safe_load_all(content))
    return {**doc, "data": data}


def images(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"image", "imageName"} and isinstance(child, str):
                yield child
            elif key == "expression" and isinstance(child, str):
                yield from re.findall(r'''\bimage:\s*['"]([^'"]+)['"]''', child)
            yield from images(child)
    elif isinstance(value, list):
        for child in value:
            yield from images(child)


def workload_policy(doc):
    spec = doc.get("spec", {})
    if doc["kind"] == "CronJob":
        spec = spec["jobTemplate"]["spec"]
    if doc["kind"] not in {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}:
        return
    pod = spec["template"]["spec"]
    label = "/".join(str(part) for part in identity(doc))
    require(isinstance(pod.get("automountServiceAccountToken"), bool), f"{label}: declare token mounting intent")
    for container in pod.get("initContainers", []) + pod.get("containers", []):
        for budget in ("requests", "limits"):
            values = container.get("resources", {}).get(budget, {})
            require(values.get("cpu") and values.get("memory"), f"{label}/{container['name']}: missing {budget}")


def embedded_syntax(doc):
    if doc["kind"] != "ConfigMap":
        return
    for name, content in doc.get("data", {}).items():
        if not isinstance(content, str):
            continue
        if name.endswith(".py"):
            compile(content, name, "exec")
        elif name.endswith(".sh"):
            subprocess.run(["bash", "-n"], input=content, text=True, check=True)
        elif name.endswith((".js", ".mjs")):
            with tempfile.NamedTemporaryFile(suffix=Path(name).suffix, mode="w") as script:
                script.write(content)
                script.flush()
                run("node", "--check", script.name)


def resource_wiring(resources):
    """Resolve chart-owned references and the few separately installed owners."""
    by_name = {(doc["kind"], doc["metadata"].get("namespace", ""), doc["metadata"]["name"]): doc for doc in resources}
    # Vault and Argo CD are separate Helm releases; these roles are Kubernetes
    # built-ins. The fencing inventory belongs to the explicit validation fixture.
    external = {
        ("ServiceAccount", "infra", "vault"): {},
        ("Service", "infra", "vault"): {"spec": {"ports": [{"port": 8200}]}},
        ("Service", "infra", "argocd-server"): {"spec": {"ports": [{"port": 80}]}},
        ("ClusterRole", "", "cluster-admin"): {},
        ("ClusterRole", "", "system:auth-delegator"): {},
        ("Secret", "infra", "fixture-inventory"): {},
        # The separately installed Traefik chart owns this entrypoint middleware.
        ("Middleware", "infra", "forwarded-headers"): {},
        ("ConfigMap", "infra", "ingress-proxy-trust"): {"data": {"trustedIPs": "fixture-edge-cidrs"}},
    }
    for key, doc in external.items():
        by_name.setdefault(key, doc)
    for doc in resources:
        if doc["kind"] == "ExternalSecret":
            target = doc["spec"].get("target", {}).get("name", doc["metadata"]["name"])
            by_name[("Secret", doc["metadata"]["namespace"], target)] = doc

    def reference(kind, namespace, name, owner, key=None, optional=False):
        target = by_name.get((kind, namespace, name))
        require(optional or target is not None, f"{owner}: missing {kind} {namespace}/{name}")
        if target is not None and key and not optional:
            if target.get("kind") == "ExternalSecret":
                template = target["spec"].get("target", {}).get("template")
                keys = set((template or {}).get("data", {}))
                # ESO's default Replace policy emits template outputs only.
                # Dynamic template/provider keys cannot be inferred offline.
                if template and template.get("templateFrom"):
                    return target
                if template is None or template.get("mergePolicy", "Replace") == "Merge":
                    if target["spec"].get("dataFrom"):
                        return target
                    keys.update(entry["secretKey"] for entry in target["spec"].get("data", []))
            else:
                keys = set(target.get("data", {})) | set(target.get("stringData", {})) | set(target.get("binaryData", {}))
            require(key in keys, f"{owner}: missing {kind} key {namespace}/{name}:{key}")
        return target

    pods = []
    for doc in resources:
        kind = doc["kind"]
        namespace = doc["metadata"].get("namespace", "")
        name = doc["metadata"]["name"]
        owner = f"{kind} {namespace}/{name}"
        annotations = doc["metadata"].get("annotations") or {}
        middlewares = annotations.get("traefik.ingress.kubernetes.io/router.middlewares", "")
        for middleware in filter(None, middlewares.split(",")):
            prefix = f"{namespace}-"
            require(middleware.startswith(prefix) and middleware.endswith("@kubernetescrd"),
                    f"{owner}: middleware must belong to the route namespace: {middleware}")
            reference("Middleware", namespace, middleware[len(prefix):-len("@kubernetescrd")], owner)
        transport = annotations.get("traefik.ingress.kubernetes.io/service.serverstransport")
        if transport:
            prefix = f"{namespace}-"
            require(transport.startswith(prefix) and transport.endswith("@kubernetescrd"),
                    f"{owner}: invalid local ServersTransport: {transport}")
            reference("ServersTransport", namespace, transport[len(prefix):-len("@kubernetescrd")], owner)
        spec = doc.get("spec", {})
        if kind == "CronJob":
            spec = spec["jobTemplate"]["spec"]
        template = spec.get("template", {})
        if "spec" in template:
            pod = template["spec"]
            labels = template.get("metadata", {}).get("labels", {})
            pods.append((namespace, labels, pod, owner))
            if kind == "StatefulSet":
                reference("Service", namespace, spec["serviceName"], owner)
                for ordinal in range(spec.get("replicas", 1)):
                    pods.append((namespace, {**labels, "statefulset.kubernetes.io/pod-name": f"{name}-{ordinal}"}, pod, owner))
            account = pod.get("serviceAccountName", "default")
            if account != "default":
                reference("ServiceAccount", namespace, account, owner)
            for secret in pod.get("imagePullSecrets", []):
                reference("Secret", namespace, secret["name"], owner)
            volumes = {volume["name"] for volume in pod.get("volumes", [])}
            volumes.update(claim["metadata"]["name"] for claim in spec.get("volumeClaimTemplates", []))
            for volume in pod.get("volumes", []):
                if "persistentVolumeClaim" in volume:
                    reference("PersistentVolumeClaim", namespace, volume["persistentVolumeClaim"]["claimName"], owner)
                for source in [volume, *volume.get("projected", {}).get("sources", [])]:
                    for resource, field in (("ConfigMap", "configMap"), ("Secret", "secret")):
                        if field in source:
                            value = source[field]
                            target = value.get("name", value.get("secretName"))
                            for key in [None, *(item["key"] for item in value.get("items", []))]:
                                reference(resource, namespace, target, owner, key, value.get("optional", False))
            for container in pod.get("initContainers", []) + pod.get("containers", []):
                for mount in container.get("volumeMounts", []) + container.get("volumeDevices", []):
                    require(mount["name"] in volumes, f"{owner}/{container['name']}: missing volume {mount['name']}")
                for entry in container.get("env", []):
                    for resource, field in (("ConfigMap", "configMapKeyRef"), ("Secret", "secretKeyRef")):
                        value = entry.get("valueFrom", {}).get(field)
                        if value:
                            reference(resource, namespace, value["name"], owner, value["key"], value.get("optional", False))
                for entry in container.get("envFrom", []):
                    for resource, field in (("ConfigMap", "configMapRef"), ("Secret", "secretRef")):
                        if field in entry:
                            value = entry[field]
                            reference(resource, namespace, value["name"], owner, optional=value.get("optional", False))
        if kind in {"RoleBinding", "ClusterRoleBinding"}:
            role = doc["roleRef"]
            reference(role["kind"], namespace if role["kind"] == "Role" else "", role["name"], owner)
            for subject in doc.get("subjects", []):
                if subject["kind"] == "ServiceAccount":
                    reference("ServiceAccount", subject.get("namespace", namespace), subject["name"], owner)
        if kind in {"MutatingAdmissionPolicyBinding", "ValidatingAdmissionPolicyBinding"}:
            reference(kind.removesuffix("Binding"), "", spec["policyName"], owner)

    for doc in resources:
        kind, namespace, name = doc["kind"], doc["metadata"].get("namespace", ""), doc["metadata"]["name"]
        spec = doc.get("spec", {})
        owner = f"{kind} {namespace}/{name}"
        if kind == "Service" and spec.get("selector"):
            selector = spec["selector"]
            selected = [(pod, workload) for ns, labels, pod, workload in pods if ns == namespace
                        and all(labels.get(key) == value for key, value in selector.items())]
            # CloudNativePG supplies the primary pod after reconciling its Cluster.
            cluster = selector.get("cnpg.io/cluster")
            operator_owned = (("Cluster", namespace, cluster) in by_name
                              and selector == {"cnpg.io/cluster": cluster, "cnpg.io/instanceRole": "primary"})
            require(selected or operator_owned, f"{owner}: selector matches no workload: {selector}")
            for port in spec.get("ports", []):
                target = port.get("targetPort", port["port"])
                if isinstance(target, str):
                    for pod, workload in selected:
                        require(any(value.get("name") == target and value.get("protocol", "TCP") == port.get("protocol", "TCP")
                                    for container in pod.get("containers", []) for value in container.get("ports", [])),
                                f"{owner}: named port {target} missing on {workload}")
        if kind == "Ingress":
            require(spec.get("ingressClassName") == "traefik", f"{owner}: unexpected ingress controller")
            backends = [path["backend"] for rule in spec.get("rules", []) for path in rule.get("http", {}).get("paths", [])]
            if "defaultBackend" in spec:
                backends.append(spec["defaultBackend"])
            for backend in backends:
                if "service" in backend:
                    service = backend["service"]
                    target = reference("Service", namespace, service["name"], owner)
                    port = service["port"]
                    require(any(value.get("name") == port["name"] if "name" in port else value["port"] == port["number"]
                                for value in target["spec"].get("ports", [])), f"{owner}: missing Service port {service}")


def source_inputs():
    files = {ROOT / name for name in run("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0") if name}
    for path in sorted(files):
        if not path.is_file() or path.suffix == ".tgz":
            continue
        text = path.read_text()
        if path.suffix == ".py":
            compile(text, str(path), "exec")
        elif path.suffix in {".yaml", ".yml", ".values"} and "templates" not in path.parts:
            list(yaml.safe_load_all(text))
        elif path.suffix == ".json":
            json.loads(text)
        elif path.suffix == ".md":
            for target in re.findall(r"\[[^\]]*\]\(([^\s)]+)\)", text):
                if not target.startswith(("http:", "https:", "mailto:", "#")):
                    require((path.parent / target.split("#")[0]).exists(), f"{path.relative_to(ROOT)}: broken link {target}")
    contract = {}
    for line in (ROOT / "config/platform.env").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        require(re.fullmatch(r"[A-Z][A-Z0-9_]*=[^\s]*", line), "Invalid platform.env property")
        name, value = line.split("=", 1)
        require(name not in contract, f"Duplicate platform property: {name}")
        contract[name] = value
        if name.endswith("_MANIFESTS"):
            paths = value.split(",") if value else []
            require(len(paths) == len(set(paths)), f"Duplicate manifest in {name}")
            for manifest in paths:
                require((ROOT / "k8s" / manifest).is_file(), f"{name}: missing {manifest}")
    resources = []
    for group in GROUPS:
        for path in (ROOT / "k8s" / group).glob("*.yaml"):
            for doc in documents(path.read_text()):
                workload_policy(doc)
                for image in images(doc):
                    require(DIGEST.search(image), f"{path.name}: image must have an immutable digest: {image}")
                resources.append(doc)
    index(resources)
    hosts = {rule["host"].removesuffix(".__PUBLIC_DOMAIN__") for doc in resources if doc["kind"] == "Ingress"
             for rule in doc["spec"].get("rules", []) if rule.get("host", "").endswith(".__PUBLIC_DOMAIN__")}
    require(hosts == set(contract["DEFAULT_CLOUDFLARE_HOST_LABELS"].split(",")), "Ingress and public DNS inventories differ")
    for path in (ROOT / ".github/workflows").glob("*.y*ml"):
        for action in re.findall(r"^\s+(?:- )?uses:\s*(\S+)", path.read_text(), re.M):
            require(action.startswith("./") or re.search(r"@[a-f0-9]{40}$|@sha256:[a-f0-9]{64}$", action), f"Unpinned action: {action}")
    for path in (ROOT / "k8s/templates").iterdir():
        for method, target in re.findall(r'\.Files\.(Get|Glob) "([^"]+)"', path.read_text()):
            require(list((ROOT / "k8s").glob(target)), f"{path.name}: missing chart {method} input {target}")
    print("[PASS] Source syntax, documentation links, manifests and deployment policy", flush=True)


def render_profiles(output):
    # Explicit synthetic settings keep offline validation independent of the
    # operator's environment, kubeconfig and installed cluster identity.
    env = {key: value for key, value in os.environ.items() if key in {"PATH", "HOME", "TMPDIR"}}
    env.update(PYTHONDONTWRITEBYTECODE="1", KUBECONFIG="/dev/null")
    for legacy in ("bootstrap", "patched"):
        result = subprocess.run(["helm", "template", "bm-cluster", str(ROOT / "k8s"),
                                 "--values", str(ROOT / f"k8s/profiles/security-images-{legacy}.values")],
                                text=True, capture_output=True, env=env)
        require(result.returncode != 0 and "Legacy ingress/image settings require explicit migration" in result.stderr,
                f"Retired {legacy} profile did not stop reconciliation")
    profiles = [(ha, apps, None) for ha, apps in itertools.product((False, True), repeat=2)]
    profiles += [(True, True, phase) for phase in ("dynamic", "expanded", "active")]
    for ha, apps, phase in profiles:
        label = f"upstream-{'ha' if ha else 'single'}-{'corp' if apps else 'infra'}"
        if phase:
            label += f"-{phase}-fencing"
        stage = output / label
        flag = lambda value: str(value).lower()
        profile_env = dict(env, HIGH_AVAILABILITY_ENABLED=flag(ha))
        if phase:
            migration = yaml.safe_load((ROOT / "config/postgres-ha-values.yaml").read_text())
            migration["postgresHa"]["active"] = phase == "active"
            migration.update(yaml.safe_load((ROOT / "config/kafka-ha-values.yaml").read_text()))
            migration["kafkaHa"].update(phase=phase, clusterId="8ipNY9RxQtWkattTais5yQ")
            migration["nodeFencing"] = {"enabled": True, "inventorySecret": "fixture-inventory", "nodeNames": ["fixture-node"]}
            migration_file = output / f"{label}-values.json"
            migration_file.write_text(json.dumps(migration))
            profile_env["PLATFORM_HA_VALUES_FILE"] = str(migration_file)
        run("bash", str(ROOT / "scripts/render-cluster-config.sh"), "--output", str(stage),
            "--domain", "example.com", "--internal-domain", "internal.example.com",
            "--organization-name", "Example & Company", "--organization-slug", "example",
            "--gitlab-group", "example", "--gitlab-project", "bm-cluster",
            "--gitops-repository", "https://github.com/example/bm-cluster.git",
            "--cloudflare-access-team", "example", "--apps-enabled", flag(apps),
            "--descheduler-enabled", flag(apps), env=profile_env)
        application = yaml.safe_load((stage / "k8s/addons/bm-cluster-application.yaml").read_text())
        helm = application["spec"]["source"]["helm"]
        values = dict(helm["valuesObject"])
        for parameter in helm["parameters"]:
            target = values
            parts = parameter["name"].split(".")
            for part in parts[:-1]:
                target = target.setdefault(part, {})
            value = parameter["value"]
            if not parameter.get("forceString") and value in ("true", "false"):
                value = value == "true"
            target[parts[-1]] = value
        value_file = stage / "gitops-values.json"
        value_file.write_text(json.dumps(values))
        options = ["--namespace", "infra"]
        for profile in helm.get("valueFiles", []):
            options += ["--values", str(ROOT / "k8s" / profile)]
        options += ["--values", str(value_file)]
        run("helm", "lint", str(ROOT / "k8s"), "--strict", *options, env=env)
        rendered = run("helm", "template", "bm-cluster", str(ROOT / "k8s"), "--skip-tests", *options, env=env)
        require(set(TOKEN.findall(rendered)) <= {"__RUNNER_TOKEN__"}, f"{label}: unresolved deployment placeholders")
        runtime = index(documents(rendered))
        resource_wiring(list(runtime.values()))
        owned = {identity(doc) for block in rendered.split("\n---")
                 if "# Source: bm-cluster/templates/" in block for doc in documents(block)}
        require(any(doc["kind"] == "Namespace" and doc["metadata"]["name"] == "apps" for doc in runtime.values()), f"{label}: missing apps foundation")
        require(any(doc["kind"] == "Deployment" and doc["metadata"]["name"] == "odoo" for doc in runtime.values()) == apps, f"{label}: incorrect Odoo scope")
        for group in (*GROUPS, "ha"):
            for path in (stage / "k8s" / group).glob("*.yaml"):
                if (not apps and (group == "corp" or path.name in {"corp-namespace.yaml", "descheduler.yaml"})) or path.name == "descheduler-run-job.yaml":
                    continue
                for doc in documents(path.read_text()):
                    require(comparable(runtime.get(identity(doc))) == comparable(doc), f"{label}: installer/GitOps mismatch in {path.relative_to(stage)}: {identity(doc)}")
        for doc in runtime.values():
            # Vendored dependencies own their image schema. Enforce our digest
            # policy on platform-owned resources; lint renders dependencies too.
            if identity(doc) in owned:
                for image in images(doc):
                    require(DIGEST.search(image), f"{label}: unpinned rendered image {image}")
            if not ha and apps:
                embedded_syntax(doc)
        (output / f"{label}.yaml").write_text(rendered)
        print(f"[PASS] {label}: Helm lint, {len(runtime)} wired resources and installer/GitOps parity", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="Private temporary directory for rendered validation manifests")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True, mode=0o700)
    source_inputs()
    render_profiles(args.output)


if __name__ == "__main__":
    main()
