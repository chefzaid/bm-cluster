#!/usr/bin/env python3
"""Explicit, offline PostgreSQL HA preparation/migration. Never deletes a PVC.

Run --help and read docs/postgres-ha.md before use. All SQL results, credentials
and dumps stay in the private state directory. A failed migration leaves the old
database fenced; it never silently reconnects writers to an uncertain copy.
"""

import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time

import yaml

ROOT = Path(__file__).resolve().parents[1]
CLUSTER = "postgres-ha"
NAMESPACE = "infra"
SELECTOR = {"cnpg.io/cluster": CLUSTER, "cnpg.io/instanceRole": "primary"}
RESERVED_ROLES = {"postgres", "streaming_replica", "cnpg_pooler_pgbouncer", "cnpg_metrics_exporter"}
FENCE = "host all all all reject\nhost replication all all reject\n"
FORMAT_SQL = "SET TIME ZONE 'UTC'; SET DateStyle='ISO, YMD'; SET intervalstyle='postgres'; SET bytea_output='hex'; SET extra_float_digits=3;\n"
ROLE_SQL = """SELECT coalesce(json_agg(r ORDER BY rolname),'[]') FROM (
SELECT rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,
rolreplication,rolbypassrls,rolconnlimit,rolpassword,rolvaliduntil
FROM pg_authid WHERE rolname !~ '^pg_') r;"""
DATABASE_SQL = """SELECT json_agg(r ORDER BY datname) FROM (
SELECT datname,pg_get_userbyid(datdba) AS owner,encoding,datlocprovider,
datcollate,datctype,datlocale,datconnlimit,datallowconn,datacl::text,
pg_tablespace.spcname AS tablespace FROM pg_database JOIN pg_tablespace
ON pg_tablespace.oid=dattablespace WHERE NOT datistemplate) r;"""


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def ident(value):
    return '"' + value.replace('"', '""') + '"'


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def normalize_schema(data):
    # pg_dump uses a random psql restrict key and emits tool/server patch versions.
    return b"\n".join(line for line in data.splitlines()
                      if not line.startswith((b"\\restrict ", b"\\unrestrict ",
                                              b"-- Dumped from ", b"-- Dumped by ")))


def restore_grantors(sql, source_bootstrap):
    # PostgreSQL 16+ checks GRANTED BY against the executing grantor's rights.
    # Restore each pg_dumpall membership as its original grantor, then return to
    # the authenticated operator superuser. Identifiers come from pg_dumpall's
    # SQL quoting; names containing newlines are rejected during preflight.
    def replace(match):
        grantor = match[2]
        decoded = grantor[1:-1].replace('""', '"') if grantor.startswith('"') else grantor
        if decoded == source_bootstrap:
            grantor = "postgres"
        return ("SET SESSION AUTHORIZATION " + grantor + ";\nGRANT " + match[1] +
                " GRANTED BY " + grantor + ";\nRESET SESSION AUTHORIZATION;")
    return re.sub(r"^GRANT (.*) GRANTED BY (.*);$", replace, sql, flags=re.MULTILINE)


