#!/usr/bin/env python3
"""Reconcile scoped application CI, including before deployment targets exist."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid
from types import SimpleNamespace
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts/lib"))
from application_delivery import ApplicationDelivery
from deployment_environments import validate_inventory, environment_context
from onboarding_services import ServiceError


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--application", required=True, help="Application name from its onboarding contract")
    parser.add_argument("--project", required=True, help="Existing GitLab namespace/project")
    parser.add_argument("--checkout", required=True, type=Path, help="Application checkout with its published configuration")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", args.application):
        parser.error("Application must be a lowercase Kubernetes name of at most 40 characters")
    if not os.environ.get("GITLAB_ADMIN_TOKEN"):
        # Reuse the installer's short-lived local administrator credential. Its
        # shell owns revocation even if Python exits with an error; no token is
        # printed, written into the checkout or passed in command arguments.
        command = '''set -euo pipefail
info() { printf '[INFO] %s\\n' "$*" >&2; }
fail() { printf '[ERROR] %s\\n' "$*" >&2; exit 1; }
source "$1"
shift
export GITLAB_ADMIN_TOKEN_NONINTERACTIVE=true
trap gitlab_revoke_ephemeral_admin_token EXIT
gitlab_acquire_admin_token
python3 "$@"
'''
        return subprocess.run(["bash", "-c", command, "application-delivery",
            str(ROOT / "scripts/lib/gitlab-admin-token.sh"), str(Path(__file__).resolve()), *sys.argv[1:]], check=False,
            env={**os.environ, "GITLAB_BOOTSTRAP_TOKEN_NAME": "bm-application-delivery-" + uuid.uuid4().hex}).returncode
    spec = importlib.util.spec_from_file_location("repository_operations", ROOT / "scripts/onboard-repositories.py")
    operations = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(operations)
    # Keep the API adapter's already-redacted operational errors concise.
    global OPERATION_ERRORS
    OPERATION_ERRORS = (operations.ReplicationError,)
    installed = operations.platform_context(required=True)
    with operations.gitlab_control_route():
        api = operations.API(os.environ.get("GITLAB_URL", installed["GITLAB_PUBLIC_URL"]).rstrip("/") + "/api/v4",
                             {"PRIVATE-TOKEN": os.environ["GITLAB_ADMIN_TOKEN"]})
        project = api.call("GET", "projects/" + quote(args.project, safe=""))
        context = {"APPLICATION_NAME": args.application, "GITLAB_PROJECT_ID": str(project["id"]),
            "GITLAB_PROJECT_PATH": project["path_with_namespace"], "PUBLIC_DOMAIN": installed["PLATFORM_DOMAIN"],
            "INTERNAL_DNS_ZONE": installed["INTERNAL_DNS_ZONE"],
            "GITLAB_REPOSITORY_URL": "http://gitlab." + installed["INTERNAL_DNS_ZONE"] + "/" + project["path_with_namespace"] + ".git"}
        kubectl = lambda *arguments, **kwargs: operations.Replicator.kubectl(None, *arguments, **kwargs)
        document = kubectl("get", "configmap", "deployment-environments", "-n", "infra", "--ignore-not-found", "-o", "json")
        targets = {}
        if document:
            inventory = validate_inventory(json.loads(document["data"]["environments.json"]), allow_partial=True)
            if (inventory["platform"]["domain"] != context["PUBLIC_DOMAIN"] or
                    inventory["platform"]["internalDomain"] != context["INTERNAL_DNS_ZONE"]):
                raise ServiceError("Deployment inventory belongs to another platform")
            targets = {name: environment_context(inventory, name) for name in inventory["environments"]}
        class Checkout:
            root = args.checkout.resolve()
            def git(self, *arguments):
                return subprocess.run(["git", "-C", str(self.root), *arguments], check=True,
                                      text=True, capture_output=True, timeout=30).stdout.strip()
        checkout = Checkout()
        contract = json.loads((checkout.root / "infra/onboarding.json").read_text())
        if contract.get("version") != 2:
            raise ServiceError("Scoped application delivery requires onboarding contract version 2")
        environments = SimpleNamespace(onboarding=SimpleNamespace(api=api, kubectl=kubectl),
            context=context, name=args.application, targets=targets, checkout=checkout, contract=contract)
        ApplicationDelivery(environments).reconcile()
    print("Scoped project runners are ready; registered deployment targets: " + (", ".join(sorted(targets)) or "none (CI only)"))
    return 0


if __name__ == "__main__":
    OPERATION_ERRORS = ()
    try:
        raise SystemExit(main())
    except (ServiceError, ValueError, OSError, subprocess.SubprocessError) + OPERATION_ERRORS as error:
        print("Application delivery configuration failed: " + str(error), file=sys.stderr)
        raise SystemExit(1) from None
