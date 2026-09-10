#!/usr/bin/env python3
"""Run the real Ansible entrypoints against isolated host/cluster substitutes."""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SECRET = "fixture-secret-never-in-ansible-output"
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, stat, subprocess, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
public = ("PLATFORM_DOMAIN", "CONFIGURE_REPOSITORY_SYNC", "GITHUB_USERNAME",
          "GITHUB_REPOSITORIES", "DEPLOY_REPOSITORIES", "CLOUDFLARE_ENABLE_ACCESS",
          "K3S_PRIVATE_ADDRESS", "K3S_PRIVATE_INTERFACE", "K3S_NODE_NETWORK_CIDR",
          "CONTROL_PLANE_COUNT", "CLUSTER_NODE_COUNT", "K3S_CONTROL_PLANE_IPS",
          "K3S_WORKER_IPS", "SERVER_EXPOSURE", "HIGH_AVAILABILITY_ENABLED",
          "CLOUDFLARE_PUBLISH_NODE_DNS")
entry = {"tool": name, "args": args,
         "env": {key: os.environ[key] for key in public if key in os.environ},
         "github_token_present": bool(os.environ.get("GITHUB_ADMIN_TOKEN"))}
with open(os.environ["MOCK_LOG"], "a") as output:
    output.write(json.dumps(entry) + "\n")
if name == os.environ.get("MOCK_FAIL"):
    sys.exit(42)
if name == "systemctl":
    sys.exit(1 if os.environ.get("MOCK_NO_K3S") else 0)
if name == "kubectl":
    if 'configmap' in args and os.environ.get('MOCK_HA'):
        pg = {"enabled": True, "active": True, "bootstrapOwner": "admin", "bootstrapDatabase": "appdb",
              "storageSize": "2Gi", "image": "ghcr.io/cloudnative-pg/postgresql:18.6-system-bookworm"}
        data = {"highAvailabilityEnabled": "true"} if 'bm-cluster-topology' in args else {"phase": "active", "postgresHa": json.dumps(pg)}
        if 'kafka-ha-state' in args:
            data = {"phase": "active", "kafkaHa": json.dumps({"enabled": True, "phase": "active", "clusterId": "fixture", "bootstrap": False})}
        print('true' if any('jsonpath=' in arg for arg in args) else json.dumps({"data": data}))
    elif args[:2] == ["get", "node"]:
        labels = {"node-role.kubernetes.io/control-plane": "true",
                  "svccontroller.k3s.cattle.io/enablelb": os.environ.get("MOCK_INGRESS", "true")}
        if os.environ.get('MOCK_HA'):
            labels['node.bm-cluster.io/exposure'] = 'local'
        if os.environ.get('MOCK_WORKER'):
            labels.pop('node-role.kubernetes.io/control-plane')
        print(json.dumps({"metadata": {"labels": labels}}))
    elif args[:2] == ["get", "nodes"]:
        print("worker-01 Ready worker 1d v1.36.4+k3s1\nworker-02 Ready worker 1d v1.36.4+k3s1")
    elif args[:2] == ["get", "secret"]:
        namespace = args[args.index("-n") + 1]
        sys.exit(0 if (pathlib.Path(os.environ["MOCK_TLS"]) / namespace).exists() else 1)
    elif args[:3] == ["create", "secret", "tls"]:
        namespace = args[args.index("-n") + 1]
        cert = pathlib.Path(next(a.split("=", 1)[1] for a in args if a.startswith("--cert=")))
        key = pathlib.Path(next(a.split("=", 1)[1] for a in args if a.startswith("--key=")))
        assert stat.S_IMODE(key.stat().st_mode) == 0o600
        details = subprocess.check_output(["openssl", "x509", "-in", str(cert), "-noout", "-ext", "subjectAltName"], text=True)
        assert "DNS:example.com" in details and "DNS:*.example.com" in details
        (pathlib.Path(os.environ["MOCK_TLS"]) / namespace).write_text(details)
    elif "-f" in args:
        target = args[args.index("-f") + 1]
        if target == "-":
            sys.stdin.read()
        else:
            assert pathlib.Path(target).is_file(), "Expected a manifest file: " + target
        print("resource configured")
    elif args[:2] == ["create", "namespace"]:
        print("apiVersion: v1\nkind: Namespace\nmetadata:\n  name: infra")
    elif args[:2] == ["get", "pods"]:
        print("fixture 1/1 Running")
