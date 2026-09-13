#!/usr/bin/env python3
"""Read public installed identity without reading credentials or evaluating code."""
import argparse
import json
import os
import subprocess
import sys

FIELDS = {
    "PLATFORM_DOMAIN": "publicDomain", "INTERNAL_DNS_ZONE": "internalDnsZone",
    "ORGANIZATION_NAME": "organizationName", "ORGANIZATION_SLUG": "organizationSlug",
    "GITLAB_GROUP_PATH": "gitlabGroupPath", "GITLAB_GROUP_NAME": "gitlabGroupName",
    "GITLAB_PROJECT_NAME": "gitlabProjectName", "KEYCLOAK_REALM": "keycloakRealm",
    "TLS_SECRET_NAME": "tlsSecretName", "SONAR_ALM_SETTING": "sonarAlmSetting",
    "CLOUDFLARE_ACCESS_IDP_NAME": "cloudflareAccessIdpName",
    "CLOUDFLARE_ACCESS_TEAM_NAME": "cloudflareAccessTeamName",
    "GITOPS_REPOSITORY_URL": "gitopsRepositoryURL",
}


def discover():
    try:
        result = subprocess.run(
            ["kubectl", "--request-timeout=5s", "get", "configmap", "bm-cluster-identity",
             "-n", "infra", "--ignore-not-found", "-o", "json"],
            capture_output=True, text=True, timeout=10, check=True,
        )
        data = json.loads(result.stdout or "{}").get("data", {})
    except FileNotFoundError:
        return {}
    except subprocess.CalledProcessError as error:
        if any(message in error.stderr for message in ("NotFound", "localhost:8080", "no configuration has been provided")):
            return {}
        raise RuntimeError("Cannot read installed platform identity; restore cluster access before reconciliation") from None
    except (subprocess.TimeoutExpired, ValueError):
        raise RuntimeError("Cannot read installed platform identity; restore cluster access before reconciliation") from None
    if os.environ.get("PLATFORM_DOMAIN") and data.get("PLATFORM_DOMAIN") != os.environ["PLATFORM_DOMAIN"]:
        return {}
    return {key: value for key, value in data.items() if key in FIELDS and isinstance(value, str)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--discover", action="store_true")
    parser.add_argument("--pairs", action="store_true")
    parser.add_argument("--json", help=argparse.SUPPRESS)
    args = parser.parse_args()
    values = json.loads(args.json) if args.json else (discover() if args.discover else {})
    values.update({key: os.environ[key] for key in FIELDS if os.environ.get(key)})
    if not os.environ.get("TLS_SECRET_NAME") and os.environ.get("CLOUDFLARE_TLS_SECRET_NAME"):
        values["TLS_SECRET_NAME"] = os.environ["CLOUDFLARE_TLS_SECRET_NAME"]
    if args.pairs:
        for key, value in values.items():
            sys.stdout.write(key + "\0" + value + "\0")
    else:
        print(json.dumps(values))
