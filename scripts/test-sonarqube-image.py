#!/usr/bin/env python3
"""Test a candidate on disposable Docker volumes, including an actual analysis.

Requires Docker, Java/javac 21+ and a verified SonarScanner CLI jar. The server
binds only to a random loopback port. No cluster data or credentials are used.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import uuid


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--scanner", required=True, type=Path)
    parser.add_argument("--logs", required=True, type=Path)
    args = parser.parse_args()
    args.scanner = args.scanner.resolve(strict=True)
    args.logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    name = "sonar-security-fixture-" + uuid.uuid4().hex[:12]
    volumes = [name + "-" + kind for kind in ("data", "extensions", "logs", "temp")]
    mounted = []
    for kind, volume in zip(("data", "extensions", "logs", "temp"), volumes):
        mounted += ["-v", volume + ":/opt/sonarqube/" + kind]
    auth = "Basic " + base64.b64encode(b"admin:admin").decode()
    endpoint = ""

    def api(path, fields=None):
        request = urllib.request.Request(endpoint + "/api/" + path,
            data=urllib.parse.urlencode(fields).encode() if fields is not None else None,
            headers={"Authorization": auth})
        with urllib.request.urlopen(request, timeout=15) as response:
            data = response.read()
        return json.loads(data) if data else None

    def permissions(owner):
        # Only the four disposable named volumes are mounted. Simulate kubelet's
        # fsGroup walk while keeping the old UID after the second startup.
        command = "for d in data extensions logs temp; do "
        command += f"chown -R {owner}:10001 /opt/sonarqube/$d; "
        command += "chmod -R g+rwX /opt/sonarqube/$d; done"
        run(["docker", "run", "--rm", "--network=none", "--read-only", "--user=0",
             "--cap-drop=ALL", "--cap-add=CHOWN", "--cap-add=FOWNER", "--cap-add=DAC_OVERRIDE",
             "--security-opt=no-new-privileges", *mounted, "--entrypoint=sh", args.image,
             "-ec", command], stdout=subprocess.DEVNULL)

    def start():
        nonlocal endpoint
        command = ["docker", "run", "-d", "--name", name, "--read-only", "--user=10001:10001",
            "--cap-drop=ALL", "--security-opt=no-new-privileges", "--memory=2g", "--cpus=1",
            "--pids-limit=512", "-p", "127.0.0.1::9000", *mounted,
            "--tmpfs", "/tmp:uid=10001,gid=10001,mode=770,exec",
            "-e", "SONAR_WEB_JAVAOPTS=-Xms128m -Xmx384m",
            "-e", "SONAR_CE_JAVAOPTS=-Xms128m -Xmx384m",
            "-e", "SONAR_SEARCH_JAVAOPTS=-Xms256m -Xmx256m", args.image]
        run(command, stdout=subprocess.DEVNULL)
        port = subprocess.check_output(["docker", "port", name, "9000/tcp"], text=True).strip().rsplit(":", 1)[1]
        endpoint = "http://127.0.0.1:" + port
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            state = json.loads(subprocess.check_output(["docker", "inspect", name], text=True))[0]["State"]
            if not state["Running"]:
                raise RuntimeError("Candidate exited before becoming ready")
            try:
                if api("system/status")["status"] == "UP":
                    return
            except (OSError, ValueError):
                pass
            time.sleep(3)
        raise TimeoutError("Candidate did not become ready in ten minutes")

    def save_logs(stage):
        result = subprocess.run(["docker", "logs", name], capture_output=True)
        (args.logs / (stage + ".log")).write_bytes(result.stdout + result.stderr)

    def stop():
        run(["docker", "stop", "--time=60", name], stdout=subprocess.DEVNULL)
        run(["docker", "rm", name], stdout=subprocess.DEVNULL)

    def measures():
        result = api("measures/component?component=security-fixture&metricKeys=ncloc,ncloc_language_distribution")
        values = {entry["metric"]: entry["value"] for entry in result["component"]["measures"]}
        if int(values["ncloc"]) < 3:
            raise AssertionError("Expected all fixture sources to be analyzed")
        languages = {item.split("=")[0] for item in values["ncloc_language_distribution"].split(";")}
        if not {"java", "js", "py"} <= languages:
            raise AssertionError("Missing language analysis: " + str(languages))
        return values

    try:
        fixture = Path(__file__).resolve().parents[1] / "images/security/tests/SonarSshFixture.java"
        with (args.logs / "ssh-regression.log").open("w") as log:
            run(["docker", "run", "--rm", "--network=none", "--read-only", "--user=10001:10001",
                "--cap-drop=ALL", "--security-opt=no-new-privileges", "--memory=512m", "--cpus=1",
                "--tmpfs", "/tmp:uid=10001,gid=10001,mode=770,exec", "-v", str(fixture) + ":/fixture.java:ro",
                "--entrypoint=sh", args.image, "-ec",
                "cp /fixture.java /tmp/SonarSshFixture.java; "
                "scanner=/opt/sonarqube/lib/scanner/sonar-scanner-engine-community-13.4.1.4007.jar; "
                "javac -d /tmp -cp \"$scanner\" /tmp/SonarSshFixture.java; "
                "java -cp \"$scanner:/tmp\" SonarSshFixture"], stdout=log, stderr=log, timeout=90)
        print("Ed25519 regression, Apache SSHD and unchanged SVNKit client passed", flush=True)
        for volume in volumes:
            run(["docker", "volume", "create", "--label", "disk-cleanup.disposable=true", volume], stdout=subprocess.DEVNULL)
        permissions(10001)
        start()
        password = "Fixture-" + secrets.token_hex(20) + "!4"
        api("users/change_password", {"login": "admin", "previousPassword": "admin", "password": password})
        auth = "Basic " + base64.b64encode(("admin:" + password).encode()).decode()
        token = api("user_tokens/generate", {"name": "disposable-fixture"})["token"]
        auth = "Bearer " + token
        with tempfile.TemporaryDirectory(prefix="sonar-analysis-") as directory:
            source = Path(directory)
            (source / "src").mkdir()
            (source / "classes").mkdir()
            (source / "src/Example.java").write_text("public class Example {\n public int add(int left, int right) {\n return left + right;\n }\n}\n")
            (source / "src/example.js").write_text("export function add(left, right) {\n return left + right;\n}\n")
            (source / "src/example.py").write_text("def add(left, right):\n    return left + right\n")
            run(["javac", "-d", "classes", "src/Example.java"], cwd=source)
            with (args.logs / "analysis.log").open("w") as log:
                run(["java", "-jar", str(args.scanner), "-Dsonar.projectKey=security-fixture",
                    "-Dsonar.sources=src", "-Dsonar.java.binaries=classes", "-Dsonar.host.url=" + endpoint,
                    "-Dsonar.scanner.skipJreProvisioning=true", "-Dsonar.scm.disabled=true"],
                    cwd=source, env={**os.environ, "SONAR_TOKEN": token, "SONAR_USER_HOME": str(source / ".sonar")},
                    stdout=log, stderr=log, timeout=600)
            report = dict(line.split("=", 1) for line in (source / ".scannerwork/report-task.txt").read_text().splitlines())
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            task = api("ce/task?id=" + urllib.parse.quote(report["ceTaskId"], safe=""))["task"]
            if task["status"] == "SUCCESS":
                break
            if task["status"] in ("FAILED", "CANCELED"):
                raise RuntimeError("Analysis processing failed: " + task.get("errorMessage", task["status"]))
            time.sleep(3)
        else:
            raise TimeoutError("Analysis processing did not finish")
        before = measures()
        print("Java, JavaScript and Python analysis processed successfully", flush=True)
        save_logs("fresh-volume")
        stop()
        permissions(1000)
        start()
        if measures() != before:
            raise AssertionError("Persisted analysis changed after the volume permission migration")
        print("Existing files owned by UID 1000 remain usable with fsGroup/UID 10001 after restart", flush=True)
        save_logs("old-owner-volume")
    finally:
        save_logs("final")
        subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for volume in volumes:
            subprocess.run(["docker", "volume", "rm", volume], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
