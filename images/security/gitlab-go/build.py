#!/usr/bin/env python3
"""Build the Go components matching the pinned Omnibus release."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


ASSETS = Path(__file__).resolve().parent
COMPONENTS = json.loads((ASSETS / 'components.json').read_text())


def run(args, directory, env=None):
    subprocess.run(args, cwd=directory, env=env, check=True)


def checkout(spec, directory):
    directory.mkdir(parents=True)
    run(['git', 'init', '-q'], directory)
    run(['git', 'remote', 'add', 'origin', spec['repository']], directory)
    if spec.get('module', '.') != '.':
        run(['git', 'sparse-checkout', 'init', '--cone'], directory)
        run(['git', 'sparse-checkout', 'set', spec['module']], directory)
    ref = spec.get('tag', spec['commit'])
    run(['git', 'fetch', '--no-tags', '--depth=1', 'origin', ref], directory)
    actual = subprocess.check_output(['git', 'rev-parse', 'FETCH_HEAD^{commit}'],
                                     cwd=directory, text=True).strip()
    if actual != spec['commit']:
        raise RuntimeError(f'Unexpected source commit: {actual}')
    run(['git', 'checkout', '--detach', '-q', actual], directory)
    if spec.get('tag'):
        run(['git', 'tag', spec['tag'], actual], directory)


def build(name, spec, sources, output, native_git):
    source = sources / name
    checkout(spec, source)
    run(['git', 'apply', '--check', str(ASSETS / f'{name}.patch')], source)
    run(['git', 'apply', str(ASSETS / f'{name}.patch')], source)
    module = source / spec['module']
    cgo = '0' if all(command['cgo'] == '0' for command in spec['commands']) else '1'
    env = {**os.environ, 'GOWORK': 'off', 'GOFLAGS': '-mod=readonly',
           'GOTOOLCHAIN': 'local', 'CGO_ENABLED': cgo}
    parallel = '1' if name == 'prometheus' else '2'
    if name == 'devfile-amd64-linux':
        dependency = sources / 'devfile-registry-support'
        checkout(spec['registrySupport'], dependency)
        run(['git', 'apply', str(ASSETS / 'devfile-registry.patch')], dependency)
        destination = module / 'security-deps/registry-library'
        shutil.copytree(dependency / 'registry-library', destination)
        run(['go', 'test', '-short', '-p', '2',
             'github.com/devfile/registry-support/registry-library/library'], module, env)
    if name == 'node-exporter':
        for fixture in ('sys', 'udev'):
            run(['./ttar', '-C', 'collector/fixtures', '-x', '-f',
                 f'collector/fixtures/{fixture}.ttar'], source)
    if name == 'gitaly':
        embedded = source / '_build/bin'
        embedded.mkdir(parents=True, exist_ok=True)
        git_files = list(native_git.glob('gitaly-git-*'))
        if len(git_files) != 9:
            raise RuntimeError('Expected nine Git executables from pinned vendor Gitaly')
        for binary in git_files:
            shutil.copy2(binary, embedded / binary.name)
        for binary in ('gitaly-hooks', 'gitaly-ssh', 'gitaly-lfs-smudge', 'gitaly-gpg'):
            run(['go', 'build', '-p', parallel, '-trimpath', '-o',
                 str(embedded / binary), './cmd/' + binary], module, env)
    for command in spec['commands']:
        destination = output / command['target']
        destination.parent.mkdir(parents=True, exist_ok=True)
        args = ['go', 'build', '-p', parallel, '-trimpath', '-ldflags',
                command['flags'], '-o', str(destination)]
        if command['tags']:
            args += ['-tags', command['tags']]
        run([*args, command['package']], module,
            {**env, 'CGO_ENABLED': command['cgo']})
    if name == 'workhorse':
        for command in spec['commands']:
            (module / command['binary']).symlink_to(output / command['target'])
        (module / 'testdata/scratch').mkdir(parents=True, exist_ok=True)
    tests = spec['tests']
    if name == 'gitaly':
        # These three suites need Omnibus's Git and native libraries. Compile
        # them here; run them in the vendor runtime before promoting the image.
        native_packages = ('client', 'middleware/customfieldshandler', 'middleware/housekeeping')
        grpc_packages = subprocess.check_output(['go', 'list', './internal/grpc/...'],
                                                cwd=module, env=env, text=True).splitlines()
        tests = ['./internal/backoff/...', './internal/stream/...'] + [
            package for package in grpc_packages
            if not any(package.endswith('/internal/grpc/' + native) for native in native_packages)]
        native_tests = output.parent / 'gitaly-tests'
        native_tests.mkdir(exist_ok=True)
        for package in native_packages:
            run(['go', 'test', '-c', '-p', parallel, '-o',
                 str(native_tests / (package.replace('/', '-') + '.test')),
                 './internal/grpc/' + package], module, env)
    run(['go', 'test', '-short', '-p', parallel, *tests], module, env)
    print(f'{name}: build and source tests passed', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources', type=Path, default=Path('/build/sources'))
    parser.add_argument('--output', type=Path, default=Path('/build/runtime'))
    parser.add_argument('--native-git', type=Path, default=Path('/vendor-git'))
    parser.add_argument('components', nargs='*', metavar='COMPONENT',
                        help='Components to build; omitted means all components')
    args = parser.parse_args()
    unknown = sorted(set(args.components) - COMPONENTS.keys())
    if unknown:
        parser.error('Unknown components: ' + ', '.join(unknown))
    for name in args.components or COMPONENTS:
        build(name, COMPONENTS[name], args.sources.resolve(), args.output.resolve(),
              args.native_git.resolve())


if __name__ == '__main__':
    main()
