#!/usr/bin/env python3
"""Replace complete Keycloak library artifacts using pinned source and replacement checksums."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--lock', required=True, type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    pending = []
    for entry in json.loads(args.lock.read_text()):
        target = (root / entry['path']).resolve()
        if not target.is_relative_to(root):
            raise ValueError('Library path escapes the distribution')
        if hashlib.sha256(target.read_bytes()).hexdigest() != entry['originalSha256']:
            raise ValueError('Unexpected vendor library: ' + entry['path'])
        if not entry['url'].startswith('https://repo.maven.apache.org/maven2/'):
            raise ValueError('Unexpected artifact repository')
        with urllib.request.urlopen(entry['url'], timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError('Replacement checksum mismatch: ' + entry['path'])
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            if archive.testzip() or not any(name.endswith(('.class', '.so')) for name in archive.namelist()):
                raise ValueError('Invalid library artifact: ' + entry['path'])
        pending.append((target, data))
    # Quarkus's application model references these paths. Keep them stable while
    # replacing the entire JAR, including its real implementation and metadata.
    for target, data in pending:
        target.write_bytes(data)
    print(f'Replaced {len(pending)} checksum-verified Keycloak libraries')


if __name__ == '__main__':
    main()
