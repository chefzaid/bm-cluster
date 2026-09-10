#!/usr/bin/env python3
"""Read durable HA settings before installers render or mutate workloads."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import yaml


def state(name):
    result = subprocess.run(["kubectl", "-n", "infra", "get", "configmap", name,
                             "--ignore-not-found", "-o", "json"],
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout).get("data", {}) if result.stdout.strip() else {}


def application_values():
    crd = subprocess.run(["kubectl", "get", "crd", "applications.argoproj.io",
                          "--ignore-not-found", "-o", "name"],
                         text=True, capture_output=True, check=True)
    if not crd.stdout.strip():
        return {}
    result = subprocess.run(["kubectl", "-n", "infra", "get", "application", "bm-cluster",
                             "--ignore-not-found", "-o", "json"],
                            text=True, capture_output=True, check=True)
    app = json.loads(result.stdout) if result.stdout.strip() else {}
    return app.get("spec", {}).get("source", {}).get("helm", {}).get("valuesObject", {})


def resolve(topology, postgres, requested, supplied=None, kafka=None, previous=None):
    stored = topology.get("highAvailabilityEnabled", "false")
    if stored not in ("true", "false") or requested not in ("", "true", "false"):
        raise ValueError("HIGH_AVAILABILITY_ENABLED and stored mode must be true or false")
    if stored == "true" and requested == "false":
        raise ValueError("HA is already enabled; refusing an implicit downgrade")
    mode = requested or stored
    profile = {"highAvailabilityEnabled": mode == "true"}
    supplied = supplied or {}
    if not isinstance(supplied, dict):
        raise ValueError("PLATFORM_HA_VALUES_FILE must contain a mapping")
    for label, key, record in (("PostgreSQL", "postgresHa", postgres),
                               ("Kafka", "kafkaHa", kafka or {})):
        phase = record.get("phase", "")
        if phase and phase != "active":
            raise ValueError(f"{label} HA migration is unfinished; finish or abort it before running the installer")
        if phase == "active":
            profile[key] = json.loads(record[key])
        if key in supplied and supplied[key] != profile.get(key):
            raise ValueError(f"The supplied {label} profile differs from the verified cutover record")
    if mode == "true" and not (profile.get("postgresHa", {}).get("enabled") and profile.get("postgresHa", {}).get("active")):
        raise ValueError("Complete the PostgreSQL HA prepare/migrate (or fresh)/cutover workflow first; see docs/high-availability.md")
    if mode == "true" and not (profile.get("kafkaHa", {}).get("enabled") is True and
                               profile["kafkaHa"].get("phase") == "active" and
                               not profile["kafkaHa"].get("bootstrap", False)):
        raise ValueError("Complete the Kafka HA migration and verification first; see docs/kafka-ha.md")
    fencing = supplied.get("nodeFencing", (previous or {}).get("nodeFencing"))
    if fencing is not None:
        if not isinstance(fencing, dict) or type(fencing.get("enabled")) is not bool:
            raise ValueError("nodeFencing.enabled must be a boolean")
        if fencing["enabled"] and (not fencing.get("inventorySecret") or
                                   not fencing.get("nodeNames")):
            raise ValueError("Enabled node fencing requires inventorySecret and explicit nodeNames")
        profile["nodeFencing"] = fencing
    return profile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    supplied_file = os.environ.get("PLATFORM_HA_VALUES_FILE", "")
    supplied = yaml.safe_load(Path(supplied_file).read_text()) if supplied_file else None
    profile = resolve(state("bm-cluster-topology"), state("postgres-ha-state"),
                      os.environ.get("HIGH_AVAILABILITY_ENABLED", ""), supplied,
                      state("kafka-ha-state"), application_values())
    if profile["highAvailabilityEnabled"] or profile.get("postgresHa") or profile.get("kafkaHa"):
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            json.dump(profile, output)
    print(str(profile["highAvailabilityEnabled"]).lower())


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        sys.exit(1)
