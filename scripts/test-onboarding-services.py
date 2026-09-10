#!/usr/bin/env python3
"""Offline service-contract checks; no cluster or provider calls are made."""

import base64
from contextlib import nullcontext
from copy import deepcopy
from http.server import BaseHTTPRequestHandler, HTTPServer
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

SPEC = importlib.util.spec_from_file_location("onboarding_services", Path(__file__).parent / "lib/onboarding_services.py")
services = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(services)
CONTEXT = {"APPLICATION_NAME": "sample", "PUBLIC_DOMAIN": "example.com", "APP_HOST": "sample.example.com",
           "GITLAB_PROJECT_ID": 7, "GITLAB_PROJECT_PATH": "team/sample",
           "GITLAB_PUBLIC_URL": "https://gitlab.example.com", "GITLAB_INTERNAL_URL": "http://gitlab.internal.example.com",
           "REGISTRY_HOST": "registry.example.com", "KEYCLOAK_REALM": "customers"}
TUNNEL = "00000000-1111-2222-3333-444444444444"
CLIENT = {"clientId": "sample-web", "publicClient": True, "protocol": "openid-connect", "standardFlowEnabled": True,
          "rootUrl": "https://sample.example.com", "redirectUris": ["https://sample.example.com/*"],
          "webOrigins": ["https://sample.example.com"], "attributes": {"pkce.code.challenge.method": "S256"},
          "defaultClientScopes": ["profile", "email"], "optionalClientScopes": ["groups"],
          "protocolMappers": [{"name": "groups", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper",
                               "config": {"claim.name": "groups"}}]}


class Vault:
    def __init__(self):
        self.values, self.calls = {}, []
        self.race = None

    def request(self, method, path, data=None, **_kwargs):
        self.calls.append((method, path, deepcopy(data)))
        if path == "/v1/sys/capabilities-self":
            return {name: ["root"] for name in data["paths"]}
        if "/metadata/" in path:
            return None
        key = path.split("/data/", 1)[1]
        if method == "GET":
            if key not in self.values:
                return None
            fields, version = self.values[key]
            return {"data": {"data": deepcopy(fields), "metadata": {"version": version}}}
        if self.race:
            callback, self.race = self.race, None
            callback(self, key)
        version = self.values.get(key, ({}, 0))[1]
        if data["options"]["cas"] != version:
            raise services.HTTPFailure(400, cas=True)
        self.values[key] = deepcopy(data["data"]), version + 1
        return {"data": {"version": version + 1}}


class GitLab:
    def __init__(self):
        self.tokens, self.calls = [], []
        self.last_id = 20

    def call(self, method, path, data=None, **_kwargs):
        self.calls.append((method, path, deepcopy(data)))
        if method == "GET" and path == "projects/7":
            return {"path_with_namespace": "team/sample", "visibility": "private"}
        if method == "GET" and "/deploy_tokens?" in path:
            return deepcopy(self.tokens)
        if method == "POST" and path == "projects/7/deploy_tokens":
            self.last_id += 1
            token = {"id": self.last_id, "username": f"reader-{self.last_id}",
                     "token": f"private-password-{self.last_id}", "revoked": False, **data}
            self.tokens.append(token)
            return deepcopy(token)
        if method == "DELETE":
            next(item for item in self.tokens if str(item["id"]) == path.rsplit("/", 1)[1])["revoked"] = True
            return None
        raise AssertionError((method, path))


