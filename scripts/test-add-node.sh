#!/usr/bin/env bash
# Exercise public role/mode selection with isolated enrollment implementations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/.." <<'PY'
import json
import os
from pathlib import Path
import pty
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="bm-add-node-test.") as directory:
    root = Path(directory)
    scripts = root / "scripts"
    scripts.mkdir()
    shutil.copytree(source / "scripts/lib", scripts / "lib")
    shutil.copy2(source / "add-node.sh", root / "add-node.sh")
    for name in ("add-k3s-control-planes.sh", "install-k3s-server.sh"):
        shutil.copy2(source / "scripts" / name, scripts / name)
    mock = '''#!/usr/bin/env python3
import json, os, pathlib, sys
record = {"script": pathlib.Path(__file__).name, "role": os.environ.get("K3S_ENROLLMENT_ROLE"), "args": sys.argv[1:]}
if "--token-stdin" in sys.argv:
    record["token_received"] = sys.stdin.readline().strip() == "fixture-node-token"
pathlib.Path(os.environ["MOCK_RESULT"]).write_text(json.dumps(record))
raise SystemExit(int(os.environ.get("MOCK_EXIT", "0")))
'''
    for name in ("add-k3s-workers.sh", "install-k3s-worker.sh"):
        target = scripts / name
        target.write_text(mock)
        target.chmod(0o700)
    record = root / "result.json"
    environment = dict(os.environ, MOCK_RESULT=str(record), K3S_ENROLLMENT_ROLE="control-plane")

    def run(arguments=(), answers=None, token=None, expected=0, extra_env=None):
        record.unlink(missing_ok=True)
        env = {**environment, **(extra_env or {})}
        if answers is None:
            result = subprocess.run([str(root / "add-node.sh"), *arguments], input=token, text=True,
                                    capture_output=True, env=env, timeout=10)
        else:
            master, slave = pty.openpty()
            try:
                process = subprocess.Popen([str(root / "add-node.sh"), *arguments], stdin=slave, text=True,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
                os.write(master, answers.encode())
                stdout, stderr = process.communicate(timeout=10)
                result = subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
            finally:
                os.close(master)
                os.close(slave)
        assert result.returncode == expected, result.stdout + result.stderr
        assert "fixture-node-token" not in result.stdout + result.stderr
        return json.loads(record.read_text()) if record.exists() else None, result

    for role in ("control-plane", "worker"):
        for mode, backend in (("remote", "add-k3s-workers.sh"), ("local", "install-k3s-worker.sh")):
            current, _ = run(["--role", role, "--mode", mode, "--yes"])
            assert current == {"script": backend, "role": role, "args": ["--non-interactive"]}
            current, _ = run([f"--mode={mode}", f"--role={role}", "--help"])
            assert current["role"] == role and current["args"] == ["--help"]
            current, _ = run(answers=f"{'1' if role == 'control-plane' else '2'}\n{'1' if mode == 'remote' else '2'}\n")
            assert current["role"] == role and current["script"] == backend

        current, _ = run(["--role", role, "--mode", "remote", "--count=2", "--ips", "10.40.0.2,10.40.0.3",
                          "--identity-file", "/tmp/key with spaces", "--transport", "vrack"])
        assert current["args"] == [f"--{role}-count=2", f"--{role}-ips", "10.40.0.2,10.40.0.3",
                                   "--identity-file", "/tmp/key with spaces", "--transport", "vrack"]
        current, _ = run(["--role", role, "--mode", "remote", "--hosts=admin@cp-02,admin@cp-03"])
        assert current["args"] == [f"--{role}-hosts=admin@cp-02,admin@cp-03"]

    current, _ = run(answers="invalid\n1\ninvalid\n2\n")
    assert current["role"] == "control-plane" and current["script"] == "install-k3s-worker.sh"
    current, _ = run(["--role", "worker", "--mode", "local", "--token-stdin", "--non-interactive"],
                     token="fixture-node-token\n")
    assert current["token_received"] and current["role"] == "worker"

    for flags in (["--non-interactive"], ["--role", "control-plane", "--ips", "10.40.0.2"],
                  ["--role", "worker", "--token-stdin"], ["--role", "bad"], ["--mode", "bad"],
                  ["--role", "worker", "--node-role", "control-plane"],
                  ["--mode", "remote", "--mode", "local"], ["--role"],
                  ["--role", "worker", "--mode", "local", "--count", "2"],
                  ["--role", "control-plane", "--mode", "remote", "--worker-ips", "10.40.0.2"],
                  ["--role", "worker", "--mode", "remote", "--control-plane-count", "2"]):
        current, _ = run(flags, expected=1)
        assert current is None, flags
    current, result = run(["--help"])
    assert current is None and "--role control-plane|worker" in result.stdout
    run(["--role", "worker", "--mode", "local"], expected=7, extra_env={"MOCK_EXIT": "7"})

print("PASS: node role/mode prompts, four enrollment paths, generic selectors, stdin safety, and failures")
PY
