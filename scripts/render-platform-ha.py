#!/usr/bin/env python3
"""Use the GitOps Helm templates for the installer's HA manifests as well."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[1]


def identity(resource):
    meta = resource.get("metadata", {})
    return resource.get("apiVersion"), resource.get("kind"), meta.get("namespace", ""), meta.get("name")


def merge(base, override):
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--values", type=Path)
    args = parser.parse_args()
    values = yaml.safe_load((args.root / "k8s/values.yaml").read_text())
    values.update(publicDomain=os.environ["PLATFORM_DOMAIN"],
                  internalDnsZone=os.environ["INTERNAL_DNS_ZONE"],
                  gitopsRepositoryURL=os.environ["GITOPS_REPOSITORY_URL"],
                  cloudflareAccessTeamName=os.environ["CLOUDFLARE_ACCESS_TEAM_NAME"],
                  appsEnabled=os.environ.get("INSTALL_APPS", "true") == "true",
                  deschedulerEnabled=os.environ.get("INSTALL_DESCHEDULER", "true") == "true")
    if args.values:
        merge(values, yaml.safe_load(args.values.read_text()))
    enabled = os.environ.get("HIGH_AVAILABILITY_ENABLED", "false") == "true"
    values["highAvailabilityEnabled"] = enabled
    with tempfile.TemporaryDirectory(prefix="bm-ha-render.") as directory:
        value_file = Path(directory) / "values.json"

        def render(enabled, templates=()):
            value_file.write_text(json.dumps({**values, "highAvailabilityEnabled": enabled}))
            command = ["helm", "template", "bm-cluster", str(ROOT / "k8s"),
                       "--namespace", "infra", "--skip-tests", "--values", str(value_file)]
            for template in templates:
                command += ["--show-only", template]
            result = subprocess.run(command, text=True, capture_output=True, check=True)
            return [doc for doc in yaml.safe_load_all(result.stdout) if doc and doc.get("kind")]

        baseline = {identity(doc) for doc in render(False)}
        desired = {identity(doc): doc for doc in render(enabled)}
        migrated_templates = [f"templates/{name}-ha.yaml" for name in ("postgres", "kafka")
                              if values.get(name + "Ha", {}).get("enabled")]
        migrated = {identity(doc) for doc in render(enabled, migrated_templates)} if migrated_templates else set()
    existing = set()
    for group in ("base", "datastores", "platform", "apps", "corp", "addons"):
        for path in (args.root / "k8s" / group).glob("*.yaml"):
            original = list(yaml.safe_load_all(path.read_text()))
            transformed = []
            for doc in original:
                if not doc:
                    continue
                key = identity(doc)
                existing.add(key)
                transformed.append(desired.get(key, doc))
            path.write_text(yaml.safe_dump_all(transformed, sort_keys=False))
    extra = [doc for key, doc in desired.items() if key not in existing and (key not in baseline or key in migrated)]
    # Migration helpers own initial bootstrap and cutover; ordinary reconciles
    # must also retain/update their verified Cluster, startup config and PDBs.
    extra_dir = args.root / "k8s/ha"
    extra_dir.mkdir(exist_ok=True)
    (extra_dir / "platform.yaml").write_text(yaml.safe_dump_all(extra, sort_keys=False))
    (args.root / "k8s/values.yaml").write_text(yaml.safe_dump(values, sort_keys=False))


if __name__ == "__main__":
    main()