elif name == "configure-tailscale.sh":
    assert sys.stdin.read().strip()
    print("100.100.10.1")
elif name == "configure-ovh-vrack.sh":
    print("eno2")
elif name in ("add-repos.sh", "install-control-plane.sh"):
    # Even helpers that accidentally echo a credential must stay censored.
    print(os.environ.get("GITHUB_ADMIN_TOKEN", ""))
'''


def exercise(case):
    with tempfile.TemporaryDirectory(prefix=f"bm-cluster-ansible-{case}.") as directory:
        fixture = Path(directory)
        for folder in ("ansible", "config", "k8s"):
            shutil.copytree(ROOT / folder, fixture / folder)
        scripts, commands = fixture / "scripts", fixture / "bin"
        scripts.mkdir()
        commands.mkdir()
        (scripts / "lib").mkdir()
        for name in ("render-cluster-config.sh", "render-security-images.py", "render-platform-ha.py",
                     "resolve-ha-profile.py", "configure-local-tls.sh", "lib/tls.sh"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        for source in (ROOT / "scripts").glob("*.sh"):
            if not (scripts / source.name).exists():
                (scripts / source.name).write_text(MOCK)
                (scripts / source.name).chmod(0o700)
        for target in [commands / name for name in ("kubectl", "helm", "sudo", "systemctl")] + [
            fixture / "add-repos.sh", fixture / "install-control-plane.sh"
        ]:
            target.write_text(MOCK)
            target.chmod(0o700)
        tls = fixture / "tls"
        tls.mkdir()
        log = fixture / "calls.jsonl"
        (fixture / "ansible.cfg").write_text("[defaults]\n")
        env = {
            "PATH": f"{commands}:{os.environ['PATH']}", "LANG": "C.UTF-8",
            "ANSIBLE_CONFIG": str(fixture / "ansible.cfg"), "ANSIBLE_NOCOLOR": "true",
            "ANSIBLE_LOCAL_TEMP": str(fixture / "ansible-tmp"),
            "TMPDIR": str(fixture),
            "MOCK_LOG": str(log), "MOCK_TLS": str(tls),
            "PLATFORM_DOMAIN": "example.com", "CONTROL_PLANE_NODE_NAME": "cp-01",
            "SECURITY_IMAGES_ENABLED": "false",
            "GITOPS_REPOSITORY_URL": "https://github.com/example/bm-cluster.git",
            "KEYCLOAK_SSO_BOOTSTRAP_USERNAME": "platform-admin",
            "KEYCLOAK_SSO_BOOTSTRAP_PASSWORD": SECRET,
            "GITHUB_ADMIN_TOKEN": SECRET, "GITHUB_USERNAME": "example",
            "GITHUB_REPOSITORIES": "example/app-one,example/app-two",
            "DEPLOY_REPOSITORIES": "none", "CONFIGURE_REPOSITORY_SYNC": "true",
        }
        variables = {"ansible_python_interpreter": sys.executable, "server_exposure": "local"}
        playbook, expected_success, check_mode = "deploy.yml", True, False
        if case == "tailscale":
            variables.update(manage_private_transport=True, k3s_node_transport="tailscale")
            env["TAILSCALE_API_TOKEN"] = "tskey-api-fixture"
        elif case == "vrack":
            variables.update(manage_private_transport=True, k3s_node_transport="vrack",
                             k3s_private_address="10.40.0.10", k3s_private_interface="eno2",
                             k3s_node_network_cidr="10.40.0.0/24")
        elif case == "cloudflare":
            variables.update(configure_cloudflare=True, server_exposure="internet")
            env.update(CLOUDFLARE_API_TOKEN=SECRET, CLOUDFLARE_ENABLE_ACCESS="false")
        elif case == "ha":
            # Omitted HIGH_AVAILABILITY_ENABLED must inherit the durable HA
            # mode and may reconcile from a surviving private control plane.
            env.update(MOCK_HA="true", MOCK_INGRESS="false", CLOUDFLARE_API_TOKEN=SECRET,
                       CLOUDFLARE_ENABLE_ACCESS="false")
        elif case == "odoo_dependencies":
            variables.update(deploy_platform_services=False, deploy_data_stores=False, install_vault_stack=False)
        elif case == "platform_infra_only":
            variables.update(install_apps=False)
        elif case == "infra_only":
            variables.update(install_apps=False, deploy_platform_services=False, deploy_data_stores=False,
                             install_vault_stack=False, install_descheduler=False, install_argocd=False)
            env["CONFIGURE_REPOSITORY_SYNC"] = "false"
            env.pop("KEYCLOAK_SSO_BOOTSTRAP_PASSWORD")
        elif case in ("missing_k3s", "private_server", "worker_server", "missing_replication", "helm_failure", "check_mode"):
            expected_success = False
            if case == "missing_k3s":
                env["MOCK_NO_K3S"] = "true"
            elif case == "worker_server":
                env["MOCK_WORKER"] = "true"
            elif case == "private_server":
                env["MOCK_INGRESS"] = "false"
            elif case == "missing_replication":
                env.pop("DEPLOY_REPOSITORIES")
            elif case == "helm_failure":
                env["MOCK_FAIL"] = "helm"
            else:
                check_mode = True
        elif case in ("install", "install_failure", "install_check"):
            playbook = "install.yml"
            variables["installer_environment"] = {
                "PLATFORM_DOMAIN": "example.com", "SERVER_EXPOSURE": "local",
                "CONTROL_PLANE_COUNT": "3", "CLUSTER_NODE_COUNT": "4",
                "K3S_CONTROL_PLANE_IPS": "10.40.0.11,10.40.0.12", "K3S_WORKER_IPS": "10.40.0.20",
                "GITHUB_ADMIN_TOKEN": SECRET,
            }
            if case == "install_failure":
                env["MOCK_FAIL"] = "install-control-plane.sh"
                expected_success = False
            check_mode = case == "install_check"
        extra = fixture / "extra.json"
        extra.write_text(json.dumps(variables))
        result = subprocess.run(
            ["ansible-playbook", "-i", str(fixture / "ansible/inventory"),
             str(fixture / "ansible" / playbook), "-e", f"@{extra}",
             *(["--check"] if check_mode else [])],
            env=env, capture_output=True, text=True, timeout=300,
        )
        output = result.stdout + result.stderr
        assert SECRET not in output, f"{case}: credential leaked in Ansible output"
        assert (result.returncode == 0) == expected_success, f"{case}:\n{output}"
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        assert SECRET not in json.dumps(calls), f"{case}: credential leaked into arguments"
        names = [call["tool"] for call in calls]
        if playbook == "install.yml":
            if check_mode:
                assert not calls
            else:
                install = next(call for call in calls if call["tool"] == "install-control-plane.sh")
                assert install["args"] == ["--yes"] and install["github_token_present"]
                assert install["env"]["CONTROL_PLANE_COUNT"] == "3"
                assert install["env"]["K3S_WORKER_IPS"] == "10.40.0.20"
        elif not expected_success:
            assert "add-repos.sh" not in names
            if case != "helm_failure":
                assert "configure-node-security.sh" not in names and "helm" not in names
        else:
            if case != "infra_only":
                assert names.index("configure-gitlab-ci.sh") < names.index("add-repos.sh")
                gitlab = next(call for call in calls if call["tool"] == "configure-gitlab-ci.sh")
                assert gitlab["env"]["CONFIGURE_REPOSITORY_SYNC"] == "false"
                replica = next(call for call in calls if call["tool"] == "add-repos.sh")
                assert replica["args"] == ["--yes"] and replica["env"]["DEPLOY_REPOSITORIES"] == "none"
                argo = next(i for i, call in enumerate(calls) if call["tool"] == "helm" and "argocd" in call["args"] and "--install" in call["args"])
                assert argo < names.index("add-repos.sh")
            if case in ("tailscale", "vrack"):
                transport = "configure-tailscale.sh" if case == "tailscale" else "configure-ovh-vrack.sh"
                assert names.index(transport) < names.index("configure-k3s-control-plane-network.sh") < names.index("configure-node-security.sh")
                security = next(call for call in calls if call["tool"] == "configure-node-security.sh")
                assert security["env"]["K3S_PRIVATE_INTERFACE"] == ("tailscale0" if case == "tailscale" else "eno2")
            if case in ("cloudflare", "ha"):
                cf = [call for call in calls if call["tool"] == "configure-cloudflare.sh"]
                assert len(cf) == 2 and all(call["env"]["CLOUDFLARE_ENABLE_ACCESS"] == "false" for call in cf)
                assert not list(tls.iterdir())
                if case == 'ha':
                    assert all(call['env']['CLOUDFLARE_PUBLISH_NODE_DNS'] == 'false' for call in cf)
                    ingress = next(call for call in calls if call['tool'] == 'configure-ingress.sh')
                    assert ingress['env']['HIGH_AVAILABILITY_ENABLED'] == 'true'
                    assert 'configure-vault-ha.sh' in names and 'sync-vault-recovery.sh' in names
                    assert names.index('configure-ha-control-planes.sh') < names.index('configure-ingress.sh')
                    security = next(call for call in calls if call['tool'] == 'configure-node-security.sh')
                    assert security['args'][security['args'].index('--server-exposure') + 1] == 'local'
            else:
                assert sorted(p.name for p in tls.iterdir()) == (["apps", "infra"] if case in ("infra_only", "platform_infra_only") else ["apps", "corp", "infra"])
                # Rerunning the shared TLS helper must reuse certificates.
                before = log.read_text()
                subprocess.run([str(scripts / "configure-local-tls.sh"), "--apps-enabled",
                                "false" if case in ("infra_only", "platform_infra_only") else "true"], env=env, check=True, capture_output=True)
                extra_calls = log.read_text()[len(before):]
                assert '"create", "secret"' not in extra_calls
                for call in calls:
                    for arg in call["args"]:
                        if arg.startswith("--key="):
                            assert not Path(arg.split("=", 1)[1]).parent.exists(), "Temporary TLS private key was retained"
            for call in calls:
                if call["tool"] == "kubectl" and call["args"][:1] == ["label"]:
                    assert call["args"][1] == "node/cp-01", "Reconciliation may relabel additional servers"
            if case == "odoo_dependencies":
                assert "configure-vault.sh" in names and "configure-gitlab-ci.sh" in names
            applied = {call["args"][call["args"].index("-f") + 1]
                       for call in calls if call["tool"] == "kubectl" and call["args"][:1] == ["apply"] and "-f" in call["args"]}
            assert any(path.endswith("/base/apps-namespace.yaml") for path in applied)
            if case in ("infra_only", "platform_infra_only"):
                assert not any(path.endswith("/base/corp-namespace.yaml") or path.endswith("/corp/odoo.yaml") for path in applied)
            if case != "infra_only":
                assert any(path.endswith("/apps/security-image-registry.yaml") for path in applied)
                assert any(path.endswith("/apps/sonar-apps-discovery.yaml") for path in applied)
            if case == "infra_only":
                assert "configure-vault.sh" not in names and "configure-gitlab-ci.sh" not in names
        return case


if __name__ == "__main__":
    cases = sys.argv[1:] or [
        "default", "tailscale", "vrack", "cloudflare", "ha", "odoo_dependencies", "infra_only", "platform_infra_only",
        "missing_k3s", "private_server", "worker_server", "missing_replication", "helm_failure", "check_mode",
        "install", "install_failure", "install_check",
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        for case in executor.map(exercise, cases):
            print(f"PASS: Ansible {case}", flush=True)
