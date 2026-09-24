#!/usr/bin/env python3
"""Provision isolated application data on the existing shared platform.

Commands use the current central-platform kubeconfig. Credentials remain in
Vault/Kubernetes Secrets and are passed to subprocesses through stdin only.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import yaml

from lib.deployment_environments import InventoryError, load_inventory
from lib.onboarding_services import ServiceError, Services

IDENTIFIER = re.compile(r"[a-z][a-z0-9_]{0,62}\Z")
REDIS_SECRET = "application-redis-auth"
REDIS_ADMIN_PATH = "infra/application-redis"
REDIS_LEGACY_PATH = "infra/application-redis-legacy"
REDIS_LEGACY_SECRET = "application-redis-legacy-auth"
REDIS_LEGACY_USER = "legacy_platform"


def run(args, payload=None):
    try:
        result = subprocess.run(args, input=payload, capture_output=True, text=True, timeout=180)
        if result.returncode:
            raise ServiceError("A shared data operation failed; check service readiness and administrator access")
        return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        raise ServiceError("A shared data operation failed or timed out") from None


def kubectl(*args):
    value = run(["kubectl", "--request-timeout=30s", *args])
    return json.loads(value) if value else {}


def apply(document):
    command = ["replace"] if document.get("metadata", {}).get("resourceVersion") else ["apply", "--server-side", "--field-manager=application-data"]
    run(["kubectl", *command, "-f", "-"], json.dumps(document))


def identity(application, environment, database=None):
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,30}", application) or environment not in ("int", "uat", "prod"):
        raise ServiceError("Use an application DNS label and int, uat or prod")
    username = application.replace("-", "_") + "_" + environment
    database = database or username
    if not IDENTIFIER.fullmatch(database):
        raise ServiceError("Database names must be lowercase SQL identifiers")
    return {"application": application, "environment": environment, "username": username,
            "database": database, "prefix": application + "." + environment + ".",
            "cachePrefix": application + ":" + environment + ":"}


def credentials(api, path, expected):
    existing, version = Services._kv_get(api, path)
    if existing:
        if any(existing.get(key) != value for key, value in expected.items()):
            raise ServiceError("Existing Vault credentials belong to another application/data identity")
        if not re.fullmatch(r"[A-Za-z0-9_-]{32,}", existing.get("password", "")):
            raise ServiceError("Existing application credentials are invalid; perform an explicit credential migration")
        return existing
    value = {**expected, "password": secrets.token_urlsafe(36)}
    Services._kv_write(api, path, value, version)
    return value


def redis_acl_user(username, password, key_prefix):
    # Cache clears need KEYS for the selected prefix. ACL key rules also check
    # each DEL/GET/SET; KEYS/SCAN can still enumerate other prefixes' names.
    # Administrative/all-database commands are unavailable.
    return (f"user {username} on #{hashlib.sha256(password.encode()).hexdigest()} "
            f"~{key_prefix}* resetchannels -@all +get +mget +set +del +unlink +exists "
            "+expire +pexpire +ttl +pttl +ping +hello +select +keys +scan +client|setinfo +client|setname")


def redis_secret(admin, current=None, user_line=None):
    lines = [f"user default on #{hashlib.sha256(admin.encode()).hexdigest()} ~* &* +@all"]
    if current:
        try:
            previous = base64.b64decode(current["data"]["users.acl"], validate=True).decode().splitlines()
            for line in previous:
                if line.startswith("user default "):
                    continue
                scoped = re.fullmatch(r"user [a-z][a-z0-9_]+ on #[0-9a-f]{64} ~[a-z0-9:-]+\* resetchannels -@all [a-z+| ]+", line)
                legacy = re.fullmatch(r"user legacy_platform on #[0-9a-f]{64} ~\* &\* \+@all", line)
                if not scoped and not legacy:
                    raise ValueError()
                lines.append(line)
        except (KeyError, ValueError, UnicodeError):
            raise ServiceError("The managed Redis ACL Secret is malformed; preserve it and recover explicitly") from None
    if user_line:
        prefix = " ".join(user_line.split(" ")[:2]) + " "
        lines = [line for line in lines if not line.startswith(prefix)] + [user_line]
    metadata = {"name": REDIS_SECRET, "namespace": "infra"}
    if current and current.get("metadata", {}).get("resourceVersion"):
        metadata["resourceVersion"] = current["metadata"]["resourceVersion"]
    return {"apiVersion": "v1", "kind": "Secret", "metadata": metadata,
            "type": "Opaque", "stringData": {"auth": admin, "users.acl": "\n".join(lines) + "\n"}}


def redis_pods():
    service = kubectl("-n", "infra", "get", "service", "redis", "-o", "json")
    selector = service.get("spec", {}).get("selector", {})
    if selector == {"app": "redis"}:
        label = "app=redis"
    elif selector.get("app") == "redis-ha-haproxy" and selector.get("release") == "bm-cluster":
        label = "app=redis-ha,release=bm-cluster"
    else:
        raise ServiceError("Unrecognized canonical Redis selector; refusing to guess the data service")
    pods = kubectl("-n", "infra", "get", "pods", "-l", label, "-o", "json").get("items", [])
    if not pods or any(not any(c.get("type") == "Ready" and c.get("status") == "True"
                              for c in p.get("status", {}).get("conditions", [])) for p in pods):
        raise ServiceError("All shared Redis peers must be Ready")
    return [p["metadata"]["name"] for p in pods]


def redis_command(pod, password, *args):
    return run(["kubectl", "-n", "infra", "exec", "-i", pod, "-c", "redis", "--", "sh", "-ec",
                'IFS= read -r REDISCLI_AUTH; export REDISCLI_AUTH; exec redis-cli --raw "$@"',
                "redis-cli", *args], password + "\n")


def require_ready(inventory, admin):
    data = kubectl("-n", "infra", "get", "configmap", "application-data-access", "-o", "json").get("data", {})
    brokers = inventory["platform"]["services"]["kafka"].get("brokers", [])
    endpoints = ",".join(f"{broker['host']}:{broker['port']}" for broker in brokers)
    if not brokers or data.get("BM_KAFKA_REMOTE_BROKERS") != endpoints or data.get("BM_REDIS_AUTH_ENABLED") != "true":
        raise ServiceError("Apply the prepared application-data Helm profile with the inventory's broker endpoints first")
    cluster = kubectl("-n", "infra", "get", "statefulset", "kafka", "-o", "json")
    if cluster.get("spec", {}).get("replicas") != len(brokers) or cluster.get("status", {}).get("readyReplicas") != len(brokers):
        raise ServiceError("All declared Kafka brokers must be Ready and match the shared StatefulSet replica count")
    for pod in redis_pods():
        anonymous = run(["kubectl", "-n", "infra", "exec", pod, "-c", "redis", "--", "redis-cli", "--raw", "PING"])
        if not anonymous.startswith("NOAUTH") or redis_command(pod, admin, "PING") != "PONG":
            raise ServiceError("Shared Redis must reject anonymous clients and accept its managed platform credential")
    for broker in brokers:
        text = run(["kubectl", "-n", "infra", "exec", f"kafka-{broker['id']}", "--", "cat", "/etc/kafka/kafka.properties"])
        config = dict(line.split("=", 1) for line in text.splitlines() if "=" in line and not line.startswith("#"))
        expected = f"REMOTE://{broker['host']}:{broker['port']}"
        if (expected not in config.get("advertised.listeners", "").split(",") or
                "REMOTE:SASL_PLAINTEXT" not in config.get("listener.security.protocol.map", "").split(",") or
                config.get("listener.name.remote.sasl.enabled.mechanisms") != "SCRAM-SHA-512" or
                config.get("authorizer.class.name") != "org.apache.kafka.metadata.authorizer.StandardAuthorizer" or
                config.get("allow.everyone.if.no.acl.found") != "false" or config.get("super.users") != "User:ANONYMOUS"):
            raise ServiceError("Every Kafka broker must run the authenticated REMOTE listener and deny ungranted principals")


def postgres_target():
    helper = Path(__file__).parent / "lib/postgres-access.sh"
    return run(["bash", "-c", 'source "$1"; postgres_runtime_target infra', "application-data", str(helper)])


def postgres(sql, target, admin, database="postgres"):
    username, password = admin["username"], admin["password"]
    if not IDENTIFIER.fullmatch(username) or not IDENTIFIER.fullmatch(database) or not password or "\n" in password:
        raise ServiceError("Invalid platform PostgreSQL credentials")
    # The official image trusts loopback connections. Use the application-facing
    # Service so credential checks exercise network password authentication.
    return run(["kubectl", "-n", "infra", "exec", "-i", target, "--", "sh", "-ec",
                'IFS= read -r PGPASSWORD; export PGPASSWORD; export PGCONNECT_TIMEOUT=10; exec psql -X -qAt --set=ON_ERROR_STOP=1 -h postgres.infra.svc.cluster.local -U "$1" -d "$2"',
                "psql", username, database], password + "\n" + sql)


def database_sql(spec, password, *, existing_role=False, existing_database=False):
    # Identifiers and generated passwords are validated before interpolation.
    role, database = spec["username"], spec["database"]
    if not IDENTIFIER.fullmatch(role) or not IDENTIFIER.fullmatch(database) or not re.fullmatch(r"[A-Za-z0-9_-]{32,}", password):
        raise ServiceError("Invalid database identity or credential")
    statements = []
    if not existing_role:
        statements.append(f"CREATE ROLE {role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD '{password}';")
    if not existing_database:
        statements += [f"CREATE DATABASE {database} OWNER {role};"]
    statements += [f"REVOKE CONNECT ON DATABASE {database} FROM PUBLIC;", f"GRANT CONNECT ON DATABASE {database} TO {role};", f"\\connect {database}",
                   "REVOKE CREATE ON SCHEMA public FROM PUBLIC;", f"GRANT USAGE, CREATE ON SCHEMA public TO {role};"]
    return "\n".join(statements) + "\n"


def provision_database(api, spec):
    path = f"apps/{spec['application']}/{spec['environment']}/database"
    stored, _ = Services._kv_get(api, path)
    admin, _ = Services._kv_get(api, "infra/postgres")
    target = postgres_target()
    role, database = spec["username"], spec["database"]
    ownership = postgres(f"SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='{database}';\n", target, admin)
    existing_role = postgres(f"SELECT rolname || ':' || (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls OR NOT rolcanlogin OR EXISTS (SELECT FROM pg_auth_members WHERE member=pg_roles.oid))::text FROM pg_roles WHERE rolname='{role}';\n", target, admin)
    if (ownership and ownership != role) or (existing_role and existing_role != role + ":false"):
        raise ServiceError("Existing database/role ownership is incompatible; migrate it explicitly before adoption")
    if (ownership or existing_role) and not stored:
        raise ServiceError("Existing database/role has no matching scoped Vault credential; explicit adoption requires restoring that credential first")
    value = credentials(api, path, {"username": role, "database": database})
    postgres(database_sql(spec, value["password"], existing_role=bool(existing_role), existing_database=bool(ownership)), target, admin)
    if postgres("SELECT current_user;\n", target, value, database) != role:
        raise ServiceError("The scoped PostgreSQL credential could not authenticate to its database")


def resp(*parts):
    return f"*{len(parts)}\r\n" + "".join(f"${len(part.encode())}\r\n{part}\r\n" for part in parts)


def provision_redis(api, spec, admin):
    value = credentials(api, f"apps/{spec['application']}/{spec['environment']}/redis", {"username": spec["username"]})
    line = redis_acl_user(spec["username"], value["password"], spec["cachePrefix"])
    current = kubectl("-n", "infra", "get", "secret", REDIS_SECRET, "-o", "json")
    apply(redis_secret(admin, current, line))
    payload = resp("AUTH", admin) + resp("ACL", "SETUSER", spec["username"], "reset", *line.split(" ")[2:])
    for pod in redis_pods():
        run(["kubectl", "-n", "infra", "exec", "-i", pod, "-c", "redis", "--", "redis-cli", "--pipe"], payload)
        if redis_command(pod, value["password"], "--user", spec["username"], "PING") != "PONG":
            raise ServiceError("The application Redis credential could not authenticate on every shared peer")


def prepare_legacy_redis(api):
    """Stage compatibility credentials without disabling existing anonymous clients.

    This fixed user preserves the previous legacy trust boundary during rollout.
    Environment workloads never receive its credentials. The saved ACL file is
    ready for the subsequent authenticated profile activation.
    """
    admin = credentials(api, REDIS_ADMIN_PATH, {"username": "default"})
    legacy = credentials(api, REDIS_LEGACY_PATH, {"username": REDIS_LEGACY_USER})
    line = (f"user {REDIS_LEGACY_USER} on #{hashlib.sha256(legacy['password'].encode()).hexdigest()} "
            "~* &* +@all")
    current = kubectl("-n", "infra", "get", "secret", REDIS_SECRET, "--ignore-not-found", "-o", "json")
    apply(redis_secret(admin["password"], current or None, line))
    apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": REDIS_LEGACY_SECRET, "namespace": "infra"},
           "type": "Opaque", "stringData": legacy})
    for pod in redis_pods():
        anonymous = run(["kubectl", "-n", "infra", "exec", pod, "-c", "redis", "--", "redis-cli", "--raw", "PING"])
        if anonymous == "PONG":
            authentication = ""
        elif anonymous.startswith("NOAUTH"):
            if redis_command(pod, admin["password"], "PING") != "PONG":
                raise ServiceError("The current Redis administrator credential cannot authenticate")
            authentication = resp("AUTH", admin["password"])
        else:
            raise ServiceError("Cannot determine the current Redis authentication state")
        payload = authentication + resp("ACL", "SETUSER", REDIS_LEGACY_USER, "reset", *line.split(" ")[2:])
        run(["kubectl", "-n", "infra", "exec", "-i", pod, "-c", "redis", "--", "redis-cli", "--pipe"], payload)
        if redis_command(pod, legacy["password"], "--user", REDIS_LEGACY_USER, "PING") != "PONG":
            raise ServiceError("The legacy Redis credential could not authenticate on every shared peer")


def kafka(*args, payload=None):
    return run(["kubectl", "-n", "infra", "exec", "-i", "kafka-0", "--", *args], payload)


def kafka_acls(spec):
    principal = "User:" + spec["username"]
    base = ["kafka-acls", "--bootstrap-server", "localhost:9092", "--add", "--allow-principal", principal]
    return [base + ["--topic", spec["prefix"], "--resource-pattern-type", "prefixed", "--operation", "Read", "--operation", "Write", "--operation", "Describe", "--operation", "Create"],
            base + ["--group", spec["prefix"], "--resource-pattern-type", "prefixed", "--operation", "Read", "--operation", "Describe"],
            base + ["--cluster", "--operation", "IdempotentWrite"]]


def validate_kafka_acls(output, spec, *, complete=False, wildcard=False):
    expected = {("TOPIC", spec["prefix"], "PREFIXED", operation) for operation in ("READ", "WRITE", "DESCRIBE", "CREATE")}
    expected |= {("GROUP", spec["prefix"], "PREFIXED", operation) for operation in ("READ", "DESCRIBE")}
    expected.add(("CLUSTER", "kafka-cluster", "LITERAL", "IDEMPOTENT_WRITE"))
    found, resource = set(), None
    principal = "User:*" if wildcard else "User:" + spec["username"]
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        if line == f"ACLs for principal `{principal}`":
            continue
        match = re.fullmatch(r"Current ACLs for resource `ResourcePattern\(resourceType=([A-Z_]+), name=([^,]+), patternType=([A-Z_]+)\)`:", line)
        if match:
            resource = match.groups()
            continue
        rule = re.fullmatch(r"\(principal=([^,]+), host=([^,]+), operation=([A-Z_]+), permissionType=([A-Z_]+)\)", line)
        if not resource or not rule:
            raise ServiceError("Unrecognized Kafka ACL output; verify the managed principal before proceeding")
        actual, host, operation, permission = rule.groups()
        if actual != principal:
            raise ServiceError("Kafka returned ACLs for an unexpected principal")
        entry = (*resource, operation)
        if wildcard and permission == "DENY":
            continue
        if wildcard or entry not in expected or host != "*" or permission != "ALLOW":
            raise ServiceError("Kafka has incompatible or overbroad ACLs; explicitly migrate existing grants before provisioning this environment")
        found.add(entry)
    if complete and found != expected:
        raise ServiceError("Kafka did not retain the complete environment topic/group permissions")


def provision_kafka(api, spec):
    for principal, wildcard in (("User:*", True), ("User:" + spec["username"], False)):
        listing = kafka("kafka-acls", "--bootstrap-server", "localhost:9092", "--list", "--principal", principal)
        validate_kafka_acls(listing, spec, wildcard=wildcard)
    value = credentials(api, f"apps/{spec['application']}/{spec['environment']}/kafka", {"username": spec["username"]})
    # Keep the generated password out of process arguments and kubectl audit URLs.
    script = ('set -eu; umask 077; cfg=$(mktemp); trap \'rm -f "$cfg"\' EXIT; cat > "$cfg"; '
              'kafka-configs --bootstrap-server localhost:9092 --alter --entity-type users --entity-name "$1" --add-config-file "$cfg"')
    kafka("sh", "-ec", script, "scram", spec["username"],
          payload="SCRAM-SHA-512=iterations=8192,password=" + value["password"] + "\n")
    for args in kafka_acls(spec):
        kafka(*args)
    listing = kafka("kafka-acls", "--bootstrap-server", "localhost:9092", "--list", "--principal", "User:" + spec["username"])
    validate_kafka_acls(listing, spec, complete=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", "--inventory", dest="config", required=True)
    parser.add_argument("--application", default="devapp")
    parser.add_argument("--environment", choices=("int", "uat", "prod"))
    parser.add_argument("--adopt-existing-database")
    preparation = parser.add_mutually_exclusive_group()
    preparation.add_argument("--prepare-auth", action="store_true")
    preparation.add_argument("--prepare-legacy-auth", action="store_true",
                             help="Stage the compatibility user while preserving the current anonymous/default behavior")
    parser.add_argument("--output-values", type=Path, help="Write the public auth profile with broker endpoints from this inventory")
    parser.add_argument("--legacy-clients-migrated", action="store_true")
    parser.add_argument("--check", "--check-ready", action="store_true", dest="check")
    args = parser.parse_args()
    inventory = load_inventory(args.config, allow_partial=True)
    if args.output_values and not args.prepare_auth:
        raise ServiceError("--output-values belongs to --prepare-auth")
    if args.environment and args.environment not in inventory["environments"]:
        raise ServiceError("The selected application environment is not registered")
    installed = kubectl("-n", "infra", "get", "configmap", "bm-cluster-identity", "-o", "json").get("data", {})
    if (installed.get("PLATFORM_DOMAIN") != inventory["platform"]["domain"] or
            installed.get("INTERNAL_DNS_ZONE") != inventory["platform"]["internalDomain"]):
        raise ServiceError("The selected kubeconfig is not the inventory's shared platform")
    if inventory["platform"]["services"]["kafka"].get("securityProtocol") != "SASL_PLAINTEXT":
        raise ServiceError("The managed Kafka listener requires SASL_PLAINTEXT inside the shared cluster or registered encrypted transport")
    services = Services(None, kubectl, {"APPLICATION_NAME": args.application,
                        "GITLAB_PROJECT_ID": "data", "GITLAB_PROJECT_PATH": "application-data"})
    with services._vault() as api:
        if args.prepare_legacy_auth:
            prepare_legacy_redis(api)
            print("Legacy Redis credentials staged. Migrate existing trusted clients to application-redis-legacy-auth, then prepare and activate the authenticated profile.")
            return
        if args.prepare_auth:
            if not args.legacy_clients_migrated:
                raise ServiceError("Review and migrate existing Redis clients first; --legacy-clients-migrated acknowledges that prerequisite")
            admin = credentials(api, REDIS_ADMIN_PATH, {"username": "default"})
            current = kubectl("-n", "infra", "get", "secret", REDIS_SECRET, "--ignore-not-found", "-o", "json")
            apply(redis_secret(admin["password"], current or None))
            if args.output_values:
                profile = yaml.safe_load((Path(__file__).resolve().parents[1] / "config/application-data-values.yaml").read_text())
                profile["applicationData"]["kafkaBrokers"] = inventory["platform"]["services"]["kafka"]["brokers"]
                try:
                    descriptor = os.open(args.output_values, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(descriptor, "w") as output:
                        yaml.safe_dump(profile, output, sort_keys=False)
                except OSError:
                    raise ServiceError("Choose a new writable --output-values path; existing files are never overwritten") from None
            profile_path = args.output_values or "config/application-data-values.yaml with the inventory's Kafka brokers"
            print(f"Redis authentication Secret prepared. Complete the legacy client credential migration, then activate {profile_path}; authentication is not enabled by this command.")
            return
        admin, _ = Services._kv_get(api, REDIS_ADMIN_PATH)
        if not admin.get("password"):
            raise ServiceError("Prepare shared Redis authentication and apply the application-data Helm profile first")
        require_ready(inventory, admin["password"])
        if args.check:
            print("Shared Redis authentication and Kafka application listeners are ready.")
            return
        if not args.environment:
            raise ServiceError("Choose --environment int, uat or prod")
        if args.adopt_existing_database and args.environment != "prod":
            raise ServiceError("Existing database adoption is limited to an explicit production migration")
        spec = identity(args.application, args.environment, args.adopt_existing_database)
        provision_database(api, spec)
        provision_redis(api, spec, admin["password"])
        provision_kafka(api, spec)
        print(f"Shared data credentials reconciled for {args.application}/{args.environment}; database {spec['database']}.")


if __name__ == "__main__":
    try:
        main()
    except (ServiceError, InventoryError, ValueError, KeyError) as error:
        print("ERROR: " + (str(error) if isinstance(error, (ServiceError, InventoryError)) else "Malformed shared data configuration"), file=sys.stderr)
        sys.exit(1)