class Keycloak:
    def __init__(self, existing=True):
        self.client = {**deepcopy(CLIENT), "id": "original-client"} if existing else None
        self.scopes = {name: "scope-" + name for name in ("profile", "email", "groups", "roles", "offline_access")}
        self.assignments = {"default": {"profile", "roles", "groups"}, "optional": {"email", "offline_access"}}
        self.mappers = [{"id": "original-mapper", "name": "groups", "config": {}}, {"id": "other-mapper", "name": "operator-owned"}]
        self.calls = []

    def request(self, method, path, data=None, **_kwargs):
        self.calls.append((method, path, deepcopy(data)))
        if path.endswith("/customers"):
            return {"realm": "customers"}
        if path.endswith("/client-scopes"):
            return [{"name": name, "id": value} for name, value in self.scopes.items()]
        if "?clientId=" in path:
            return [deepcopy(self.client)] if self.client else []
        if path.endswith("/clients") and method == "POST":
            self.client = {**deepcopy(data), "id": "new-client"}
            self.mappers = [{**deepcopy(mapper), "id": "new-mapper"} for mapper in data.get("protocolMappers", [])]
            return None
        for mode in self.assignments:
            if f"/{mode}-client-scopes" in path:
                if method == "GET":
                    return [{"name": name, "id": self.scopes[name]} for name in self.assignments[mode]]
                scope = next(name for name, value in self.scopes.items() if value == path.rsplit("/", 1)[1])
                if method == "DELETE":
                    self.assignments[mode].remove(scope)
                else:
                    other = "optional" if mode == "default" else "default"
                    assert scope not in self.assignments[other]
                    self.assignments[mode].add(scope)
                return None
        if "/protocol-mappers/models" in path:
            if method == "GET":
                return deepcopy(self.mappers)
            if method == "POST":
                self.mappers.append({**deepcopy(data), "id": "extra-mapper"})
            else:
                index = next(i for i, item in enumerate(self.mappers) if item["id"] == data["id"])
                self.mappers[index] = deepcopy(data)
            return None
        if method == "GET":
            return deepcopy(self.client)
        if method == "PUT":
            # Scope properties are deliberately ignored, as in Keycloak 26.
            self.client.update({key: deepcopy(value) for key, value in data.items()
                                if key not in ("defaultClientScopes", "optionalClientScopes")})
            return None
        raise AssertionError((method, path))


class Cloudflare:
    def __init__(self):
        self.records, self.calls = [], []
        self.ineffective = False

    def request(self, method, path, data=None, **_kwargs):
        self.calls.append((method, path, deepcopy(data)))
        parsed = urlparse(path)
        if parsed.path == "/zones":
            result = [{"id": "zone-1", "name": "example.com"}]
        elif method == "GET":
            name = parse_qs(parsed.query)["name"][0]
            result = [deepcopy(item) for item in self.records if item["name"] == name]
        elif self.ineffective:
            result = {}
        elif method == "POST":
            result = {**deepcopy(data), "id": "record-" + str(len(self.records))}
            self.records.append(result)
        elif method == "PUT":
            record_id = parsed.path.rsplit("/", 1)[1]
            index = next(i for i, item in enumerate(self.records) if item["id"] == record_id)
            result = {**deepcopy(data), "id": record_id}
            self.records[index] = result
        else:
            raise AssertionError((method, path))
        return {"success": True, "result": result}


class ServicesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "client.json").write_text(json.dumps(CLIENT))
        self.vault, self.gitlab, self.identity, self.cf = Vault(), GitLab(), Keycloak(), Cloudflare()
        self.state, self.ingresses = None, []
        self.service = services.Services(self.gitlab, self.kubectl, CONTEXT)
        self.service._vault = lambda: nullcontext(self.vault)
        self.service._keycloak = lambda: nullcontext(self.identity)
        self.service._cf = lambda: self.cf

    def kubectl(self, *args, **_kwargs):
        if args[:2] == ("get", "configmap"):
            return deepcopy(self.state)
        if args[:2] == ("get", "service"):
            return {"status": {"loadBalancer": {"ingress": [{"ip": "51.68.232.240"}]}}}
        if args[:2] == ("get", "ingresses"):
            return {"items": deepcopy(self.ingresses)}
        raise AssertionError(args)

    def registry_auth(self, base, headers):
        testcase = self
        class Repository:
            def request(self, method, path, **_kwargs):
                actual = base64.b64decode(headers["Authorization"].split()[1]).decode()
                if any(actual == f"{token['username']}:{token['token']}" and not token.get("revoked")
                       for token in testcase.gitlab.tokens):
                    return {"token": "private-jwt"} if path.startswith("/jwt/auth") else b"001e# service=git-upload-pack\n0000"
                raise services.HTTPFailure(401)
        return Repository()

    def test_preflight_is_read_only_and_secret_input_errors_precede_writes(self):
        contract = {"registry": {"path": "apps/sample/registry"},
                    "vault": [{"path": "apps/sample/runtime", "fields": {"KEY": {"input": "RUNTIME_KEY"}}}],
                    "keycloak": {"file": "client.json", "realm": "customers"}, "dns": {"hosts": ["sample.example.com"]}}
        with self.assertRaisesRegex(services.ServiceError, "Missing secret input"):
            self.service.preflight(contract, self.root)
        self.service.secret_inputs["RUNTIME_KEY"] = "operator-private-input"
        outcome = self.service.preflight(contract, self.root)
        self.assertEqual(outcome["status"], "ready")
        self.assertNotIn("operator-private-input", json.dumps(outcome))
        self.assertTrue(all(method == "GET" for method, _, _ in self.gitlab.calls))
        self.assertTrue(all(method == "GET" for method, _, _ in self.identity.calls))
        self.assertTrue(all(method == "GET" for method, _, _ in self.cf.calls))
        self.assertEqual(self.vault.values, {})

    def test_vault_rerun_retains_secrets_and_fills_only_missing_fields(self):
        contract = {"vault": [{"path": "apps/sample/runtime", "fields": {
            "KEY": {"generate": 24, "encoding": "hex"}, "ENCODED": {"generate": 24, "encoding": "base64"},
            "USER": {"value": "sample"}}}]}
        self.vault.values["apps/sample/runtime"] = ({"KEY": "original-password", "unrelated": "retain"}, 3)
        self.service.provision(contract, self.root)
        first = deepcopy(self.vault.values)
        self.service.provision(contract, self.root)
        self.assertEqual(first, self.vault.values)
        result = first["apps/sample/runtime"][0]
        self.assertEqual(result["KEY"], "original-password")
        self.assertEqual(result["unrelated"], "retain")
        self.assertEqual(len(base64.b64decode(result["ENCODED"])), 24)

    def test_literal_defaults_preserve_custom_database_and_optional_credentials(self):
        contract = {"vault": [{"path": "apps/sample/runtime", "fields": {
            "DATABASE": {"value": "sample"}, "API_KEY": {"value": ""}, "OPTIONAL": {"value": ""}}}]}
        self.vault.values["apps/sample/runtime"] = ({"DATABASE": "custom_database", "API_KEY": "real-operator-api-key"}, 4)
        self.service.preflight(contract, self.root)
        self.service.provision(contract, self.root)
        self.service.provision(contract, self.root)
        self.assertEqual(self.vault.values["apps/sample/runtime"], ({
            "DATABASE": "custom_database", "API_KEY": "real-operator-api-key", "OPTIONAL": ""}, 5))

    def test_vault_cas_race_preserves_the_winning_password(self):
        contract = {"vault": [{"path": "apps/sample/runtime", "fields": {"PASSWORD": {"generate": 24}, "USER": {"value": "sample"}}}]}
        self.vault.race = lambda api, path: api.values.update({path: ({"PASSWORD": "winner-secret"}, 1)})
        self.service.provision(contract, self.root)
        self.assertEqual(self.vault.values["apps/sample/runtime"], ({"PASSWORD": "winner-secret", "USER": "sample"}, 2))

    def test_existing_input_is_never_replaced_silently(self):
        self.vault.values["apps/sample/runtime"] = ({"PASSWORD": "original"}, 1)
        self.service.secret_inputs["PASSWORD"] = "replacement"
        with self.assertRaisesRegex(services.ServiceError, "rotate it explicitly"):
            self.service.provision({"vault": [{"path": "apps/sample/runtime", "fields": {"PASSWORD": {"input": "PASSWORD"}}}]}, self.root)
        self.assertEqual(self.vault.values["apps/sample/runtime"][0]["PASSWORD"], "original")

    def test_vault_tombstone_is_not_treated_as_new_secret(self):
        class Deleted:
            def request(self, _method, path, **_kwargs):
                return {"data": {"current_version": 2}} if "/metadata/" in path else None
        with self.assertRaisesRegex(services.ServiceError, "explicit recovery"):
            self.service._kv_get(Deleted(), "apps/sample/runtime")

    def test_registry_creation_rerun_and_revoked_token_replacement(self):
        contract = {"registry": {"path": "apps/sample/registry"}}
        with patch.object(services, "HTTP", side_effect=self.registry_auth):
            self.service.provision(contract, self.root)
            first = deepcopy(self.vault.values)
            self.service.provision(contract, self.root)
            self.assertEqual(first, self.vault.values)
            self.assertEqual(len(self.gitlab.tokens), 1)
            self.gitlab.tokens[0]["revoked"] = True
            result = self.service.provision(contract, self.root)
        self.assertEqual(len(self.gitlab.tokens), 2)
        self.assertNotEqual(first, self.vault.values)
        self.assertEqual(self.gitlab.tokens[1]["scopes"], ["read_repository", "read_registry"])
        self.assertNotIn("private-password", json.dumps(result))
        self.assertFalse(any(method == "PUT" for method, _, _ in self.gitlab.calls))

    def test_registry_cas_conflict_revokes_only_the_new_unused_token(self):
        contract = {"registry": {"path": "apps/sample/registry"}}
        def concurrent(api, path):
            token = self.gitlab.call("POST", "projects/7/deploy_tokens", {"name": "other-operator", "scopes": ["read_repository", "read_registry"]})
            api.values[path] = {"registry": CONTEXT["REGISTRY_HOST"], "username": token["username"], "password": token["token"]}, 1
        self.vault.race = concurrent
        with patch.object(services, "HTTP", side_effect=self.registry_auth):
            self.service.provision(contract, self.root)
        self.assertTrue(self.gitlab.tokens[0]["revoked"])
        self.assertFalse(self.gitlab.tokens[1]["revoked"])
        self.assertEqual(self.vault.values["apps/sample/registry"][0]["username"], self.gitlab.tokens[1]["username"])

    def test_registry_lost_vault_response_never_revokes_a_published_token(self):
        contract = {"registry": {"path": "apps/sample/registry"}}
        original = self.vault.request
        def lost_response(method, path, data=None, **kwargs):
            result = original(method, path, data, **kwargs)
            if method == "POST" and "/data/" in path:
                raise services.ServiceError("Response was lost")
            return result
        self.vault.request = lost_response
        with patch.object(services, "HTTP", side_effect=self.registry_auth):
            with self.assertRaisesRegex(services.ServiceError, "Response was lost"):
                self.service.provision(contract, self.root)
            self.assertFalse(self.gitlab.tokens[0]["revoked"])
            self.vault.request = original
            self.service.provision(contract, self.root)
        self.assertEqual(len(self.gitlab.tokens), 1)

    def test_registry_503_does_not_rotate_credentials(self):
        contract = {"registry": {"path": "apps/sample/registry"}}
        with patch.object(services, "HTTP", side_effect=self.registry_auth):
            self.service.provision(contract, self.root)
        class Unavailable:
            def request(self, *_args, **_kwargs):
                raise services.HTTPFailure(503)
        with patch.object(services, "HTTP", return_value=Unavailable()), self.assertRaises(services.HTTPFailure):
            self.service.provision(contract, self.root)
        self.assertEqual(len(self.gitlab.tokens), 1)

    def test_keycloak_preserves_identity_and_unrelated_mapper_and_repairs_scopes(self):
        contract = {"keycloak": {"file": "client.json", "realm": "customers"}}
        self.service.provision(contract, self.root)
        self.service.provision(contract, self.root)
        self.assertEqual(self.identity.client["id"], "original-client")
        self.assertEqual(self.identity.assignments, {"default": {"profile", "email"}, "optional": {"groups", "offline_access"}})
        self.assertEqual(self.identity.mappers[0]["id"], "original-mapper")
        self.assertEqual(self.identity.mappers[1], {"id": "other-mapper", "name": "operator-owned"})
        self.assertEqual(self.identity.client["attributes"]["bm-cluster.onboarding.project"], "team/sample")

    def test_keycloak_collision_and_missing_scope_fail_before_mutation(self):
        contract = {"keycloak": {"file": "client.json", "realm": "customers"}}
        self.identity.client["rootUrl"] = "https://unrelated.example.com"
        with self.assertRaisesRegex(services.ServiceError, "ownership"):
            self.service.preflight(contract, self.root)
        self.assertTrue(all(method == "GET" for method, _, _ in self.identity.calls))
        self.identity.client = deepcopy(CLIENT)
        self.identity.client["id"] = "original-client"
        del self.identity.scopes["groups"]
        with self.assertRaisesRegex(services.ServiceError, "scopes are missing"):
            self.service.preflight(contract, self.root)

    def test_contract_cannot_escape_app_paths_or_import_local_realm_users(self):
        for path in ["infra/gitlab", "apps/other/runtime", "apps/sample/../other", "apps/sample//secret"]:
            with self.subTest(path=path), self.assertRaises(services.ServiceError):
                self.service.preflight({"registry": {"path": path}}, self.root)
        (self.root / "client.json").write_text(json.dumps({"realm": "master", "users": [{"username": "test"}]}))
        with self.assertRaises(services.ServiceError):
            self.service.preflight({"keycloak": {"file": "client.json"}}, self.root)

    def test_dns_publication_rejects_wildcards_even_without_preflight(self):
        for hosts in [["*.example.com"], ["external.invalid"], ["sample.example.com", "sample.example.com"]]:
            with self.subTest(hosts=hosts), self.assertRaises(services.ServiceError):
                self.service.publish_dns({"dns": {"hosts": hosts}})
        self.assertEqual(self.cf.calls, [])

    def test_dns_waits_for_published_matching_zone_and_rejects_conflicts(self):
        contract = {"dns": {"hosts": ["sample.example.com"]}}
        self.state = {"data": {"mode": "tunnel", "domain": "example.com", "tunnelID": TUNNEL, "publishedTunnelID": ""}}
        with self.assertRaisesRegex(services.ServiceError, "has not been published"):
            self.service.preflight(contract, self.root)
        self.assertEqual(self.cf.calls, [])
        self.state["data"]["publishedTunnelID"] = TUNNEL
        self.state["data"]["domain"] = "other.example"
        with self.assertRaises(services.ServiceError):
            self.service.publish_dns(contract)
        self.state["data"]["domain"] = "example.com"
        self.cf.records = [{"id": "old", "name": "sample.example.com", "type": "A", "content": "8.8.8.8"}]
        with self.assertRaisesRegex(services.ServiceError, "another origin"):
            self.service.publish_dns(contract)

    def test_dns_preserves_mail_and_unrelated_records_and_rechecks_write(self):
        contract = {"dns": {"hosts": ["sample.example.com"]}}
        mail = {"id": "mail", "name": "sample.example.com", "type": "TXT", "content": "verification"}
        unrelated = {"id": "other", "name": "other.example.com", "type": "A", "content": "8.8.8.8"}
        self.cf.records = [mail, unrelated]
        self.service.preflight(contract, self.root)
        self.assertEqual(len(self.cf.records), 2)
        self.service.publish_dns(contract)
        self.service.publish_dns(contract)
        self.assertIn(mail, self.cf.records)
        self.assertIn(unrelated, self.cf.records)
        self.assertEqual(len(self.cf.records), 3)
        self.assertEqual(sum(method == "POST" for method, _, _ in self.cf.calls), 1)
        self.cf.records = []
        self.cf.ineffective = True
        with self.assertRaisesRegex(services.ServiceError, "did not converge"):
            self.service.publish_dns(contract)

    def test_dns_legacy_adoption_requires_the_matching_application_ingress(self):
        contract = {"dns": {"hosts": ["sample.example.com"]}}
        self.state = {"data": {"mode": "tunnel", "domain": "example.com", "tunnelID": TUNNEL, "publishedTunnelID": TUNNEL}}
        self.cf.records = [{"id": "old", "name": "sample.example.com", "type": "A", "content": "51.68.232.240",
                            "comment": "Managed by bm-cluster/scripts/configure-cloudflare.sh"}]
        with self.assertRaises(services.ServiceError):
            self.service.publish_dns(contract)
        self.ingresses = [{"metadata": {"namespace": "apps", "annotations": {"argocd.argoproj.io/tracking-id": "other:networking.k8s.io/Ingress:apps/other"}},
                           "spec": {"rules": [{"host": "sample.example.com"}]}}]
        with self.assertRaisesRegex(services.ServiceError, "different or unowned Ingress"):
            self.service.publish_dns(contract)
        self.ingresses[0]["metadata"]["annotations"]["argocd.argoproj.io/tracking-id"] = "sample:networking.k8s.io/Ingress:apps/sample"
        self.service.publish_dns(contract)
        self.assertEqual(self.cf.records[0]["content"], TUNNEL + ".cfargotunnel.com")


class HTTPTests(unittest.TestCase):
    def test_missing_is_only_404_and_redirects_do_not_receive_credentials(self):
        calls = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                calls.append(self.path)
                code = {"/missing": 404, "/denied": 403, "/redirect": 302}.get(self.path, 200)
                self.send_response(code)
                if code == 302:
                    self.send_header("Location", "/capture-secret")
                self.end_headers()
                self.wfile.write(b'private-token-never-log')
            def log_message(self, *_args):
                pass
        with HTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                api = services.HTTP(f"http://127.0.0.1:{server.server_port}", {"Authorization": "Bearer private-token-never-log"})
                self.assertIsNone(api.request("GET", "/missing", missing=True))
                for path in ("/denied", "/redirect"):
                    with self.assertRaises(services.HTTPFailure) as failure:
                        api.request("GET", path, missing=True)
                    self.assertNotIn("private-token", str(failure.exception))
                self.assertNotIn("/capture-secret", calls)
            finally:
                server.shutdown()
                thread.join()


if __name__ == "__main__":
    unittest.main()
