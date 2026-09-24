#!/usr/bin/env python3
"""Preserve durable availability and shared-data settings before reconciliation."""
import argparse
import copy
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


def shared_data_profile(previous, supplied):
    previous_data = previous.get("applicationData", {})
    if not isinstance(previous_data, dict):
        raise ValueError("Stored applicationData must be a mapping")
    selected = copy.deepcopy(previous_data)
    if "applicationData" in supplied:
        if not isinstance(supplied["applicationData"], dict):
            raise ValueError("applicationData must be a mapping")
        selected.update(supplied["applicationData"])
    if not selected:
        return {}
    if set(selected) - {"enabled", "kafkaBrokers"} or type(selected.get("enabled")) is not bool:
        raise ValueError("applicationData requires boolean enabled and the managed Kafka broker list")
    if previous_data.get("enabled") and not selected["enabled"]:
        raise ValueError("Shared application authentication is enabled; refusing an implicit downgrade")
    if not selected["enabled"]:
        return {"applicationData": selected}
    brokers = selected.get("kafkaBrokers")
    if not isinstance(brokers, list) or len(brokers) not in (1, 3):
        raise ValueError("Shared application access requires one or three private Kafka broker endpoints")
    # Keep only the managed auth fragment; credentials are never Helm inputs.
    redis = copy.deepcopy(previous.get("redis-ha", {}))
    def merge(target, source):
        for key, value in source.items():
            if isinstance(value, dict) and isinstance(target.get(key), dict):
                merge(target[key], value)
            else:
                target[key] = copy.deepcopy(value)
    if not isinstance(redis, dict) or not isinstance(supplied.get("redis-ha", {}), dict):
        raise ValueError("Redis authentication settings must be a mapping")
    merge(redis, supplied.get("redis-ha", {}))
    redis_config = redis.get("redis", {})
    if not isinstance(redis_config, dict) or not isinstance(redis_config.get("config", {}), dict):
        raise ValueError("Redis authentication configuration must be a mapping")
    if (redis.get("auth") is not True or redis.get("existingSecret") != "application-redis-auth" or
            redis.get("authKey") != "auth" or redis_config.get("config", {}).get("aclfile") != "/etc/redis-acl/users.acl"):
        raise ValueError("Preserve the complete authenticated Redis profile from config/application-data-values.yaml")
    mounts = redis_config.get("extraVolumeMounts", [])
    volumes = redis.get("extraVolumes", [])
    if not isinstance(mounts, list) or not isinstance(volumes, list):
        raise ValueError("Redis ACL volumes and mounts must be lists")
    if ({"name": "application-redis-acl", "mountPath": "/etc/redis-acl", "readOnly": True} not in mounts or
            {"name": "application-redis-acl", "secret": {"secretName": "application-redis-auth"}} not in volumes):
        raise ValueError("The authenticated Redis ACL volume and mount must be preserved")
    return {"applicationData": selected, "redis-ha": {
        "auth": True, "existingSecret": "application-redis-auth", "authKey": "auth",
        "redis": {"config": {"aclfile": redis_config["config"]["aclfile"]}, "extraVolumeMounts": mounts},
        "extraVolumes": volumes}}


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
    profile.update(shared_data_profile(previous or {}, supplied))
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
    if profile["highAvailabilityEnabled"] or profile.get("postgresHa") or profile.get("kafkaHa") or profile.get("applicationData", {}).get("enabled"):
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
