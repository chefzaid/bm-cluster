#!/usr/bin/env python3
"""Compare rendered ESO charts, retaining non-Vault schema changes for review."""
import argparse
import json
from pathlib import Path

import yaml


def documents(path):
    loader = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
    result = {}
    for obj in yaml.load_all(path.read_text(), Loader=loader):
        if not obj:
            continue
        key = (obj["kind"], obj["metadata"].get("namespace", ""), obj["metadata"]["name"])
        if key in result:
            raise ValueError(f"Duplicate rendered object: {key}")
        result[key] = obj
    return result


def schema_changes(old, new, path=""):
    changes = []
    if isinstance(old, dict) and isinstance(new, dict):
        for key in sorted(old.keys() - new.keys() - {"description"}):
            changes.append({"type": "removed", "path": path + "/" + key})
        for key in sorted(new.keys() - old.keys() - {"description"}):
            changes.append({"type": "added", "path": path + "/" + key})
        for key in sorted((old.keys() & new.keys()) - {"description"}):
            changes.extend(schema_changes(old[key], new[key], path + "/" + key))
    elif isinstance(old, list) and isinstance(new, list) and len(old) == len(new):
        for index, (before, after) in enumerate(zip(old, new)):
            changes.extend(schema_changes(before, after, path + "/" + str(index)))
    elif old != new:
        changes.append({"type": "changed", "path": path, "before": old, "after": new})
    return changes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("old", type=Path)
    parser.add_argument("new", type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    old, new = documents(args.old), documents(args.new)
    removed = old.keys() - new.keys()
    if removed:
        raise ValueError(f"Existing chart resources were removed: {sorted(removed)}")
    changes, crds, deployments = [], [], []
    for key in sorted(old):
        before, after = old[key], new[key]
        if key[0] == "CustomResourceDefinition":
            versions = lambda obj: [(v["name"], v.get("served"), v.get("storage"))
                                    for v in obj["spec"]["versions"]]
            if versions(before) != versions(after):
                raise ValueError(f"Served/storage API versions changed: {key[2]}")
            delta = schema_changes(before["spec"], after["spec"], key[2])
            if any("/provider/properties/vault/" in change["path"]
                   or change["path"].endswith("/provider/properties/vault") for change in delta):
                raise ValueError(f"Vault provider schema changed: {key[2]}")
            changes.extend(delta)
            crds.append(key[2])
        elif key[0] == "Deployment":
            spec = after["spec"]["template"]["spec"]
            pod_security = spec.get("securityContext", {})
            for container in spec["containers"]:
                security = {**pod_security, **container.get("securityContext", {})}
                valid = (security.get("runAsUser") == 10001
                         and security.get("runAsGroup") == 10001
                         and security.get("runAsNonRoot") is True
                         and security.get("readOnlyRootFilesystem") is True
                         and security.get("allowPrivilegeEscalation") is False
                         and "ALL" in security.get("capabilities", {}).get("drop", [])
                         and security.get("seccompProfile", {}).get("type") == "RuntimeDefault")
                if not valid:
                    raise ValueError(f"Expected security settings missing from {key[2]}/{container['name']}")
                for bound in ("requests", "limits"):
                    resources = container.get("resources", {}).get(bound, {})
                    if not resources.get("cpu") or not resources.get("memory"):
                        raise ValueError(f"CPU/memory {bound} missing from {key[2]}")
            deployments.append(key[2])
    result = {
        "status": "structural checks passed; other schema changes require review",
        "objectsBefore": len(old), "objectsAfter": len(new),
        "crds": crds, "hardenedDeployments": deployments,
        "addedObjects": sorted(new.keys() - old.keys()),
        "schemaChangesExcludingDescriptions": changes,
    }
    args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Verified {len(crds)} CRD API versions and {len(deployments)} hardened Deployments; "
          f"retained {len(changes)} other schema changes for review")


if __name__ == "__main__":
    main()
