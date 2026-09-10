#!/usr/bin/env python3
"""Exercise unseal stdin handling without accessing a cluster or real keys."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
stdin = sys.stdin.read() if '-i' in args else ''
log = pathlib.Path(os.environ['MOCK_LOG'])
with log.open('a') as f:
    f.write(json.dumps({'args': args, 'stdin': stdin}) + '\n')
if args[0] == 'get':
    print(os.environ.get('MOCK_PHASE', 'Running'))
elif 'status' in args:
    if os.environ.get('MOCK_STATUS_EMPTY'):
        sys.exit(1)
    written = pathlib.Path(os.environ['MOCK_WRITTEN']).exists()
    sealed = os.environ.get('MOCK_SEALED', 'true') == 'true'
    if written and not os.environ.get('MOCK_REMAIN_SEALED'):
        sealed = False
    print(json.dumps({'sealed': sealed}))
    sys.exit(2 if sealed else 0)
elif 'write' in args:
    assert args[-4:] == ['write', '-format=json', 'sys/unseal', '-']
    assert '-i' in args
    payload = json.loads(stdin)
    assert list(payload) == ['key']
    if os.environ.get('MOCK_WRITE_FAIL'):
        sys.exit(1)
    pathlib.Path(os.environ['MOCK_WRITTEN']).touch()
    print(json.dumps({'sealed': False}))
else:
    raise AssertionError('Unexpected command')
'''


class UnsealTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='vault-unseal-test-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.key = self.directory / 'unseal-key'
        self.key.write_text('fixture-key+/==\n')
        self.key.chmod(0o600)
        self.log = self.directory / 'calls.jsonl'
        mock = self.directory / 'kubectl'
        mock.write_text(MOCK)
        mock.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.directory) + os.pathsep + os.environ['PATH'],
                        VAULT_UNSEAL_KEY_FILE=str(self.key), VAULT_NAMESPACE='fixture-namespace',
                        VAULT_POD='fixture-vault-0', VAULT_ADDR='http://127.0.0.1:8200',
                        MOCK_LOG=str(self.log), MOCK_WRITTEN=str(self.directory / 'written'))

    def run_helper(self, **env):
        return subprocess.run(['bash', str(ROOT / 'scripts/vault-unseal.sh')],
                              env=dict(self.env, **env), text=True, capture_output=True, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def writes(self):
        return [x for x in self.calls() if 'write' in x['args']]

    def assert_secret_only_on_stdin(self, key, result):
        writes = self.writes()
        self.assertEqual(len(writes), 1)
        self.assertEqual(json.loads(writes[0]['stdin']), {'key': key})
        self.assertIn('-i', writes[0]['args'])
        self.assertNotIn(key, json.dumps([x['args'] for x in self.calls()]))
        self.assertNotIn(key, result.stdout + result.stderr)

    def test_sealed_server_receives_exact_key_and_is_checked_afterward(self):
        key = 'fixture-"quoted"-\\-$(must-not-run)-+/=='
        self.key.write_text(key + '\n\n')
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_secret_only_on_stdin(key, result)
        self.assertEqual(sum('status' in c['args'] for c in self.calls()), 2)

    def test_unsealed_server_does_not_receive_key(self):
        result = self.run_helper(MOCK_SEALED='false')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_missing_or_empty_key_skips_cluster_access(self):
        for missing in (False, True):
            with self.subTest(missing=missing):
                if missing:
                    self.key.unlink()
                else:
                    self.key.write_bytes(b'')
                self.assertEqual(self.run_helper().returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_nonrunning_pod_is_skipped(self):
        self.assertEqual(self.run_helper(MOCK_PHASE='Pending').returncode, 0)
        self.assertEqual(len(self.calls()), 1)

    def test_unavailable_status_does_not_trigger_unseal(self):
        self.assertEqual(self.run_helper(MOCK_STATUS_EMPTY='true').returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_failed_unseal_is_reported(self):
        self.assertNotEqual(self.run_helper(MOCK_WRITE_FAIL='true').returncode, 0)

    def test_remaining_sealed_is_reported(self):
        result = self.run_helper(MOCK_REMAIN_SEALED='true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Vault remains sealed', result.stderr)

    def test_installer_unseal_streams_the_same_anonymous_api_request(self):
        source = (ROOT / 'scripts/configure-vault.sh').read_text()
        blocks = re.findall(r'if \[\[ "\$sealed" == "true" \]\]; then\n.*?\nfi', source, re.S)
        self.assertEqual(len(blocks), 1)
        key = 'fixture-installer-"quoted"-+/=='
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', 'info() { :; }\n' + blocks[0]],
            env=dict(self.env, sealed='true', unseal_key=key, NAMESPACE='fixture-namespace',
                     VAULT_POD='fixture-vault-0', VAULT_ADDR='http://127.0.0.1:8200'),
            text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_secret_only_on_stdin(key, result)


if __name__ == '__main__':
    unittest.main()