class Migration:
    def __init__(self, args):
        self.args = args
        self.directory = Path(args.state_dir).absolute()
        require(not self.directory.is_symlink(), "State directory cannot be a symlink")
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        current = self.directory.stat()
        require(current.st_uid == os.geteuid() and stat.S_IMODE(current.st_mode) == 0o700,
                "State directory must be owned by the current user with mode 0700")
        require(all(not part.is_symlink() for part in [self.directory, *self.directory.parents]),
                "State directory ancestry cannot contain symlinks")
        self.kubectl = shlex.split(os.environ.get("KUBECTL", "kubectl"))
        self.state_path = self.directory / "state.json"
        require(not self.state_path.is_symlink(), "State file cannot be a symlink")
        self.lock = os.fdopen(os.open(self.directory / ".migration.lock",
                                     os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600), "w")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.lock.close()
            raise RuntimeError("Another PostgreSQL migration command is using this journal") from None
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {}

    def write(self, name, value):
        path = self.directory / name
        require(path.parent == self.directory and not path.is_symlink(), "Unsafe state filename")
        data = value if isinstance(value, bytes) else json.dumps(value, indent=2).encode() + b"\n"
        descriptor, temporary = tempfile.mkstemp(prefix="." + name + ".", dir=self.directory)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
            directory = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            Path(temporary).unlink(missing_ok=True)
        return path

    def record(self, **changes):
        self.state.update(changes)
        self.write("state.json", self.state)

    def publish(self, phase, profile):
        self.apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "postgres-ha-state", "namespace": NAMESPACE},
                    "data": {"phase": phase, "postgresHa": json.dumps(profile, sort_keys=True),
                             "clusterUid": self.state["clusterUid"]}})

    def run(self, command, data=None, output=None, input_file=None):
        with (self.directory / "command-error.log").open("ab") as errors:
            result = subprocess.run(command, input=data, stdin=input_file, stdout=output or subprocess.PIPE,
                                    stderr=errors, check=False)
        require(result.returncode == 0, "Command failed; inspect private command-error.log. No automatic rollback performed.")
        return result.stdout

    def kube(self, *args, data=None):
        return self.run([*self.kubectl, *args], data=data)

    def get(self, kind, name=None, namespace=NAMESPACE):
        args = ["get", kind, *( [name] if name else []), "-o", "json", "--ignore-not-found"]
        if namespace:
            args += ["-n", namespace]
        data = self.kube(*args)
        return json.loads(data) if data.strip() else None

    def apply(self, resource):
        self.kube("apply", "-f", "-", data=json.dumps(resource).encode())

    def sql(self, pod, database, query, source=False):
        if source:
            command = ["sh", "-ceu", 'exec psql -X -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$1"', "sh", database]
        else:
            command = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", database]
        return self.kube("exec", "-i", "-n", NAMESPACE, pod, "-c", "postgres", "--", *command,
                         data=(FORMAT_SQL + query).encode()).decode().strip()

    def tool(self, pod, command, *, source=False, data=None, output=None, input_file=None):
        if source:
            command = ["sh", "-ceu", 'export PGUSER="$POSTGRES_USER"; exec "$@"', "sh", *command]
        else:
            command = ["env", "PGUSER=postgres", *command]
        return self.run([*self.kubectl, "exec", "-i", "-n", NAMESPACE, pod, "-c", "postgres", "--", *command],
                        data=data, output=output, input_file=input_file)

    def preflight(self):
        require(os.environ.get("HIGH_AVAILABILITY_ENABLED") == "true",
                "Explicit HIGH_AVAILABILITY_ENABLED=true is required")
        nodes = self.get("nodes", namespace=None)["items"]
        ready = [node for node in nodes if any(c["type"] == "Ready" and c["status"] == "True"
                                               for c in node.get("status", {}).get("conditions", []))]
        control_planes = [node for node in ready if any(key in node["metadata"].get("labels", {})
                          for key in ("node-role.kubernetes.io/control-plane", "node-role.kubernetes.io/master"))]
        schedulable = [node for node in ready if not node.get("spec", {}).get("unschedulable") and
                       not any(t["effect"] in ("NoSchedule", "NoExecute") for t in node.get("spec", {}).get("taints", []))]
        require(len(control_planes) >= 3 and len(schedulable) >= 3,
                "At least three Ready control planes and three schedulable hosts are required before mutation")

    def maintenance(self):
        require(self.args.maintenance, "--maintenance acknowledges application downtime and source connection termination")
        for application in self.get("applications.argoproj.io")["items"]:
            automated = application["spec"].get("syncPolicy", {}).get("automated")
            require(automated is None or automated.get("enabled") is False,
                    "Pause automatic sync on all infra Argo Applications for the maintenance window")
            require(not application.get("operation") and
                    application.get("status", {}).get("operationState", {}).get("phase") not in {"Running", "Terminating"},
                    "Wait for in-progress Argo operations to finish")

    def primary(self):
        cluster = self.get("clusters.postgresql.cnpg.io", CLUSTER)
        require(cluster and cluster["metadata"]["uid"] == self.state.get("clusterUid"),
                "Target Cluster identity changed or was not prepared by this state directory")
        require(cluster.get("status", {}).get("readyInstances") == 3, "All three PostgreSQL instances must be Ready")
        pods = [pod for pod in self.get("pods")["items"]
                if pod["metadata"].get("labels", {}).get("cnpg.io/cluster") == CLUSTER and
                pod["metadata"].get("labels", {}).get("cnpg.io/podRole") == "instance" and
                not pod["metadata"].get("deletionTimestamp")]
        require(len(pods) == 3 and len({pod["spec"].get("nodeName") for pod in pods}) == 3,
                "Three PostgreSQL instances must occupy three distinct hosts")
        pod = cluster["status"].get("currentPrimary")
        require(pod in {p["metadata"]["name"] for p in pods}, "Current primary is not one of the expected pods")
        require(self.sql(pod, "postgres", "SELECT count(*) FROM pg_stat_replication WHERE state='streaming';") == "2",
                "Both standbys must be streaming before proceeding")
        require(self.sql(pod, "postgres", "SHOW synchronous_commit;") == "on" and
                self.sql(pod, "postgres", "SHOW synchronous_standby_names;").startswith("ANY 1"),
                "Synchronous commit/quorum policy is not active")
        return pod

    def legacy(self):
        pvc = self.get("pvc", "postgres-v18-pvc")
        deployment = self.get("deployment", "postgres")
        require(pvc and deployment, "Existing postgres Deployment and postgres-v18-pvc are required")
        if self.state.get("sourcePvcUid"):
            require(pvc["metadata"]["uid"] == self.state["sourcePvcUid"] and
                    deployment["metadata"]["uid"] == self.state["sourceDeploymentUid"], "Original source identity changed")
        require(self.get("service", "postgres")["spec"]["selector"] == {"app": "postgres"},
                "Canonical Service no longer points exclusively to the original database")
        pods = [pod for pod in self.get("pods")["items"] if pod["metadata"].get("labels", {}).get("app") == "postgres"
                and not pod["metadata"].get("deletionTimestamp")]
        require(len(pods) == 1, "Exactly one original PostgreSQL pod must exist")
        self.record(sourcePvcUid=pvc["metadata"]["uid"], sourceDeploymentUid=deployment["metadata"]["uid"],
                    sourcePod=pods[0]["metadata"]["name"])
        return pods[0]["metadata"]["name"]

    def prepare(self):
        require(not self.state, "Use a new private state directory for preparation")
        if self.get("customresourcedefinition", "clusters.postgresql.cnpg.io", namespace=None):
            require(not self.get("clusters.postgresql.cnpg.io", CLUSTER), "Target Cluster already exists; do not overwrite or reuse data")
        secret = self.get("secret", "postgres-secret")
        require(secret, "Provision existing postgres-secret through Vault/External Secrets first")
        owner = base64.b64decode(secret["data"]["POSTGRES_USER"]).decode()
        require(owner not in RESERVED_ROLES and not owner.startswith("pg_"), "Bootstrap owner collides with an operator-reserved role")
        config = self.get("configmap", "postgres-config")
        database = config["data"]["POSTGRES_DB"] if config else "appdb"
        require(database not in {"postgres", "template0", "template1"}, "Bootstrap application database must have a distinct name")
        self.run(["helm", "upgrade", "--install", "cloudnative-pg", "cloudnative-pg", "--repo",
                  "https://cloudnative-pg.github.io/charts", "--version", "0.29.0", "--namespace", "cnpg-system",
                  "--create-namespace", "-f", str(ROOT / "config/postgres-ha-operator-values.yaml"), "--wait", "--timeout", "10m"])
        self.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "postgres-ha-bootstrap", "namespace": NAMESPACE},
                    "type": "kubernetes.io/basic-auth", "data": {"username": secret["data"]["POSTGRES_USER"],
                    "password": secret["data"]["POSTGRES_PASSWORD"]}})
        profile = yaml.safe_load((ROOT / "config/postgres-ha-values.yaml").read_text())
        profile["postgresHa"].update(bootstrapOwner=owner, bootstrapDatabase=database)
        path = self.write("staged-values.yaml", yaml.safe_dump(profile).encode())
        rendered = self.run(["helm", "template", "bm-cluster", str(ROOT / "k8s"), "-f", str(path),
                             "--set", "publicDomain=example.invalid,internalDnsZone=internal.example.invalid,gitopsRepositoryURL=https://example.invalid/repo.git,cloudflareAccessTeamName=example",
                             "--show-only", "templates/postgres-ha.yaml"])
        self.kube("apply", "-f", "-", data=rendered)
        cluster = self.get("clusters.postgresql.cnpg.io", CLUSTER)
        self.record(phase="prepared", clusterUid=cluster["metadata"]["uid"], bootstrapOwner=owner, bootstrapDatabase=database)
        self.publish("prepared", profile["postgresHa"])
        self.kube("wait", "-n", NAMESPACE, "--for=condition=Ready", "cluster.postgresql.cnpg.io/" + CLUSTER, "--timeout=20m")
        self.primary()
        print("Prepared three isolated PostgreSQL instances. Preserve staged-values.yaml as the GitOps staging profile.")

    def inventory(self, pod, source=False):
        databases = json.loads(self.sql(pod, "postgres", DATABASE_SQL, source))
        roles = json.loads(self.sql(pod, "postgres", ROLE_SQL, source))
        memberships = json.loads(self.sql(pod, "postgres", """SELECT coalesce(json_agg(r ORDER BY role,member,grantor),'[]') FROM (
SELECT pg_get_userbyid(roleid) AS role,pg_get_userbyid(member) AS member,pg_get_userbyid(grantor) AS grantor,
admin_option,inherit_option,set_option FROM pg_auth_members) r;""", source))
        settings = json.loads(self.sql(pod, "postgres", """SELECT coalesce(json_agg(r ORDER BY db,role),'[]') FROM (
SELECT coalesce((SELECT datname FROM pg_database WHERE oid=setdatabase),'') AS db,
CASE WHEN setrole=0 THEN '' ELSE pg_get_userbyid(setrole) END AS role,setconfig
FROM pg_db_role_setting) r;""", source))
        data = {}
        for database in databases:
            name = database["datname"]
            require("=" not in name and not name.startswith(("postgresql:", "postgres:")),
                    "Database names interpreted as libpq connection strings require a separate migration plan")
            require(database["datallowconn"] and database["tablespace"] == "pg_default",
                    "Migration requires connectable databases and default tablespaces; plan custom layouts separately")
            require(self.sql(pod, name, "SELECT count(*) FROM pg_subscription WHERE subenabled;", source) == "0",
                    "Disable logical subscription writers before migration")
            require(self.sql(pod, name, "SELECT count(*) FROM pg_foreign_table;", source) == "0",
                    "Foreign tables require a separate migration plan")
            relations = json.loads(self.sql(pod, name, """SELECT coalesce(json_agg(r ORDER BY schema,name),'[]') FROM (
SELECT n.nspname AS schema,c.relname AS name,c.relkind AS kind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' AND c.relkind IN ('r','m','S')) r;""", source))
            tables = {}
            for relation in relations:
                table = ident(relation["schema"]) + "." + ident(relation["name"])
                if relation["kind"] == "S":
                    tables[table] = self.sql(pod, name, "SELECT json_build_object('last_value',last_value,'is_called',is_called) FROM " + table + ";", source)
                else:
                    tables[table] = self.row_hash(pod, name, "SELECT md5(to_jsonb(t)::text) FROM " + table + " t ORDER BY 1", source)
            large_objects = self.row_hash(pod, name, "SELECT md5(loid::text||':'||pageno::text||':'||encode(data,'hex')) FROM pg_largeobject ORDER BY loid,pageno", source)
            schema = self.tool(pod, ["pg_dump", "--schema-only", "--dbname", name], source=source)
            extensions = json.loads(self.sql(pod, name, """SELECT json_agg(r ORDER BY extname) FROM (
SELECT extname,extversion,nspname AS schema FROM pg_extension JOIN pg_namespace ON pg_namespace.oid=extnamespace) r;""", source))
            data[name] = {"tables": tables, "largeObjects": large_objects,
                          "extensions": extensions, "schemaSha256": hashlib.sha256(normalize_schema(schema)).hexdigest()}
        return {"roles": roles, "databases": databases, "memberships": memberships, "settings": settings, "data": data}

    def row_hash(self, pod, database, query, source):
        # PostgreSQL sorts fixed-size hashes with work_mem/disk spill; the client
        # streams them instead of aggregating a potentially large DB in memory.
        command = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-d", database]
        if source:
            command = ["sh", "-ceu", 'export PGUSER="$POSTGRES_USER"; exec "$@"', "sh", *command]
        else:
            command = ["env", "PGUSER=postgres", *command]
        with (self.directory / "command-error.log").open("ab") as errors:
            process = subprocess.Popen([*self.kubectl, "exec", "-i", "-n", NAMESPACE, pod, "-c", "postgres", "--", *command],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
            process.stdin.write((FORMAT_SQL + "COPY (" + query + ") TO STDOUT;\n").encode())
            process.stdin.close()
            digest, rows = hashlib.sha256(), 0
            for line in process.stdout:
                digest.update(line)
                rows += 1
            require(process.wait() == 0, "Data hash query failed; inspect private command-error.log")
        return {"rows": rows, "sha256": digest.hexdigest()}

    def verify(self, target):
        expected = json.loads((self.directory / "source-inventory.json").read_text())
        actual = self.inventory(target)
        expected_roles = {role["rolname"] for role in expected["roles"]}
        require(all(role["rolname"] in expected_roles | RESERVED_ROLES for role in actual["roles"]),
                "Target contains unexpected roles")
        actual["roles"] = [role for role in actual["roles"] if role["rolname"] in expected_roles]
        members = {m["member"] for m in expected["memberships"]} | expected_roles
        actual["memberships"] = [m for m in actual["memberships"] if m["member"] in members]
        for membership in expected["memberships"]:
            if membership["grantor"] == self.state.get("sourceBootstrapRole"):
                membership["grantor"] = "postgres"
        self.write("target-inventory.json", actual)
        require(actual == expected, "Imported role/database/schema/data inventory differs; canonical Service remains unchanged")
        self.record(phase="verified")

    def migrate(self):
        require(self.state.get("phase") == "prepared", "Migration requires a newly prepared target; never retry on partial data")
        self.maintenance()
        source, target = self.legacy(), self.primary()
        roles = json.loads(self.sql(source, "postgres", ROLE_SQL, True))
        source_bootstrap = self.sql(source, "postgres", "SELECT rolname FROM pg_authid WHERE oid=10;", True)
        self.record(sourceBootstrapRole=source_bootstrap, grantorMapping={source_bootstrap: "postgres"})
        require(not ({r["rolname"] for r in roles} & RESERVED_ROLES),
                "Source uses CNPG-reserved roles; prepare an explicit role mapping before migration")
        require(all("\n" not in role["rolname"] and "\r" not in role["rolname"] for role in roles),
                "Role names containing newlines require a separate migration plan")
        require(all(not role["rolpassword"] or role["rolpassword"].startswith("SCRAM-SHA-256$") for role in roles),
                "Legacy password hashes need an explicit credential migration before SCRAM-only HA")
        require(self.sql(source, "postgres", "SELECT count(*) FROM pg_prepared_xacts;", True) == "0",
                "Resolve prepared transactions before migration")
        require(self.sql(source, "postgres", "SELECT count(*) FROM pg_replication_slots;", True) == "0",
                "Existing replication slots require a separate migration plan")
        require(self.sql(source, "postgres", "SELECT count(*) FROM pg_tablespace WHERE spcname NOT IN ('pg_default','pg_global');", True) == "0",
                "Custom tablespaces require a separate migration plan")
        source_template = self.tool(source, ["pg_dump", "--schema-only", "--dbname=template1"], source=True)
        target_template = self.tool(target, ["pg_dump", "--schema-only", "--dbname=template1"])
        require(normalize_schema(source_template) == normalize_schema(target_template),
                "Custom template database objects require a separate migration plan")
        source_version = int(self.sql(source, "postgres", "SHOW server_version_num;", True))
        target_version = int(self.sql(target, "postgres", "SHOW server_version_num;"))
        require(source_version // 10000 == target_version // 10000 and source_version <= target_version,
                "Use the same PostgreSQL major without downgrading its minor version")
        pristine = self.inventory(target)
        require(all(not data["tables"] for data in pristine["data"].values()), "Target already contains application tables")
        require({d["datname"] for d in pristine["databases"]} == {"postgres", self.state["bootstrapDatabase"]},
                "Target has unexpected databases")
        source_before = self.inventory(source, True)
        self.write("source-inventory-before-fence.json", source_before)
        require(self.sql(source, "postgres", "SHOW hba_file;", True) ==
                self.sql(source, "postgres", "SHOW data_directory;", True) + "/pg_hba.conf",
                "Custom source HBA paths require a separate migration plan")
        hba = self.tool(source, ["sh", "-ceu", 'cat "$PGDATA/pg_hba.conf"'], source=True)
        self.write("source-pg_hba.conf", hba)
        self.record(phase="fencing")
        self.tool(source, ["sh", "-ceu", 'umask 077; test ! -e "$PGDATA/bm-ha-original-pg_hba.conf"; '
                          'cp "$PGDATA/pg_hba.conf" "$PGDATA/bm-ha-original-pg_hba.conf"; '
                          'cat > "$PGDATA/pg_hba.conf.bm-ha"; mv "$PGDATA/pg_hba.conf.bm-ha" "$PGDATA/pg_hba.conf"'],
                  source=True, data=FENCE.encode() + hba)
        self.sql(source, "postgres", "SELECT pg_reload_conf();", True)
        require(self.sql(source, "postgres", "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;", True) == "0",
                "Source HBA fencing failed validation; inspect private backup before proceeding")
        # HUP processing is asynchronous. Confirm a fresh TCP connection is
        # rejected by HBA (rather than merely lacking a password) before killing
        # existing sessions and taking the final backup.
        for _ in range(30):
            command = [*self.kubectl, "exec", "-n", NAMESPACE, source, "-c", "postgres", "--", "sh", "-ceu",
                       'PGCONNECT_TIMEOUT=2 psql -w -h 127.0.0.1 -U "$POSTGRES_USER" -d postgres -c "SELECT 1"']
            connection = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            if connection.returncode and b"pg_hba.conf rejects connection" in connection.stderr:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Source TCP fencing was not confirmed; keep maintenance in place and inspect HBA")
        # Reload acknowledgement plus a new connection ensure the fence is read;
        # existing sessions must also be terminated to prevent late writes.
        self.sql(source, "postgres", "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type='client backend' AND pid<>pg_backend_pid();", True)
        require(self.sql(source, "postgres", "SELECT count(*) FROM pg_stat_activity WHERE backend_type='client backend' AND pid<>pg_backend_pid();", True) == "0",
                "Source still has client connections after fencing")
        self.record(phase="fenced")
        inventory = self.inventory(source, True)
        self.write("source-inventory.json", inventory)
        globals_sql = self.tool(source, ["pg_dumpall", "--globals-only"], source=True)
        self.write("globals.sql", globals_sql)
        dumps = []
        for index, database in enumerate(inventory["databases"]):
            filename = f"database-{index}.dump"
            path = self.write(filename, b"")
            with path.open("wb") as output:
                self.tool(source, ["pg_dump", "--format=custom", "--create", "--dbname", database["datname"]], source=True, output=output)
            with path.open("rb") as saved:
                digest = hashlib.file_digest(saved, "sha256").hexdigest()
            dumps.append({"database": database["datname"], "file": filename, "sha256": digest})
        self.write("dumps.json", dumps)
        require(self.inventory(source, True) == inventory, "Source changed while dumping; keep fenced and investigate background writers")
        self.record(phase="restoring")
        bootstrap = self.state["bootstrapDatabase"]
        self.sql(target, "postgres", "DROP DATABASE " + ident(bootstrap) + " WITH (FORCE);\nDROP ROLE " + ident(self.state["bootstrapOwner"]) + ";")
        self.sql(target, "postgres", restore_grantors(globals_sql.decode(), source_bootstrap))
        for entry in dumps:
            # The operator may reconnect to its maintenance DB; FORCE prevents a
            # stale management connection from obstructing its brief recreation.
            database = entry["database"]
            self.sql(target, "template1", "DROP DATABASE IF EXISTS " + ident(database) + " WITH (FORCE);")
            with (self.directory / entry["file"]).open("rb") as dump:
                self.tool(target, ["pg_restore", "--exit-on-error", "--create", "--dbname=template1"], input_file=dump)
        self.verify(target)
        profile = yaml.safe_load((self.directory / "staged-values.yaml").read_text())
        profile["postgresHa"]["active"] = True
        self.write("active-values.yaml", yaml.safe_dump(profile).encode())
        print("Import verified. Original database remains fenced, original PVC retained. Review active-values.yaml before cutover.")

    def fresh(self):
        require(self.state.get("phase") == "prepared", "Fresh bootstrap requires a prepared target")
        require(not self.get("pvc", "postgres-v18-pvc") and not self.get("deployment", "postgres"),
                "Fresh mode refuses an existing database/PVC; use explicit migration")
        target = self.primary()
        self.sql(target, "postgres", "ALTER ROLE " + ident(self.state["bootstrapOwner"]) + " SUPERUSER;\nCREATE DATABASE keycloak;")
        self.write("source-inventory.json", self.inventory(target))
        self.record(phase="verified", fresh=True)
        profile = yaml.safe_load((self.directory / "staged-values.yaml").read_text())
        profile["postgresHa"]["active"] = True
        self.write("active-values.yaml", yaml.safe_dump(profile).encode())
        print("Fresh HA database verified. Activate the reviewed profile before starting dependent applications.")

    def cutover(self):
        require(self.state.get("phase") == "verified", "Cutover requires a successfully verified import/fresh bootstrap")
        self.maintenance()
        require(self.args.desired_values, "--desired-values must name the reviewed persistent active Helm profile")
        desired = yaml.safe_load(Path(self.args.desired_values).read_text())["postgresHa"]
        expected = yaml.safe_load((self.directory / "active-values.yaml").read_text())["postgresHa"]
        require(desired == expected, "Desired active profile differs from the verified migration profile")
        target = self.primary()
        self.verify(target)
        service = self.get("service", "postgres")
        if not self.state.get("fresh"):
            source = self.legacy()
            require(self.inventory(source, True) == json.loads((self.directory / "source-inventory.json").read_text()),
                    "Original database changed since verification; do not cut over")
            self.record(phase="cutover-started")
            self.publish("cutover-started", desired)
            self.kube("scale", "deployment/postgres", "-n", NAMESPACE, "--replicas=0")
            self.kube("wait", "-n", NAMESPACE, "--for=delete", "pod", "-l", "app=postgres", "--timeout=180s")
            patch = [{"op": "test", "path": "/spec/selector", "value": {"app": "postgres"}},
                     {"op": "replace", "path": "/spec/selector", "value": SELECTOR}]
            self.kube("patch", "service", "postgres", "-n", NAMESPACE, "--type=json", "-p", json.dumps(patch))
        else:
            require(not service, "Fresh cutover refuses to replace an existing canonical Service")
            self.record(phase="cutover-started")
            self.publish("cutover-started", desired)
            self.apply({"apiVersion": "v1", "kind": "Service", "metadata": {"name": "postgres", "namespace": NAMESPACE},
                        "spec": {"selector": SELECTOR, "ports": [{"port": 5432, "targetPort": 5432}], "type": "ClusterIP"}})
        self.kube("patch", "cluster.postgresql.cnpg.io", CLUSTER, "-n", NAMESPACE, "--type=merge", "-p",
                  json.dumps({"spec": {"postgresql": {"pg_hba": ["host all all all scram-sha-256"]}}}))
        for _ in range(60):
            primary = self.primary()
            if self.sql(primary, "postgres", "SELECT count(*) FROM pg_hba_file_rules WHERE type LIKE 'host%' AND auth_method='reject';") == "0":
                break
            time.sleep(2)
        else:
            raise RuntimeError("Canonical Service moved but target access is still staged; inspect and finish cutover manually")
        self.record(phase="active")
        self.publish("active", desired)
        print("Canonical postgres Service cut over. Keep the active profile in GitOps before resuming sync/writers. Old PVC and fenced data remain intact.")

    def abort(self):
        require(self.state.get("phase") in {"fencing", "fenced", "restoring", "verified"} and not self.state.get("fresh"),
                "Abort is only safe before cutover; after new writes, plan a reverse migration")
        self.maintenance()
        source = self.legacy()
        hba = (self.directory / "source-pg_hba.conf").read_bytes()
        self.tool(source, ["sh", "-ceu", 'umask 077; cat > "$PGDATA/pg_hba.conf.bm-ha"; '
                          'mv "$PGDATA/pg_hba.conf.bm-ha" "$PGDATA/pg_hba.conf"'], source=True, data=hba)
        self.sql(source, "postgres", "SELECT pg_reload_conf();", True)
        self.record(phase="aborted")
        checkpoint = self.get("configmap", "postgres-ha-state")
        if checkpoint:
            require(checkpoint.get("data", {}).get("clusterUid") == self.state["clusterUid"],
                    "A different migration owns postgres-ha-state; inspect it before resuming installation")
            self.kube("delete", "configmap", "postgres-ha-state", "-n", NAMESPACE)
        print("Original database reconnected. Target remains isolated; no target/PVC/backup was removed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "migrate", "fresh", "cutover", "abort"])
    parser.add_argument("--state-dir", required=True, help="Private durable directory, mode 0700; preserve for recovery")
    parser.add_argument("--maintenance", action="store_true", help="Acknowledge downtime; all automatic Argo sync must already be paused")
    parser.add_argument("--desired-values", help="Reviewed persistent active Helm values used at cutover")
    args = parser.parse_args()
    os.umask(0o077)
    migration = Migration(args)
    if args.action != "abort":
        migration.preflight()
    getattr(migration, args.action)()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        # SQL/API errors are deliberately kept in the private command log.
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
