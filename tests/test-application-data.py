#!/usr/bin/env python3
"""Offline guards for shared data isolation; optional disposable DB/cache probes."""
import base64
from contextlib import nullcontext, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("application_data", ROOT / "scripts/configure-application-data.py")
data = importlib.util.module_from_spec(spec)
spec.loader.exec_module(data)
ha_spec = importlib.util.spec_from_file_location("ha_profile", ROOT / "scripts/resolve-ha-profile.py")
ha_profile = importlib.util.module_from_spec(ha_spec)
ha_spec.loader.exec_module(ha_profile)


class DataContract(unittest.TestCase):
    def test_auth_preparation_uses_inventory_endpoints_without_writing_credentials_to_values(self):
        inventory = {"platform": {"domain": "example.test", "internalDomain": "services.test", "services": {
            "kafka": {"securityProtocol": "SASL_PLAINTEXT", "brokers": [{"id": 0, "host": "100.100.0.15", "port": 30940}]}}}, "environments": {"int": {}}}
        installed = {"data": {"PLATFORM_DOMAIN": "example.test", "INTERNAL_DNS_ZONE": "services.test"}}
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "values.yaml"
            with patch.object(sys, "argv", ["configure-application-data.py", "--config", "public.yaml", "--prepare-auth", "--legacy-clients-migrated", "--output-values", str(output)]), patch.object(data, "load_inventory", return_value=inventory) as load, patch.object(data, "kubectl", side_effect=[installed, {}]), patch.object(data.Services, "_vault", return_value=nullcontext(object())), patch.object(data, "credentials", return_value={"username": "default", "password": "admin" * 10}), patch.object(data, "apply"), redirect_stdout(io.StringIO()):
                data.main()
            load.assert_called_once_with("public.yaml", allow_partial=True)
            contents = output.read_text()
            self.assertEqual(inventory["platform"]["services"]["kafka"]["brokers"], yaml.safe_load(contents)["applicationData"]["kafkaBrokers"])
            self.assertNotIn("admin" * 10, contents)

    def test_unregistered_environment_is_rejected_before_platform_access(self):
        with patch.object(sys, "argv", ["configure-application-data.py", "--config", "public.yaml", "--environment", "prod"]), patch.object(data, "load_inventory", return_value={"environments": {"int": {}}}), patch.object(data, "kubectl") as access:
            with self.assertRaisesRegex(data.ServiceError, "not registered"):
                data.main()
            access.assert_not_called()

    def test_installer_reruns_preserve_shared_auth_without_enabling_ha(self):
        supplied = yaml.safe_load((ROOT / "config/application-data-values.yaml").read_text())
        first = ha_profile.resolve({}, {}, "", supplied=supplied)
        self.assertFalse(first["highAvailabilityEnabled"])
        self.assertTrue(first["applicationData"]["enabled"])
        self.assertEqual(first, ha_profile.resolve({}, {}, "", previous=first))
        with self.assertRaisesRegex(ValueError, "downgrade"):
            ha_profile.resolve({}, {}, "", supplied={"applicationData": {"enabled": False}}, previous=first)
        with self.assertRaisesRegex(ValueError, "authenticated Redis"):
            ha_profile.resolve({}, {}, "", supplied={"redis-ha": {"auth": False}}, previous=first)

    def test_identifiers_cannot_escape_the_application_environment(self):
        for app in ("bad/path", "bad;sql", "DevApp", "x" * 32):
            with self.assertRaises(data.ServiceError):
                data.identity(app, "int")
        with self.assertRaises(data.ServiceError):
            data.identity("devapp", "qa")
        self.assertEqual("devapp_int", data.identity("devapp", "int")["database"])
        self.assertEqual("devappdb", data.identity("devapp", "prod", "devappdb")["database"])

    def test_database_creation_is_restricted_and_reruns_preserve_owners(self):
        identity = data.identity("devapp", "int")
        sql = data.database_sql(identity, "x" * 40)
        self.assertIn("NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS", sql)
        self.assertIn("CREATE DATABASE devapp_int OWNER devapp_int", sql)
        repeat = data.database_sql(identity, "x" * 40, existing_role=True, existing_database=True)
        self.assertNotIn("CREATE DATABASE", repeat)
        self.assertNotIn("ALTER", repeat)
        self.assertIn("REVOKE CONNECT ON DATABASE devapp_int FROM PUBLIC", repeat)
        with self.assertRaises(data.ServiceError):
            data.database_sql(identity, "';bad")

    def test_legacy_or_privileged_database_owner_is_rejected_before_credential_write(self):
        for owner, role in (("admin", "devapp_prod:false"), ("devapp_prod", "devapp_prod:true")):
            with patch.object(data.Services, "_kv_get", return_value=({}, 0)), patch.object(data, "postgres_target", return_value="deployment/postgres"), patch.object(data, "postgres", side_effect=[owner, role]), patch.object(data, "credentials") as create:
                with self.assertRaises(data.ServiceError):
                    data.provision_database(object(), data.identity("devapp", "prod", "devappdb"))
                create.assert_not_called()

    def test_redis_secret_keeps_other_environments_and_prevents_lost_updates(self):
        first = data.redis_secret("admin" * 10, user_line=data.redis_acl_user("devapp_int", "x" * 40, "devapp:int:"))
        current = {"metadata": {"resourceVersion": "7"}, "data": {key: base64.b64encode(value.encode()).decode() for key, value in first["stringData"].items()}}
        second = data.redis_secret("admin" * 10, current, data.redis_acl_user("devapp_uat", "y" * 40, "devapp:uat:"))
        self.assertEqual("7", second["metadata"]["resourceVersion"])
        self.assertIn("~devapp:int:*", second["stringData"]["users.acl"])
        self.assertIn("~devapp:uat:*", second["stringData"]["users.acl"])
        self.assertNotIn("nopass", second["stringData"]["users.acl"])
        self.assertNotIn("x" * 40, second["stringData"]["users.acl"])

    def test_legacy_auth_staging_preserves_anonymous_access_until_profile_activation(self):
        admin, legacy = "a" * 40, "l" * 40
        for authenticated in (False, True):
            applied, commands = [], []
            def run(command, payload=None):
                commands.append((command, payload))
                return "NOAUTH Authentication required." if authenticated and command[-1] == "PING" else "PONG"
            with patch.object(data, "credentials", side_effect=[{"username": "default", "password": admin},
                     {"username": "legacy_platform", "password": legacy}]), \
                    patch.object(data, "kubectl", return_value={}), patch.object(data, "apply", side_effect=applied.append), \
                    patch.object(data, "redis_pods", return_value=["redis-0"]), patch.object(data, "run", side_effect=run), \
                    patch.object(data, "redis_command", return_value="PONG") as authenticated_command:
                data.prepare_legacy_redis(object())
            payload = next(payload for command, payload in commands if command[-1] == "--pipe")
            self.assertEqual(data.resp("AUTH", admin) in payload, authenticated)
            self.assertIn("legacy_platform", payload)
            self.assertNotIn("default", payload)
            self.assertNotIn("nopass", payload)
            self.assertNotIn(admin, str([command for command, _ in commands]))
            self.assertEqual(applied[1]["stringData"], {"username": "legacy_platform", "password": legacy})
            self.assertTrue(any(call.args[2:] == ("--user", "legacy_platform", "PING") for call in authenticated_command.call_args_list))
            current = {"data": {key: base64.b64encode(value.encode()).decode() for key, value in applied[0]["stringData"].items()}}
            activated = data.redis_secret(admin, current, data.redis_acl_user("devapp_int", "i" * 40, "devapp:int:"))
            self.assertIn("user legacy_platform on #", activated["stringData"]["users.acl"])
            self.assertIn("~devapp:int:*", activated["stringData"]["users.acl"])
            self.assertNotIn("nopass", activated["stringData"]["users.acl"])

    def test_legacy_acl_exception_does_not_accept_arbitrary_administrators(self):
        for line in ("user another_admin on #" + "a" * 64 + " ~* &* +@all",
                     "user legacy_platform on nopass ~* &* +@all"):
            current = {"data": {"users.acl": base64.b64encode(line.encode()).decode()}}
            with self.assertRaisesRegex(data.ServiceError, "malformed"):
                data.redis_secret("a" * 40, current)

    def test_kafka_acl_includes_dlt_and_groups_without_wildcard_cluster_access(self):
        commands = data.kafka_acls(data.identity("devapp", "uat"))
        self.assertIn("--resource-pattern-type", commands[0])
        self.assertIn("devapp.uat.", commands[0])
        self.assertIn("devapp.uat.", commands[1])
        self.assertEqual("IdempotentWrite", commands[2][-1])
        self.assertNotIn("All", str(commands))
        self.assertNotIn("*", str(commands))

    def test_existing_broad_kafka_permissions_stop_reconciliation(self):
        identity = data.identity("devapp", "int")
        granted = "Current ACLs for resource `ResourcePattern(resourceType=TOPIC, name=*, patternType=LITERAL)`:\n    (principal=User:devapp_int, host=*, operation=ALL, permissionType=ALLOW)\n"
        with self.assertRaisesRegex(data.ServiceError, "overbroad"):
            data.validate_kafka_acls(granted, identity)
        with self.assertRaisesRegex(data.ServiceError, "overbroad"):
            data.validate_kafka_acls(granted.replace("User:devapp_int", "User:*"), identity, wildcard=True)
        with self.assertRaisesRegex(data.ServiceError, "Unrecognized"):
            data.validate_kafka_acls("unexpected response", identity)

    def test_anonymous_cache_is_rejected_before_any_kafka_checks(self):
        inventory = {"platform": {"services": {"kafka": {"brokers": [{"id": 0, "host": "100.64.0.10", "port": 30940}]}}}}
        config = {"data": {"BM_REDIS_AUTH_ENABLED": "true", "BM_KAFKA_REMOTE_BROKERS": "100.64.0.10:30940"}}
        with patch.object(data, "kubectl", side_effect=[config, {"spec": {"replicas": 1}, "status": {"readyReplicas": 1}}]), patch.object(data, "redis_pods", return_value=["redis-0"]), patch.object(data, "run", return_value="PONG") as calls:
            with self.assertRaisesRegex(data.ServiceError, "reject anonymous"):
                data.require_ready(inventory, "admin" * 10)
            self.assertEqual(1, calls.call_count)

    def test_remote_listener_keeps_internal_addresses_and_rejects_missing_broker(self):
        script = ROOT / "k8s/files/kafka-remote-env.sh"
        env = dict(os.environ, HOSTNAME="kafka-1", BM_KAFKA_REMOTE_ENABLED="true", KAFKA_PROCESS_ROLES="broker",
                   BM_KAFKA_REMOTE_BROKERS="100.64.0.10:30940,100.64.0.11:30941,100.64.0.12:30942",
                   KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://kafka-1.kafka.infra.svc.cluster.local:9092",
                   KAFKA_LISTENER_SECURITY_PROTOCOL_MAP="PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT")
        command = ["bash", "-ec", 'source "$1"; configure_remote_kafka; echo "$KAFKA_ADVERTISED_LISTENERS"; echo "$KAFKA_LISTENER_SECURITY_PROTOCOL_MAP"', "fixture", str(script)]
        result = subprocess.run(command, env=env, text=True, capture_output=True, check=True)
        self.assertIn("PLAINTEXT://kafka-1.kafka.infra.svc.cluster.local:9092,REMOTE://100.64.0.11:30941", result.stdout)
        self.assertIn("REMOTE:SASL_PLAINTEXT", result.stdout)
        env["BM_KAFKA_REMOTE_BROKERS"] = "100.64.0.10:30940"
        self.assertNotEqual(0, subprocess.run(command, env=env, capture_output=True).returncode)

    def test_opt_in_helm_profile_persists_and_ha_mounts_are_unambiguous(self):
        command = ["helm", "template", "bm-cluster", str(ROOT / "k8s"), "--set-string",
                   "publicDomain=example.com,internalDnsZone=internal.example.com,organizationName=Example,gitopsRepositoryURL=https://example.com/platform.git,cloudflareAccessTeamName=example"]
        default = list(yaml.safe_load_all(subprocess.run(command, text=True, capture_output=True, check=True).stdout))
        self.assertFalse(any(r and r["metadata"]["name"] == "application-data-access" for r in default))
        profile = ["--values", str(ROOT / "config/application-data-values.yaml")]
        enabled = list(yaml.safe_load_all(subprocess.run(command + profile, text=True, capture_output=True, check=True).stdout))
        app = next(r for r in enabled if r and r["kind"] == "Application" and r["metadata"]["name"] == "bm-cluster")
        values = app["spec"]["source"]["helm"]["valuesObject"]
        self.assertTrue(values["applicationData"]["enabled"])
        controller_policy = next(r for r in enabled if r and r["kind"] == "NetworkPolicy" and r["metadata"]["name"] == "kafka-controller-access")
        self.assertEqual(controller_policy["spec"]["podSelector"], {"matchLabels": {"app": "kafka-controller"}})
        self.assertEqual(controller_policy["spec"]["ingress"], [{"from": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "infra"}}}], "ports": [{"protocol": "TCP", "port": 9093}]}])
        self.assertTrue(values["redis-ha"]["auth"])
        self.assertEqual("/etc/redis-acl/users.acl", values["redis-ha"]["redis"]["config"]["aclfile"])
        ha = ["--set", "highAvailabilityEnabled=true", "--values", str(ROOT / "config/kafka-ha-values.yaml"),
              "--set", "kafkaHa.phase=active", "--set-string", "kafkaHa.clusterId=8ipNY9RxQtWkattTais5yQ"]
        self.assertNotEqual(0, subprocess.run(command + profile + ha, capture_output=True).returncode)
        for index in (1, 2):
            ha += ["--set", f"applicationData.kafkaBrokers[{index}].id={index}", "--set-string", f"applicationData.kafkaBrokers[{index}].host=100.64.0.{10 + index}", "--set", f"applicationData.kafkaBrokers[{index}].port={30940 + index}"]
        rendered = list(yaml.safe_load_all(subprocess.run(command + profile + ha, text=True, capture_output=True, check=True).stdout))
        redis_ingress = next(item for item in rendered if item and item["kind"] == "NetworkPolicy" and item["metadata"]["name"] == "shared-redis-ha-clients")
        self.assertIn({"namespaceSelector": {"matchLabels": {"bm-cluster.io/application-workloads": "true"}}}, redis_ingress["spec"]["ingress"][0]["from"])
        self.assertEqual(redis_ingress["spec"]["ingress"][0]["ports"], [{"protocol": "TCP", "port": 6379}])
        for item in rendered:
            if item and item["kind"] == "StatefulSet" and item["metadata"]["name"] in ("kafka", "kafka-controller"):
                pod = item["spec"]["template"]["spec"]
                paths = [mount["mountPath"] for mount in pod["containers"][0]["volumeMounts"]]
                self.assertEqual(1, paths.count("/opt/bm-cluster"))


