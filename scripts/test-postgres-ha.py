#!/usr/bin/env python3
"""PostgreSQL HA safety tests; --docker also runs isolated SQL migration/abort."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("postgres_ha", ROOT / "scripts/configure-postgres-ha.py")
HA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HA)


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bm-postgres-ha-test-")
        self.addCleanup(self.temp.cleanup)
        self.migration = HA.Migration(argparse.Namespace(state_dir=self.temp.name, maintenance=True, desired_values=None))
        self.addCleanup(self.migration.lock.close)

    def test_insufficient_topology_has_no_writes(self):
        self.migration.get = lambda *args, **kwargs: {"items": []}
        with patch.dict(os.environ, {"HIGH_AVAILABILITY_ENABLED": "true"}), self.assertRaisesRegex(RuntimeError, "three Ready"):
            self.migration.preflight()
        self.assertEqual(self.migration.state, {})

    def test_migration_requires_prepared_target(self):
        with self.assertRaisesRegex(RuntimeError, "newly prepared"):
            self.migration.migrate()

    def test_cutover_requires_verified_data(self):
        self.migration.state = {"phase": "restoring"}
        with self.assertRaisesRegex(RuntimeError, "verified"):
            self.migration.cutover()

    def test_no_old_copy_rollback_after_cutover(self):
        for phase in ("cutover-started", "active", "aborted"):
            with self.subTest(phase=phase), self.assertRaisesRegex(RuntimeError, "before cutover"):
                self.migration.state = {"phase": phase}
                self.migration.abort()

    def test_automatic_gitops_must_be_paused(self):
        self.migration.get = lambda *args: {"items": [{"spec": {"syncPolicy": {"automated": {}}}}]}
        with self.assertRaisesRegex(RuntimeError, "Pause automatic sync"):
            self.migration.maintenance()

    def test_bad_inventory_never_verifies(self):
        expected = {"roles": [{"rolname": "admin", "rolpassword": "original"}], "memberships": [], "data": {"appdb": "original"}}
        self.migration.write("source-inventory.json", expected)
        self.migration.inventory = lambda target: dict(expected, data={"appdb": "changed"})
        with self.assertRaisesRegex(RuntimeError, "inventory differs"):
            self.migration.verify("unused")
        self.assertNotEqual(self.migration.state.get("phase"), "verified")

    def test_bootstrap_grantor_mapping_preserves_options_and_other_grantors(self):
        sql = ('GRANT report TO admin WITH ADMIN OPTION, INHERIT TRUE GRANTED BY admin;\n'
               'GRANT report TO app WITH SET FALSE GRANTED BY "other admin";')
        restored = HA.restore_grantors(sql, "admin")
        self.assertIn("WITH ADMIN OPTION, INHERIT TRUE GRANTED BY postgres;", restored)
        self.assertIn('SET SESSION AUTHORIZATION "other admin";', restored)
        self.assertIn('WITH SET FALSE GRANTED BY "other admin";', restored)

    def test_private_state_rejects_symlink(self):
        link = Path(self.temp.name) / "linked"
        link.symlink_to(self.temp.name)
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            HA.Migration(argparse.Namespace(state_dir=str(link)))

    def test_failed_checkpoint_replacement_retains_prior_resume_state(self):
        self.migration.record(phase="fenced")
        with patch.object(HA.os, "replace", side_effect=OSError("fixture failure")), self.assertRaises(OSError):
            self.migration.record(phase="restoring")
        self.assertEqual(json.loads(self.migration.state_path.read_text())["phase"], "fenced")
        self.assertEqual(list(Path(self.temp.name).glob(".state.json.*")), [])
        self.assertEqual(self.migration.state_path.stat().st_mode & 0o777, 0o600)

    def test_concurrent_migration_commands_cannot_share_a_journal(self):
        with self.assertRaisesRegex(RuntimeError, "Another PostgreSQL migration"):
            HA.Migration(argparse.Namespace(state_dir=self.temp.name))


def docker_canary():
    import yaml
    image = yaml.safe_load((ROOT / "config/postgres-ha-values.yaml").read_text())["postgresHa"]["image"]
    docker = ["docker"] if os.geteuid() == 0 else ["sudo", "-n", "docker"]
    subprocess.run([*docker, "image", "inspect", image], check=True, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory(prefix="bm-postgres-ha-canary-") as directory:
        directory = Path(directory)
        names = ["bm-pg-ha-source-" + str(os.getpid()), "bm-pg-ha-target-" + str(os.getpid())]
        wrapper = directory / "kubectl"
        wrapper.write_text("#!/usr/bin/env python3\nimport subprocess,sys\na=sys.argv[1:]\n"
                           "assert a[0]=='exec'\ni=a.index('--');p=a[a.index('-n')+2]\n"
                           "raise SystemExit(subprocess.call(" + repr(docker) + "+['exec','-i',p]+a[i+1:]))\n")
        wrapper.chmod(0o700)

        def run(command, data=None, check=True):
            return subprocess.run(command, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)

        def sql(name, query, user="postgres", database="postgres"):
            return run([*docker, "exec", "-i", name, "psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-U", user, "-d", database], query.encode())

        class Fixture(HA.Migration):
            def get(self, kind, name=None, namespace="infra"):
                if kind in {"pvc", "deployment"}:
                    return {"metadata": {"uid": "fixture-" + kind}}
                if kind == "service":
                    return {"spec": {"selector": {"app": "postgres"}}}
                if kind == "pods":
                    return {"items": [{"metadata": {"name": names[0], "labels": {"app": "postgres"}}}]}
                if kind == "applications.argoproj.io":
                    return {"items": []}
                if kind == "configmap":
                    return None
                raise AssertionError(kind)

            def primary(self):
                # This fixture validates SQL and fencing, not Kubernetes
                # scheduling, operator elections or three-host failover.
                return names[1]

        sleeper = None
        try:
            for name, owner in zip(names, ["admin", "postgres"]):
                run([*docker, "run", "-d", "--name", name, "--network", "none", "--user", "26:26", "--read-only",
                     "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--memory", "512m", "--cpus", "0.5",
                     "--tmpfs", "/tmp:rw,nosuid,nodev,size=32m,uid=26,gid=26",
                     "--tmpfs", "/var/run/postgresql:rw,nosuid,nodev,size=16m,uid=26,gid=26",
                     "--tmpfs", "/var/lib/postgresql/data:rw,nosuid,nodev,size=128m,uid=26,gid=26",
                     "-e", "PGDATA=/var/lib/postgresql/data", "-e", "POSTGRES_USER=" + owner, "--entrypoint", "sh", image,
                     "-ceu", 'initdb -U "$POSTGRES_USER" --locale=en_US.utf8 --auth=trust >/dev/null; '
                     'exec postgres -c shared_buffers=32MB -c max_wal_size=64MB -c min_wal_size=32MB'])
                for _ in range(80):
                    if run([*docker, "exec", name, "pg_isready", "-U", owner], check=False).returncode == 0:
                        break
                    time.sleep(0.25)
                else:
                    raise RuntimeError("Fixture did not start")
            sql(names[0], "CREATE DATABASE appdb; CREATE ROLE report LOGIN PASSWORD 'fixture-only-password'; "
                "ALTER ROLE admin PASSWORD 'fixture-admin-password'; GRANT report TO admin WITH ADMIN OPTION; "
                "ALTER ROLE report SET search_path TO public; ALTER ROLE report IN DATABASE appdb SET search_path TO public; "
                "ALTER DATABASE appdb SET timezone TO 'Europe/Paris';", "admin")
            sql(names[0], "CREATE TABLE things(id bigserial PRIMARY KEY,value text); INSERT INTO things(value) VALUES "
                "('alpha'),('beta'),('quotes'' data'),(NULL); SELECT nextval('things_id_seq'); GRANT SELECT ON things TO report;", "admin", "appdb")
            sql(names[0], "CREATE TABLE retained(value text); INSERT INTO retained VALUES('default-db-data');", "admin")
            sql(names[1], "CREATE ROLE admin LOGIN PASSWORD 'fixture-admin-password'; CREATE ROLE streaming_replica REPLICATION LOGIN; "
                "CREATE DATABASE appdb OWNER admin;")
            sleeper = subprocess.Popen([*docker, "exec", names[0], "psql", "-h", "127.0.0.1", "-U", "admin", "-d", "postgres",
                                        "-c", "SELECT pg_sleep(300)"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            with patch.dict(os.environ, {"KUBECTL": str(wrapper)}):
                fixture = Fixture(argparse.Namespace(state_dir=str(directory / "state"), maintenance=True, desired_values=None))
                fixture.record(phase="prepared", clusterUid="fixture", bootstrapOwner="admin", bootstrapDatabase="appdb")
                fixture.write("staged-values.yaml", (ROOT / "config/postgres-ha-values.yaml").read_bytes())
                fixture.migrate()
                assert fixture.state["phase"] == "verified"
                assert sleeper.wait(timeout=10) != 0
                rejected = run([*docker, "exec", names[0], "psql", "-h", "127.0.0.1", "-U", "admin", "-d", "postgres", "-c", "SELECT 1"], check=False)
                assert rejected.returncode != 0 and b"pg_hba.conf rejects connection" in rejected.stderr
                fixture.abort()
                assert fixture.state["phase"] == "aborted"
                run([*docker, "exec", names[0], "psql", "-h", "127.0.0.1", "-U", "admin", "-d", "postgres", "-c", "SELECT 1"])
                assert fixture.inventory(names[0], True) == json.loads((directory / "state/source-inventory.json").read_text())
            print("PASS: isolated role/password/database/schema/data/sequence restore, existing session termination, new TCP fence, and abort recovery")
        finally:
            for name in names:
                run([*docker, "rm", "-f", "-v", name], check=False)
            if sleeper:
                sleeper.wait(timeout=10)


if __name__ == "__main__":
    use_docker = "--docker" in sys.argv
    if use_docker:
        sys.argv.remove("--docker")
    result = unittest.main(exit=False)
    if not result.result.wasSuccessful():
        raise SystemExit(1)
    if use_docker:
        docker_canary()
