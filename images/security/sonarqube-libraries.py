"""Replace verified, unrelocated library bytecode; preserve the application ABI surface.

The lock records every Maven input by SHA-256. Dependency versions and original
class bytes are checked before replacement. This never changes version metadata
without replacing the corresponding library implementation.
"""
import argparse, hashlib, io, json, re, urllib.request, zipfile
from pathlib import Path


def properties(data):
    return dict(line.split('=', 1) for line in data.decode().splitlines()
                if '=' in line and not line.startswith(('#', '!')))


def replacement(group, artifact, version):
    def numbers(value):
        return tuple(int(v) for v in re.findall(r'\d+', value)[:3])
    selected = None
    if group == 'at.yawk.lz4': selected = '1.11.1'
    elif group == 'ch.qos.logback': selected = '1.5.34'
    elif group.startswith('com.fasterxml.jackson') and version.startswith('2.'): selected = '2.18.9'
    elif group.startswith('tools.jackson') and version.startswith('3.2.'): selected = '3.2.1'
    elif group == 'com.sun.mail' and artifact == 'jakarta.mail': selected = '2.0.2'
    elif group == 'io.netty' and version.startswith('4.1.'): selected = '4.1.137.Final'
    elif group == 'io.projectreactor.netty': selected = '1.2.8'
    elif group == 'io.projectreactor' and artifact == 'reactor-core': selected = '3.7.8'
    elif group == 'org.apache.httpcomponents.client5': selected = '5.6.3'
    elif group == 'org.apache.httpcomponents.core5': selected = '5.4.3'
    elif group == 'org.apache.logging.log4j' and artifact in ('log4j-api', 'log4j-to-slf4j'): selected = '2.25.5' if version.startswith('2.25.') else '2.26.1'
    elif group == 'org.apache.sshd': selected = '2.19.0'
    elif group == 'org.postgresql' and artifact == 'postgresql': selected = '42.7.12'
    if selected and numbers(version) < numbers(selected): return selected
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--lock', type=Path, required=True)
    parser.add_argument('--write-lock', action='store_true')
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    lock = json.loads(args.lock.read_text()) if args.lock.exists() else {}
    if not args.write_lock and not lock: raise ValueError('A populated artifact lock is required')

    def fetch(group, artifact, version, classifier=''):
        name = f'{artifact}-{version}{classifier}.jar'
        relative = f'{group.replace(".", "/")}/{artifact}/{version}/{name}'
        url = 'https://repo.maven.apache.org/maven2/' + relative
        target = args.cache / (group + '_' + name)
        if not target.exists(): target.write_bytes(urllib.request.urlopen(url, timeout=60).read())
        data = target.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if relative not in lock:
            if not args.write_lock: raise ValueError('Unpinned Maven artifact: ' + relative)
            # Maven's independently published checksum verifies the download;
            # the resulting SHA-256 is mandatory for subsequent builds.
            try:
                expected = urllib.request.urlopen(url + '.sha512', timeout=30).read().decode().split()[0]
                assert hashlib.sha512(data).hexdigest() == expected
            except urllib.error.HTTPError as error:
                if error.code != 404: raise
                expected = urllib.request.urlopen(url + '.sha1', timeout=30).read().decode().split()[0]
                assert hashlib.sha1(data).hexdigest() == expected
            lock[relative] = digest
            args.lock.write_text(json.dumps(lock, indent=2, sort_keys=True) + '\n')
        if lock[relative] != digest: raise ValueError('Artifact hash mismatch: ' + relative)
        return data

    changes = []
    for path in sorted(args.root.rglob('*.jar')):
        if path.is_symlink(): continue
        with zipfile.ZipFile(path) as archive:
            entries = {info.filename: (info, archive.read(info)) for info in archive.infolist()}
        libraries = []
        for name, (_, data) in sorted(entries.items()):
            if not name.endswith('/pom.properties'): continue
            prop = properties(data)
            if not all(key in prop for key in ('groupId', 'artifactId', 'version')): continue
            group, artifact, old = (prop[key] for key in ('groupId', 'artifactId', 'version'))
            new = replacement(group, artifact, old)
            if new: libraries.append((name, group, artifact, old, new))
        # Gradle/JDBC artifacts can identify themselves only in their manifest.
        if not libraries:
            for artifact, group in [('reactor-netty-http', 'io.projectreactor.netty'), ('reactor-netty-core', 'io.projectreactor.netty'), ('reactor-core', 'io.projectreactor'), ('postgresql', 'org.postgresql')]:
                match = re.fullmatch(re.escape(artifact) + r'-(\d[\w.\-]*)\.jar', path.name)
                if match and (new := replacement(group, artifact, match[1])):
                    libraries.append(('', group, artifact, match[1], new))
        if not libraries: continue
        # Individual artifacts retain Maven signatures and the complete manifest.
        if len(libraries) == 1 and path.name.startswith(libraries[0][2] + '-' + libraries[0][3]):
            _, group, artifact, old, new = libraries[0]
            classifier = path.name.removeprefix(artifact + '-' + old).removesuffix('.jar')
            if path.read_bytes() != fetch(group, artifact, old, classifier):
                raise ValueError('Modified standalone artifact: ' + str(path))
            data = fetch(group, artifact, new, classifier)
            target = path.with_name(artifact + '-' + new + classifier + '.jar')
            if target != path and target.exists(): raise ValueError('Duplicate artifact: ' + str(target))
            target.write_bytes(data)
            if target != path: path.unlink()
            changes.append([str(path.relative_to(args.root)), group + ':' + artifact, old, new])
            continue
        if any(re.search(r'META-INF/[^/]+\.(SF|RSA|DSA|EC)$', name) for name in entries):
            raise ValueError('Refusing to alter a signed aggregate: ' + str(path))
        for pom_path, group, artifact, old, new in libraries:
            old_zip = zipfile.ZipFile(io.BytesIO(fetch(group, artifact, old)))
            new_zip = zipfile.ZipFile(io.BytesIO(fetch(group, artifact, new)))
            prefix = pom_path.split('META-INF/maven/')[0]
            apm = prefix == 'agent/'
            exploded = prefix.startswith('IMPL-JARS/')
            new_prefix = prefix.replace(artifact + '-' + old + '.jar/', artifact + '-' + new + '.jar/') if exploded else prefix
            def map_name(name, base=prefix):
                return base + (name[:-6] + '.esclazz' if apm and name.endswith('.class') else name)
            old_names = old_zip.namelist()
            old_classes = [name for name in old_names if name.endswith('.class') and not name.endswith('module-info.class')]
            present = [name for name in old_classes if map_name(name) in entries]
            if not present: raise ValueError('No original library classes: ' + str(path) + ':' + artifact)
            if len(present) != len(old_classes) and not apm:
                raise ValueError('Incomplete or relocated original classes: ' + str(path) + ':' + artifact)
            for name in present:
                if entries[map_name(name)][1] != old_zip.read(name):
                    raise ValueError('Modified original bytecode: ' + str(path) + ':' + name)
            # Preserve unrelated merged resources in aggregate jars. Libraries'
            # service descriptors are merged by provider name below.
            metadata = 'META-INF/maven/' + group + '/' + artifact + '/'
            def own(name):
                if exploded: return True
                return (not name.startswith('META-INF/') or name.startswith(metadata)
                        or name.startswith('META-INF/versions/') or name.startswith('META-INF/services/'))
            merged_services = {}
            for name in old_names:
                mapped = map_name(name)
                if name.startswith('META-INF/services/') and mapped in entries and not exploded:
                    previous = set(entries[mapped][1].decode().splitlines())
                    merged_services[name] = previous - set(old_zip.read(name).decode().splitlines())
                if own(name) and mapped in entries and not name.endswith('/') and (exploded or not name.endswith('module-info.class')):
                    entries.pop(mapped)
            for info in new_zip.infolist():
                name = info.filename
                if name.endswith('/') or not own(name): continue
                if not exploded and name.endswith('module-info.class'): continue
                # The APM classloader deliberately uses Java 8 classes only.
                if apm and name.startswith('META-INF/versions/') and map_name(name) not in {map_name(n) for n in present}: continue
                data = new_zip.read(info)
                if name in merged_services:
                    data = ('\n'.join(sorted(merged_services[name] | set(data.decode().splitlines()))) + '\n').encode()
                mapped = map_name(name, new_prefix)
                if mapped in entries and entries[mapped][1] != data:
                    raise ValueError('Overlapping library resource: ' + str(path) + ':' + mapped)
                # Keep a stable timestamp for reproducible aggregate jars.
                updated = zipfile.ZipInfo(mapped, (2026, 9, 9, 0, 0, 0))
                updated.compress_type = zipfile.ZIP_DEFLATED
                updated.external_attr = 0o644 << 16
                entries[mapped] = (updated, data)
            if exploded:
                listing = prefix.split(artifact + '-' + old + '.jar/')[0] + 'LISTING.TXT'
                info, data = entries[listing]
                assert (artifact + '-' + old + '.jar').encode() in data
                entries[listing] = (info, data.replace((artifact + '-' + old + '.jar').encode(), (artifact + '-' + new + '.jar').encode()))
            changes.append([str(path.relative_to(args.root)), group + ':' + artifact, old, new])
        eddsa_metadata = 'META-INF/maven/net.i2p.crypto/eddsa/pom.properties'
        if eddsa_metadata in entries:
            # Apache SSHD 2.16+ supports Bouncy Castle for Ed25519 without this
            # optional, unmaintained provider. Keep SSH support and verify the
            # alternate provider with handshake and signature regression tests.
            if path.name != 'sonar-scanner-engine-community-13.4.1.4007.jar':
                raise ValueError('Unexpected EdDSA consumer: ' + str(path))
            assert 'org/bouncycastle/jce/provider/BouncyCastleProvider.class' in entries
            sshd = properties(entries['META-INF/maven/org.apache.sshd/sshd-common/pom.properties'][1])
            assert sshd['version'] == '2.19.0'
            for name, (_, data) in entries.items():
                if name.endswith('.class') and b'net/i2p/crypto/eddsa' in data and not name.startswith(('net/i2p/', 'org/apache/sshd/')):
                    raise ValueError('Another component requires the old provider: ' + name)
            old = properties(entries[eddsa_metadata][1])['version']
            with zipfile.ZipFile(io.BytesIO(fetch('net.i2p.crypto', 'eddsa', old))) as original:
                for name in original.namelist():
                    if name.endswith('.class'):
                        assert name in entries and entries[name][1] == original.read(name), name
                        del entries[name]
            for name in list(entries):
                if name.startswith('META-INF/maven/net.i2p.crypto/eddsa/'):
                    del entries[name]
                elif name.startswith('META-INF/services/') and b'net.i2p.crypto.eddsa' in entries[name][1]:
                    info, data = entries[name]
                    entries[name] = (info, b'\n'.join(line for line in data.splitlines() if b'net.i2p.crypto.eddsa' not in line) + b'\n')
            changes.append([str(path.relative_to(args.root)), 'net.i2p.crypto:eddsa', old, 'replaced by the existing Bouncy Castle provider through Apache SSHD 2.19.0'])
        temp = path.with_suffix('.patched.jar')
        with zipfile.ZipFile(temp, 'w') as output:
            for _, (info, data) in sorted(entries.items()): output.writestr(info, data)
        temp.replace(path)
    if args.write_lock: args.lock.write_text(json.dumps(lock, indent=2, sort_keys=True) + '\n')
    print(json.dumps(changes, indent=2))


if __name__ == '__main__': main()