@unittest.skipUnless(os.environ.get("BM_TEST_DATA_DOCKER") == "1", "set BM_TEST_DATA_DOCKER=1 for disposable PostgreSQL/Redis checks")
class LiveDataIsolation(unittest.TestCase):
    def docker(self, *args, payload=None, check=True):
        return subprocess.run(["docker", *args], input=payload, text=True, capture_output=True, check=check).stdout.strip()

    def test_postgres_and_cache_reject_other_environment_credentials_and_keys(self):
        prefix = "bm-data-test-" + uuid.uuid4().hex[:10]
        pg, redis = prefix + "-pg", prefix + "-redis"
        with tempfile.TemporaryDirectory(prefix=prefix) as temp:
            path = Path(temp) / "users.acl"
            current = data.redis_secret("admin" * 10)
            path.write_text(current["stringData"]["users.acl"])
            path.chmod(0o644)
            try:
                self.docker("run", "-d", "--name", pg, "--hostname", "postgres.infra.svc.cluster.local", "-e", "POSTGRES_PASSWORD=" + "admin" * 10, "postgres:18-alpine")
                self.docker("run", "-d", "--name", redis, "--mount", f"type=bind,source={path},target=/users.acl,readonly", "redis:8.10.0-alpine", "redis-server", "--aclfile", "/users.acl")
                for _ in range(60):
                    if "accepting connections" in self.docker("exec", pg, "pg_isready", "-h", "127.0.0.1", "-U", "postgres", check=False):
                        break
                    time.sleep(0.5)
                original_run = data.run
                def postgres_exec(command, payload=None):
                    return original_run(["docker", "exec", "-i", pg, *command[command.index("--") + 1:]], payload)
                for env in ("int", "uat"):
                    self.docker("exec", "-i", pg, "psql", "-U", "postgres", "-v", "ON_ERROR_STOP=1", payload=data.database_sql(data.identity("devapp", env), env * 20))
                    with patch.object(data, "run", side_effect=postgres_exec):
                        credential = {"username": "devapp_" + env, "password": env * 20}
                        own = data.postgres("CREATE TABLE fixture (id int); INSERT INTO fixture VALUES (1); SELECT * FROM fixture;", pg, credential, "devapp_" + env)
                        self.assertEqual("1", own)
                        with self.assertRaises(data.ServiceError):
                            data.postgres("SELECT current_user;", pg, {**credential, "password": "wrong" * 10}, "devapp_" + env)
                    existing = {"metadata": {"resourceVersion": "1"}, "data": {key: base64.b64encode(value.encode()).decode() for key, value in current["stringData"].items()}}
                    def apply_acl(document):
                        nonlocal current
                        current = document
                    def redis_exec(command, payload=None):
                        return self.docker("exec", "-i", redis, *command[command.index("--") + 1:], payload=payload)
                    with patch.object(data, "credentials", return_value={"username": "devapp_" + env, "password": env * 20}), patch.object(data, "kubectl", return_value=existing), patch.object(data, "apply", side_effect=apply_acl), patch.object(data, "redis_pods", return_value=[redis]), patch.object(data, "run", side_effect=redis_exec):
                        data.provision_redis(None, data.identity("devapp", env), "admin" * 10)
                with patch.object(data, "run", side_effect=postgres_exec):
                    with self.assertRaises(data.ServiceError):
                        data.postgres("SELECT 1;", pg, {"username": "devapp_int", "password": "int" * 20}, "devapp_uat")
                self.assertTrue(self.docker("exec", redis, "redis-cli", "PING").startswith("NOAUTH"))
                self.assertEqual("OK", self.docker("exec", "-e", "REDISCLI_AUTH=" + "int" * 20, redis, "redis-cli", "--user", "devapp_int", "SET", "devapp:int:users::1", "one"))
                self.assertTrue(self.docker("exec", "-e", "REDISCLI_AUTH=" + "uat" * 20, redis, "redis-cli", "--user", "devapp_uat", "GET", "devapp:int:users::1").startswith("NOPERM"))
                # Shared cache ACLs isolate values, not key-name enumeration.
                self.assertIn("devapp:int:users::1", self.docker("exec", "-e", "REDISCLI_AUTH=" + "uat" * 20, redis, "redis-cli", "--user", "devapp_uat", "KEYS", "*"))
                self.assertTrue(self.docker("exec", "-e", "REDISCLI_AUTH=" + "int" * 20, redis, "redis-cli", "--user", "devapp_int", "FLUSHALL").startswith("NOPERM"))
            finally:
                self.docker("rm", "-f", pg, redis, check=False)

    def test_real_kafka_scram_and_acl_reject_other_environment_topics_and_groups(self):
        prefix = "bm-kafka-test-" + uuid.uuid4().hex[:10]
        image = "docker.io/confluentinc/cp-kafka@sha256:0ad069035863aa1b090f4d9af47bfd2c08dc32864f3575d7d8579e3155c2586d"
        controller, broker = prefix + "-controller", prefix + "-broker"
        shared = {"CLUSTER_ID": "8ipNY9RxQtWkattTais5yQ", "KAFKA_CONTROLLER_QUORUM_VOTERS": "3000@controller:9093",
                  "KAFKA_CONTROLLER_LISTENER_NAMES": "CONTROLLER", "KAFKA_AUTHORIZER_CLASS_NAME": "org.apache.kafka.metadata.authorizer.StandardAuthorizer",
                  "KAFKA_SUPER_USERS": "User:ANONYMOUS", "KAFKA_ALLOW_EVERYONE_IF_NO_ACL_FOUND": "false", "KAFKA_HEAP_OPTS": "-Xms128m -Xmx256m"}
        def env_args(values):
            return [item for key, value in values.items() for item in ("-e", key + "=" + value)]
        try:
            self.docker("network", "create", prefix)
            controller_env = dict(shared, KAFKA_PROCESS_ROLES="controller", KAFKA_NODE_ID="3000",
                                  KAFKA_LISTENERS="CONTROLLER://0.0.0.0:9093", KAFKA_ADVERTISED_LISTENERS="CONTROLLER://controller:9093",
                                  KAFKA_LISTENER_SECURITY_PROTOCOL_MAP="CONTROLLER:PLAINTEXT")
            start = '. /etc/confluent/docker/bash-config; ub path /etc/kafka/ writable; ub render-template "/etc/confluent/docker/${COMPONENT}.properties.template" > "/etc/${COMPONENT}/${COMPONENT}.properties"; ub render-template /etc/confluent/docker/log4j2.yaml.template > /etc/kafka/log4j2.yaml; ub render-template /etc/confluent/docker/tools-log4j2.yaml.template > /etc/kafka/tools-log4j2.yaml; /etc/confluent/docker/ensure; exec /etc/confluent/docker/launch'
            self.docker("run", "-d", "--name", controller, "--network", prefix, "--network-alias", "controller", *env_args(controller_env), image, "bash", "-ec", start)
            broker_env = dict(shared, KAFKA_PROCESS_ROLES="broker", KAFKA_NODE_ID="1", KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR="1",
                              KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://kafka-0:9092", KAFKA_LISTENER_SECURITY_PROTOCOL_MAP="PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT",
                              BM_KAFKA_REMOTE_ENABLED="true", BM_KAFKA_REMOTE_BROKERS="kafka-0:9094")
            self.docker("run", "-d", "--name", broker, "--hostname", "kafka-0", "--network", prefix, "--network-alias", "kafka-0",
                        "--mount", f"type=bind,source={ROOT / 'k8s/files'},target=/opt/bm-cluster,readonly", *env_args(broker_env), image, "bash", "/opt/bm-cluster/kafka-remote-start.sh")
            for _ in range(90):
                if "Transition from STARTING to STARTED" in self.docker("logs", broker):
                    break
                time.sleep(0.5)
            else:
                self.fail("Disposable Kafka did not start with the managed remote listener")
            def execute(*args, payload=None):
                return self.docker("exec", "-i", broker, *args, payload=payload)
            for env in ("int", "uat"):
                with patch.object(data, "credentials", return_value={"username": "devapp_" + env, "password": env * 20}), patch.object(data, "kafka", side_effect=execute):
                    data.provision_kafka(None, data.identity("devapp", env))
                config = f'security.protocol=SASL_PLAINTEXT\nsasl.mechanism=SCRAM-SHA-512\nsasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="devapp_{env}" password="{env * 20}";\ndefault.api.timeout.ms=5000\nrequest.timeout.ms=5000\n'
                execute("sh", "-ec", 'cat > "$1"', "config", "/tmp/" + env + ".properties", payload=config)
            execute("kafka-topics", "--bootstrap-server", "kafka-0:9094", "--command-config", "/tmp/int.properties", "--create", "--topic", "devapp.int.order_topic", "--partitions", "1", "--replication-factor", "1")
            execute("kafka-console-producer", "--bootstrap-server", "kafka-0:9094", "--producer.config", "/tmp/int.properties", "--topic", "devapp.int.order_topic", "--producer-property", "enable.idempotence=true", payload="environment-isolation\n")
            received = execute("kafka-console-consumer", "--bootstrap-server", "kafka-0:9094", "--consumer.config", "/tmp/int.properties", "--topic", "devapp.int.order_topic", "--group", "devapp.int.fixture", "--from-beginning", "--max-messages", "1", "--timeout-ms", "10000")
            self.assertIn("environment-isolation", received)
            for credential, group, error in (("uat", "devapp.uat.fixture", "TopicAuthorizationException"), ("int", "devapp.uat.fixture", "GroupAuthorizationException")):
                result = subprocess.run(["docker", "exec", broker, "kafka-console-consumer", "--bootstrap-server", "kafka-0:9094", "--consumer.config", "/tmp/" + credential + ".properties", "--topic", "devapp.int.order_topic", "--group", group, "--from-beginning", "--max-messages", "1", "--timeout-ms", "5000"], text=True, capture_output=True, timeout=30)
                self.assertNotIn("environment-isolation", result.stdout)
                self.assertIn(error, result.stderr)
        finally:
            self.docker("rm", "-f", broker, controller, check=False)
            self.docker("network", "rm", prefix, check=False)


if __name__ == "__main__":
    unittest.main()
