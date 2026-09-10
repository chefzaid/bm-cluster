#!/usr/bin/env python3
"""Test a PostgreSQL image against existing disposable data and a logical restore.

Requires Docker on Linux. Fixture containers have no network access, run as
UID/GID 999 with a read-only root, and use only newly created volumes. Private
logs include generated fixture credentials and must stay outside the repository.
"""
import argparse
import gzip
import hashlib
import json
import lzma
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time


REMOVED_PACKAGES = {'dirmngr', 'gnupg', 'gnupg-l10n', 'gnupg-utils', 'gpg',
                    'gpg-agent', 'gpg-wks-client', 'gpg-wks-server', 'gpgconf',
                    'gpgsm', 'libsqlite3-0'}


def command(args, *, data=None, timeout=120):
    return subprocess.run(args, input=data, check=True, capture_output=True, timeout=timeout).stdout


def wait_for(check, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError, subprocess.CalledProcessError):
            pass
        time.sleep(1)
    raise TimeoutError('PostgreSQL fixture did not become ready')


class Fixture:
    def __init__(self, args, private):
        self.args, self.private = args, private
        self.name = 'postgres-security-test-' + secrets.token_hex(6)
        self.active = False
        self.volumes = []
        self.phase = 'setup'
        self.results = {'image': args.image, 'previousImage': args.previous_image,
                        'checks': [], 'provenance': {}}

    @staticmethod
    def limits():
        return ['--network=none', '--memory=512m', '--memory-swap=512m', '--cpus=0.5',
                '--pids-limit=128', '--read-only', '--user=999:999', '--cap-drop=ALL',
                '--security-opt=no-new-privileges']

    def inspect_image(self, image, label):
        self.phase = label + ' provenance'
        info = json.loads(command(['docker', 'image', 'inspect', image]))[0]
        # Pin this invocation to the inspected image ID, even when passed a tag.
        image_id = info['Id']
        script = r'''
set -eu
find /usr/lib/postgresql/18 /usr/share/postgresql/18 -type f -exec sha256sum {} +
find /usr/lib /lib -name 'libc.so.6' -o -name 'ld-linux*.so.*' -o -name 'libicu*.so.72*' -o -name locale-archive | sort -u | xargs sha256sum
sha256sum /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-ensure-initdb.sh
'''
        hashes = command(['docker', 'run', '--rm', *self.limits(), '--entrypoint=/bin/sh',
                          image_id, '-ec', script])
        (self.args.logs / (label + '-runtime.sha256')).write_bytes(hashes)
        files = {}
        for line in hashes.decode().splitlines():
            digest, file = line.split(None, 1)
            files[file] = digest
        packages = command(['docker', 'run', '--rm', *self.limits(), '--entrypoint=dpkg-query',
                            image_id, '-W', '-f=${binary:Package}\t${Version}\t${db:Status-Status}\n'])
        (self.args.logs / (label + '-packages.tsv')).write_bytes(packages)
        installed = {}
        for line in packages.decode().splitlines():
            name, version, status = line.split('\t')
            if status == 'installed':
                installed[name.split(':')[0]] = version
        self.results['provenance'][label] = {'imageId': image_id, 'hashedFiles': len(files),
                                             'installedPackages': len(installed)}
        return image_id, files, installed

    def create_volume(self, label):
        volume = self.name + '-' + label
        command(['docker', 'volume', 'create', volume])
        self.volumes.append(volume)
        command(['docker', 'run', '--rm', '--network=none', '--memory=64m', '--cpus=0.5',
                 '--read-only', '--user=0:0', '--cap-drop=ALL', '--cap-add=CHOWN',
                 '--security-opt=no-new-privileges', '-v', volume + ':/var/lib/postgresql',
                 '--entrypoint=/bin/sh', self.previous, '-ec', 'chown 999:999 /var/lib/postgresql'])
        return volume

    def setup(self):
        self.previous, old_files, old_packages = self.inspect_image(self.args.previous_image, 'previous')
        self.candidate, new_files, new_packages = self.inspect_image(self.args.image, 'candidate')
        assert old_files == new_files, 'PostgreSQL, extension, locale, libc, ICU or entrypoint files changed'
        missing = old_packages.keys() - new_packages.keys()
        assert missing == REMOVED_PACKAGES, 'Candidate did not remove exactly the reviewed packages'
        assert old_packages.keys() >= new_packages.keys(), 'Candidate introduced an unexpected package'
        assert all(new_packages[key] == old_packages[key] for key in new_packages), 'A retained package version changed'
        assert not REMOVED_PACKAGES & new_packages.keys()
        self.results['checks'].append('exact runtime/extension/locale/ICU/libc/entrypoint hashes and retained package versions')
        password = secrets.token_urlsafe(32)
        self.env = self.private / 'fixture.env'
        self.env.write_text('POSTGRES_USER=fixture\nPOSTGRES_DB=fixture\n'
                            'POSTGRES_PASSWORD=' + password + '\n'
                            'POSTGRES_INITDB_ARGS=--data-checksums --auth-host=scram-sha-256\n')
        (self.args.logs / 'fixture.env').write_bytes(self.env.read_bytes())
        self.init = self.private / 'init'
        self.init.mkdir(mode=0o755)
        self.init.chmod(0o755)
        (self.init / '01.sql').write_text("CREATE TABLE initialization (marker text PRIMARY KEY); INSERT INTO initialization VALUES ('plain');\n")
        (self.init / '02.sql.gz').write_bytes(gzip.compress(b"INSERT INTO initialization VALUES ('gzip');\n"))
        (self.init / '03.sql.xz').write_bytes(lzma.compress(b"INSERT INTO initialization VALUES ('xz');\n"))
        compressed = command(['docker', 'run', '--rm', '-i', *self.limits(), '--entrypoint=zstd',
                              self.previous, '-c'], data=b"INSERT INTO initialization VALUES ('zstd');\n")
        (self.init / '04.sql.zst').write_bytes(compressed)
        for file in self.init.iterdir():
            file.chmod(0o644)

    def start(self, image, volume, label):
        self.phase = label + ' startup'
        command(['docker', 'run', '-d', '--name', self.name, *self.limits(),
                 '--env-file', str(self.env), '-v', volume + ':/var/lib/postgresql',
                 '-v', str(self.init) + ':/docker-entrypoint-initdb.d:ro',
                 '--tmpfs=/tmp:rw,nosuid,noexec,size=64m,uid=999,gid=999',
                 '--tmpfs=/var/run/postgresql:rw,nosuid,noexec,size=16m,uid=999,gid=999', image])
        self.active = True

        def ready():
            state = json.loads(command(['docker', 'inspect', self.name]))[0]['State']
            if not state['Running']:
                raise RuntimeError('PostgreSQL fixture exited during startup')
            # Initialization's temporary server uses only a Unix socket. TCP
            # readiness confirms that entrypoint initialization has completed.
            command(['docker', 'exec', self.name, 'pg_isready', '-h', '127.0.0.1',
                     '-U', 'fixture', '-d', 'fixture'])
            return True

        wait_for(ready)
        assert self.sql("SELECT json_agg(marker ORDER BY marker) FROM initialization") == ['gzip', 'plain', 'xz', 'zstd']

    def sql_raw(self, query, database='fixture'):
        return command(['docker', 'exec', '-i', self.name, 'psql', '-X', '-A', '-t',
                        '-v', 'ON_ERROR_STOP=1', '-U', 'fixture', '-d', database], data=query.encode())

    def sql(self, query, database='fixture'):
        return json.loads(self.sql_raw(query, database))

    def stop(self, label):
        command(['docker', 'stop', '--time', '30', self.name])
        with (self.args.logs / (label + '.log')).open('wb') as log:
            subprocess.run(['docker', 'logs', self.name], stdout=log, stderr=subprocess.STDOUT, check=True)
        state = json.loads(command(['docker', 'inspect', self.name]))[0]['State']
        assert not state['OOMKilled'] and state['ExitCode'] == 0, 'PostgreSQL did not shut down cleanly'
        command(['docker', 'rm', '-v', self.name])
        self.active = False

    def seed(self):
        self.phase = 'previous fixture data'
        available = self.sql('SELECT json_agg(name ORDER BY name) FROM pg_available_extensions')
        for name in available:
            quoted = '"' + name.replace('"', '""') + '"'
            self.sql_raw('CREATE EXTENSION IF NOT EXISTS ' + quoted + ' CASCADE;')
        self.results['availableExtensions'] = available
        self.sql_raw('''
CREATE TABLE fixture_data (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 label text UNIQUE NOT NULL, payload jsonb NOT NULL, document xml NOT NULL,
 token uuid NOT NULL DEFAULT uuid_generate_v4());
INSERT INTO fixture_data(label,payload,document)
 SELECT label, jsonb_build_object('label',label), xmlparse(document '<root><value>42</value></root>')
 FROM (VALUES ('a'),('A'),('á'),('ä'),('Å'),('Z'),('z'),('é'),('é'),('ß'),('ss'),
 ('2'),('10'),('-'),('_'),('日本語'),('😀'),('Ω'),('Ж')) AS labels(label);
CREATE INDEX fixture_payload_gin ON fixture_data USING gin(payload);
''')
        return self.state()

    def state(self, database='fixture'):
        return self.sql('''SELECT json_build_object(
 'rows',(SELECT json_agg(row_to_json(t) ORDER BY id) FROM
  (SELECT id,label,payload,document::text,token FROM fixture_data) t),
 'order',(SELECT json_agg(label ORDER BY label) FROM fixture_data),
 'extensions',(SELECT json_object_agg(extname,extversion) FROM pg_extension),
 'collation',(SELECT json_build_object('provider',datlocprovider,'collate',datcollate,
  'ctype',datctype,'recorded',datcollversion,'actual',pg_database_collation_actual_version(oid))
  FROM pg_database WHERE datname=current_database()),
 'checksums',current_setting('data_checksums'),
 'server_version',current_setting('server_version'))''', database)

    def exercise(self, label, expected, database='fixture'):
        self.phase = label + ' SQL and maintenance checks'
        assert self.state(database) == expected, 'Persisted rows, ordering, versions or extensions changed'
        result = self.sql('''SELECT json_build_object(
 'xml',xpath('/root/value/text()',document)::text[],
 'xslt',xslt_process(document::text,'<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:output method="text"/><xsl:template match="/"><xsl:value-of select="root/value"/></xsl:template></xsl:stylesheet>'),
 'uuid_version',substring(uuid_generate_v4()::text,15,1),
 'digest',encode(digest('fixture','sha256'),'hex'),
 'hstore',('a=>value'::hstore)->'a',
 'unaccent',unaccent('café'),
 'ltree','root.branch.leaf'::ltree <@ 'root'::ltree)
 FROM fixture_data ORDER BY id LIMIT 1''', database)
        assert result == {'xml': ['42'], 'xslt': '42', 'uuid_version': '4',
                          'digest': hashlib.sha256(b'fixture').hexdigest(),
                          'hstore': 'value', 'unaccent': 'cafe', 'ltree': True}
        # Force real LLVM compilation while keeping the data and query bounded.
        jit = self.sql_raw('''SET jit_above_cost=0; SET jit_inline_above_cost=0; SET jit_optimize_above_cost=0;
EXPLAIN (ANALYZE, FORMAT JSON) SELECT sum(i::bigint*i) FROM generate_series(1,2000) i;''', database)
        explain = json.loads(jit[jit.index(b'['):])
        assert explain[0]['JIT']['Functions'] > 0, 'LLVM JIT was not exercised'
        (self.args.logs / (label + '-jit.json')).write_text(json.dumps(explain, indent=2) + '\n')
        for tool, options in [('vacuumdb', ['--analyze-only']), ('reindexdb', []), ('pg_amcheck', [])]:
            output = command(['docker', 'exec', self.name, tool, '-U', 'fixture', '-d', database, *options])
            (self.args.logs / (label + '-' + tool + '.log')).write_bytes(output)
        # Exercise the existing Perl-backed client wrappers and SCRAM over TCP.
        successful = command(['docker', 'exec', self.name, '/bin/sh', '-ec',
                              'export PGPASSWORD="$POSTGRES_PASSWORD"; exec psql -X -A -t '
                              '-h 127.0.0.1 -U fixture -d "$1" -c "SELECT 42"', 'check', database])
        assert successful.strip() == b'42'
        wrong = subprocess.run(['docker', 'exec', '-i', self.name, '/bin/sh', '-ec',
                                'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -X -A -t '
                                '-h 127.0.0.1 -U fixture -d "$1" -c "SELECT 42"', 'check', database],
                               input=(secrets.token_urlsafe(32) + '\n').encode(), capture_output=True, timeout=30)
        assert wrong.returncode and b'password authentication failed' in wrong.stderr
        tools = command(['docker', 'exec', self.name, '/bin/sh', '-ec',
                         'for tool in /usr/lib/postgresql/18/bin/*; do "$tool" --version; done'])
        (self.args.logs / (label + '-native-tool-versions.log')).write_bytes(tools)
        closure = command(['docker', 'exec', self.name, '/bin/sh', '-ec',
                           'for file in /usr/lib/postgresql/18/bin/* /usr/lib/postgresql/18/lib/*.so; '
                           'do ldd "$file"; done'])
        assert b'not found' not in closure, 'A native runtime dependency is missing'
        (self.args.logs / (label + '-ldd.log')).write_bytes(closure)
        self.results['checks'].append(label + ': SQL/XML/XSLT/UUID/crypto/JIT, index checks, native tools, SCRAM and persisted state')

    def dump(self, label):
        self.phase = label + ' backup'
        backup = command(['docker', 'exec', self.name, 'pg_dump', '-U', 'fixture', '-d', 'fixture', '-Fc'])
        (self.args.logs / (label + '.dump')).write_bytes(backup)
        # Fully parse/decompress the archive using the real native restore tool.
        command(['docker', 'exec', '-i', self.name, 'pg_restore', '--file=/dev/null'], data=backup)
        self.results[label + 'Backup'] = {'bytes': len(backup), 'sha256': hashlib.sha256(backup).hexdigest()}
        return backup

    def run(self):
        self.setup()
        volume = self.create_volume('data')
        self.start(self.previous, volume, 'previous')
        expected = self.seed()
        self.exercise('previous', expected)
        self.dump('previous')
        self.stop('previous')
        print('Previous image initialized compressed scripts, all available extensions and verified fixture data', flush=True)

        self.start(self.candidate, volume, 'candidate')
        self.exercise('candidate', expected)
        self.sql_raw("INSERT INTO fixture_data(label,payload,document) VALUES ('candidate-write','{}','<root><value>42</value></root>');")
        updated = self.state()
        assert len(updated['rows']) == len(expected['rows']) + 1
        backup = self.dump('candidate')
        self.stop('candidate')
        print('Candidate preserved the old volume, collation order and extensions, and created a verified backup', flush=True)

        self.start(self.candidate, volume, 'restarted')
        self.exercise('restarted', updated)
        self.stop('restarted')

        restored = self.create_volume('restored')
        self.start(self.candidate, restored, 'restore')
        command(['docker', 'exec', self.name, 'createdb', '-U', 'fixture', 'restored'])
        command(['docker', 'exec', '-i', self.name, 'pg_restore', '--exit-on-error',
                 '-U', 'fixture', '-d', 'restored'], data=backup)
        self.exercise('restored', updated, database='restored')
        self.stop('restored')
        self.results['checks'].append('new writes survive restart; complete custom-format backup restored to a separate volume')
        self.results['status'] = 'passed'
        print('Candidate restart and isolated logical restore passed', flush=True)

    def cleanup(self):
        if self.active:
            with (self.args.logs / 'failed-container.log').open('wb') as log:
                subprocess.run(['docker', 'logs', self.name], stdout=log, stderr=subprocess.STDOUT, check=False, timeout=30)
            subprocess.run(['docker', 'rm', '-f', '-v', self.name], capture_output=True, check=False, timeout=60)
        for volume in self.volumes:
            subprocess.run(['docker', 'volume', 'rm', volume], capture_output=True, check=False, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image')
    parser.add_argument('--previous-image', required=True)
    parser.add_argument('--logs', type=Path, required=True)
    args = parser.parse_args()
    args.logs = args.logs.resolve()
    if args.logs.is_relative_to(Path(__file__).resolve().parents[1]):
        parser.error('--logs must be outside the repository because it contains fixture credentials and backups')
    os.umask(0o077)
    args.logs.mkdir(parents=True, mode=0o700, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='postgres-security-fixture-') as directory:
        fixture = Fixture(args, Path(directory))
        try:
            fixture.run()
        except Exception as error:
            fixture.results.update(status='failed', phase=fixture.phase, errorType=type(error).__name__)
            (args.logs / 'failure.txt').write_text(str(error) + '\n')
            if isinstance(error, subprocess.CalledProcessError):
                (args.logs / 'command-stderr.log').write_bytes(error.stderr or b'')
            raise RuntimeError(f'PostgreSQL fixture failed during {fixture.phase}; inspect {args.logs}') from None
        finally:
            (args.logs / 'result.json').write_text(json.dumps(fixture.results, indent=2) + '\n')
            fixture.cleanup()


if __name__ == '__main__':
    main()
