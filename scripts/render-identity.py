#!/usr/bin/env python3
"""Render validated public identity into a private installation staging directory."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re

import yaml

spec = importlib.util.spec_from_file_location("platform_identity", Path(__file__).with_name("platform-identity.py"))
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


def render(root):
    settings = {key: os.environ[key] for key in identity.FIELDS}
    replacements = {"__" + key + "__": value for key, value in settings.items()}
    replacements.update({
        "__PUBLIC_DOMAIN__": settings["PLATFORM_DOMAIN"],
        "__ORGANIZATION_NAME_JSON__": json.dumps(settings["ORGANIZATION_NAME"]),
        "__GITLAB_GROUP_NAME_JSON__": json.dumps(settings["GITLAB_GROUP_NAME"]),
        "__CLOUDFLARE_ACCESS_IDP_NAME_JSON__": json.dumps(settings["CLOUDFLARE_ACCESS_IDP_NAME"]),
        "__PLATFORM_TITLE_JSON__": json.dumps(settings["ORGANIZATION_NAME"] + " Intranet"),
        "__APPS_ENABLED__": os.environ["INSTALL_APPS"],
        "__DESCHEDULER_ENABLED__": os.environ["INSTALL_DESCHEDULER"],
        "__HA_VALUES_OBJECT__": '{"highAvailabilityEnabled":false}',
    })
    pattern = re.compile("|".join(map(re.escape, replacements)))
    for base in (root / "k8s", root / "config"):
        for path in base.rglob("*"):
            if not path.is_file() or path.suffix == ".tgz" or "templates" in path.relative_to(root).parts:
                continue
            try:
                source = path.read_text()
            except UnicodeDecodeError:
                continue
            content = pattern.sub(lambda match: replacements[match[0]], source)
            unresolved = set(re.findall(r"__[A-Z][A-Z0-9_]+__", content)) - {"__RUNNER_TOKEN__"}
            if unresolved:
                raise ValueError(f"Unresolved placeholders in {path}: {sorted(set(unresolved))}")
            path.write_text(content)
    values_path = root / "k8s/values.yaml"
    values = yaml.safe_load(values_path.read_text())
    values.update({identity.FIELDS[key]: value for key, value in settings.items()})
    values.update(appsEnabled=os.environ["INSTALL_APPS"] == "true",
                  deschedulerEnabled=os.environ["INSTALL_DESCHEDULER"] == "true")
    # Dependency chart values are supplied explicitly: Helm does not template
    # arbitrary strings in values files.
    profile = "patched" if values["securityImagesEnabled"] else "bootstrap"
    image_values = yaml.safe_load((root / f"k8s/profiles/security-images-{profile}.values").read_text())["trivy-operator"]
    scanner = values["trivy-operator"]
    for key in ("image", "trivy"):
        if key == "image":
            scanner[key].update(image_values[key])
        else:
            scanner[key]["image"].update(image_values[key]["image"])
    registry = "registry." + settings["PLATFORM_DOMAIN"] if profile == "patched" else "docker.io"
    scanner["image"]["registry"] = scanner["trivy"]["image"]["registry"] = registry
    values_path.write_text(yaml.safe_dump(values, sort_keys=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    render(parser.parse_args().root)
