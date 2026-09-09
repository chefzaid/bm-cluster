#!/usr/bin/env python3
"""Select public bootstrap or patched images without making cluster changes."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

import yaml


def select_enabled(requested, domain):
    if requested != "auto":
        return requested == "true"
    try:
        result = subprocess.run(
            ["kubectl", "--request-timeout=5s", "get", "application", "bm-cluster",
             "--namespace=infra", "--output=json"],
            capture_output=True, text=True, timeout=10, check=True,
        )
        app = json.loads(result.stdout)
        helm = app.get("spec", {}).get("source", {}).get("helm", {})
        parameters = {p["name"]: p["value"] for p in helm.get("parameters", [])}
        if parameters.get("publicDomain") != domain:
            return False
        if "securityImagesEnabled" in parameters:
            return parameters["securityImagesEnabled"].lower() == "true"
        return "profiles/security-images-bootstrap.values" not in helm.get("valueFiles", [])
    except FileNotFoundError:
        return False
    except subprocess.CalledProcessError as error:
        if any(text in error.stderr for text in ("NotFound", "doesn't have a resource type", "localhost:8080", "no configuration has been provided")):
            return False
        raise RuntimeError("Cannot detect the security image profile; retry or explicitly set SECURITY_IMAGES_ENABLED=true/false") from error
    except (subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        raise RuntimeError("Cannot detect the security image profile; retry or explicitly set SECURITY_IMAGES_ENABLED=true/false") from error


def image_parts(image):
    base, separator, digest = image.partition("@")
    repository, colon, tag = base.rpartition(":")
    if not colon or "/" in tag:
        repository, tag = base, "latest"
    return repository, tag + (separator + digest if separator else "")


def render(root, enabled):
    catalog = json.loads((root / "k8s/security-images.json").read_text())
    profile = "patched" if enabled else "bootstrap"
    # This runs before the ordinary domain-placeholder renderer.
    scanner_registry = "registry.__PUBLIC_DOMAIN__" if enabled else "docker.io"
    private_image = re.compile(
        r"registry\.__PUBLIC_DOMAIN__/swirlit/bm-cluster/security/([a-z][a-z0-9-]*)(?::[^\s@\"']+)?@sha256:[a-f0-9]{64}"
    )
    for path in (root / "k8s").rglob("*.yaml"):
        content = path.read_text()
        if not enabled and "templates" not in path.parts:
            content = private_image.sub(lambda match: catalog["upstreams"][match[1]], content)
        content = content.replace("__SECURITY_IMAGE_PROFILE__", profile)
        content = content.replace("__SECURITY_SCANNER_REGISTRY__", scanner_registry)
        content = content.replace("__SECURITY_PULL_SECRETS__", '["platform-registry-auth"]' if enabled else '[]')
        path.write_text(content)
    values = root / "k8s/values.yaml"
    content = values.read_text().replace(
        "securityImagesEnabled: true", "securityImagesEnabled: " + str(enabled).lower()
    )
    values.write_text(content)
    vault_path = root / "config/vault-values.yaml"
    vault = yaml.safe_load(vault_path.read_text())
    image = catalog.get("vaultPatchedImage") if enabled else catalog["upstreams"]["vault"]
    if not image:
        raise ValueError("Patched Vault image is missing from the security image catalog")
    repository, tag = image_parts(image)
    vault.setdefault("server", {})["image"] = {"repository": repository, "tag": tag}
    vault.setdefault("global", {})["imagePullSecrets"] = (
        [{"name": "platform-registry-auth"}] if enabled else []
    )
    vault_path.write_text(yaml.safe_dump(vault, sort_keys=False))
    ingress_path = root / "config/ingress-nginx-values.yaml"
    ingress = yaml.safe_load(ingress_path.read_text())
    controller = ingress["controller"]
    initializer = next(c for c in controller["extraInitContainers"] if c["name"] == "prepare-nginx-dirs")
    image = initializer["image"] if enabled else catalog["upstreams"]["ingress-nginx"]
    initializer["image"] = image
    repository, version = image_parts(image)
    tag, _, digest = version.partition("@")
    # Null out the chart's registry/image defaults when using a full repository.
    controller["image"] = {"registry": None, "image": None, "repository": repository,
                           "tag": tag, "digest": digest}
    ingress["imagePullSecrets"] = [{"name": "platform-registry-auth"}] if enabled else []
    # The public image has file capabilities on NGINX/dumb-init. The rebuild
    # removes them; both profiles use the same non-root, read-only directories.
    controller["containerSecurityContext"]["capabilities"] = {
        "drop": ["ALL"], "add": [] if enabled else ["NET_BIND_SERVICE"],
    }
    ingress_path.write_text(yaml.safe_dump(ingress, sort_keys=False))
    print(f"[INFO] Security image profile: {profile}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--enabled", choices=("auto", "true", "false"), default="auto")
    args = parser.parse_args()
    render(args.root, select_enabled(args.enabled, args.domain))


if __name__ == "__main__":
    main()
