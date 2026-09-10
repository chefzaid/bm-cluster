#!/usr/bin/env python3
"""Check vendor UI extraction against the pinned Go compiler's real embed.FS."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('vault_ui', ROOT / 'images/security/vault-ui.py')
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)


class ExtractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='vault-ui-test-')
        root = Path(cls.directory.name)
        cls.files = {
            'web_ui/index.html': b'<html>Verified fixture</html>',
            'web_ui/assets/empty.js': b'',
            'web_ui/assets/small.bin': bytes(range(256)) * 4,
            'web_ui/assets/large.bin': bytes(range(256)) * 5,
        }
        for name, data in cls.files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (root / 'main.go').write_text('''package main
import ("embed"; "io/fs"; "fmt")
//go:embed web_ui/*
var content embed.FS
func main() { fs.WalkDir(content, ".", func(p string, d fs.DirEntry, e error) error {
 if e != nil { panic(e) }; if !d.IsDir() { b, e := content.ReadFile(p); if e != nil { panic(e) }; fmt.Println(p, len(b)) }; return nil
}) }
''')
        env = {**os.environ, 'GOTOOLCHAIN': 'local', 'GOWORK': 'off', 'CGO_ENABLED': '0'}
        go = os.environ.get('GO_EXECUTABLE', 'go')
        version = subprocess.check_output([go, 'version'], env=env, text=True)
        if 'go1.26.7 ' not in version:
            raise RuntimeError('Use the pinned Go 1.26.7 compiler for this layout fixture')
        subprocess.run([go, 'build', '-p', '1', '-ldflags=-s -w', '-o', 'fixture', 'main.go'],
                       cwd=root, env=env, check=True)
        subprocess.run([str(root / 'fixture')], check=True, stdout=subprocess.DEVNULL)
        cls.binary = (root / 'fixture').read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_exact_files_including_empty_binary_and_hash_boundary(self):
        self.assertEqual(UI.extract(self.binary), self.files)

    def test_corrupt_asset_rejected(self):
        binary = bytearray(self.binary)
        offset = binary.index(self.files['web_ui/index.html'])
        binary[offset] ^= 1
        with self.assertRaisesRegex(ValueError, 'content hash mismatch'):
            UI.extract(binary)

    def test_truncated_load_segment_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Truncated load segment'):
            UI.extract(self.binary[:len(self.binary) // 2])

    def test_wrong_architecture_rejected(self):
        binary = bytearray(self.binary)
        binary[18] = 183
        with self.assertRaisesRegex(ValueError, 'x86-64'):
            UI.extract(binary)

    def test_traversal_rejected(self):
        binary = self.binary.replace(b'web_ui/assets/small.bin', b'web_ui/../bad/small.bin')
        self.assertEqual(len(binary), len(self.binary))
        with self.assertRaisesRegex(ValueError, 'Invalid or duplicate UI path'):
            UI.extract(binary)


if __name__ == '__main__':
    unittest.main()
