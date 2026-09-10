#!/usr/bin/env python3
"""Preserve Vault's verified vendor UI when rebuilding its Go server.

Supports the pinned Go 1.26 ELF64 little-endian embed.FS layout. Every table
pointer, path and compiler content hash is checked before any files are written.
Layout/hash changes fail the build; this is not a general ELF unpacker.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import struct


def extract(binary):
    if binary[:7] != b'\x7fELF\x02\x01\x01':
        raise ValueError('Expected ELF64 little-endian version 1')
    if struct.unpack_from('<H', binary, 18)[0] != 62:
        raise ValueError('Expected x86-64')
    phoff = struct.unpack_from('<Q', binary, 32)[0]
    size, count = struct.unpack_from('<HH', binary, 54)
    if size != 56 or not 1 <= count <= 128:
        raise ValueError('Unexpected program headers')
    segments = []
    for i in range(count):
        kind, _, offset, address, _, filesz, _, _ = struct.unpack_from(
            '<IIQQQQQQ', binary, phoff + i * size)
        if kind == 1:
            if offset + filesz > len(binary):
                raise ValueError('Truncated load segment')
            segments.append((offset, address, filesz))

    def offset_of(address, length):
        for offset, start, filesz in segments:
            if start <= address and address + length <= start + filesz:
                return offset + address - start
        raise ValueError('Pointer outside file-backed load segments')

    def address_of(offset):
        for start, address, filesz in segments:
            if start <= offset < start + filesz:
                return address + offset - start
        raise ValueError('Offset outside load segments')

    def read(address, length):
        offset = offset_of(address, length)
        return binary[offset:offset + length]

    # The compiler sorts entries by directory, then basename. Locate a known
    # file's row and walk backward to a self-referencing []file header.
    marker = b'web_ui/index.html'
    marker_offset = binary.find(marker)
    if marker_offset < 0 or binary.find(marker, marker_offset + 1) >= 0:
        raise ValueError('Expected one embedded UI index path')
    needle = struct.pack('<QQ', address_of(marker_offset), len(marker))
    row = binary.find(needle)
    if row < 0 or binary.find(needle, row + 1) >= 0:
        raise ValueError('Expected one embedded UI index row')
    table = None
    for distance in range(10000):
        header = row - 24 - 48 * distance
        if header < 0:
            break
        pointer, length, capacity = struct.unpack_from('<QQQ', binary, header)
        if length == capacity and distance < length <= 10000:
            if pointer == address_of(header + 24):
                table = (header + 24, length)
                break
    if table is None:
        raise ValueError('Cannot identify the complete UI embed.FS table')
    start, length = table
    offset_of(address_of(start), length * 48)
    files, names, directories = {}, set(), set()
    for i in range(length):
        entry = start + i * 48
        name_address, name_length, data_address, data_length = struct.unpack_from(
            '<QQQQ', binary, entry)
        if not 1 <= name_length <= 4096:
            raise ValueError('Invalid embedded filename length')
        name = read(name_address, name_length).decode('utf-8')
        path = PurePosixPath(name)
        if (not name.startswith('web_ui/') or '\\' in name or '\x00' in name
                or '..' in path.parts or str(path) != name.rstrip('/')
                or name in names):
            raise ValueError('Invalid or duplicate UI path')
        names.add(name)
        digest = binary[entry + 32:entry + 48]
        if name.endswith('/'):
            if data_address or data_length or digest != bytes(16):
                raise ValueError('Invalid embedded directory')
            directories.add(name.rstrip('/'))
            continue
        if data_length > 128 * 1024 * 1024:
            raise ValueError('UI asset exceeds size bound')
        data = read(data_address, data_length)
        # cmd/internal/hash and staticdata.fileStringSym in Go 1.26.7 use
        # different hashes above 1024 bytes. These are NOT plain SHA-256.
        if len(data) <= 1024:
            calculated = bytearray(hashlib.sha256(data).digest())
            calculated[0] ^= 0xff
        else:
            calculated = hashlib.sha256(b'\x01' + data).digest()
        if digest != calculated[:16]:
            raise ValueError('Compiler content hash mismatch: ' + name)
        files[name] = data
    if not files.get('web_ui/index.html') or 'web_ui' not in directories:
        raise ValueError('Missing UI index or root directory')
    for name in names:
        for parent in PurePosixPath(name).parents:
            if str(parent) != '.' and str(parent) not in directories:
                raise ValueError('Missing UI parent directory')
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--manifest', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.read_bytes()
    files = extract(binary)
    if args.output.exists():
        raise ValueError('Output must not exist')
    args.output.mkdir(parents=True)
    for name, data in files.items():
        target = args.output / name.removeprefix('web_ui/')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    manifest = {'binarySha256': hashlib.sha256(binary).hexdigest(),
                'files': {name: hashlib.sha256(data).hexdigest()
                          for name, data in sorted(files.items())}}
    args.manifest.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Preserved {len(files)} UI files with verified compiler content hashes')


if __name__ == '__main__':
    main()
