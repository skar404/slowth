#!/usr/bin/env python3
"""One entry point for source checks, iOS/macOS builds and signed version releases."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tarfile

from release_tools import automatic, build, core, models, version


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest='command', required=True)
    commands.add_parser('check', help='Check the public source snapshot and tests; no models or Apple credentials')
    package = commands.add_parser('models', help='Prepare models; --publish signs and publishes a GitHub Release')
    package.add_argument('--tag', required=True, help='New model tag, e.g. models-v10-1')
    package.add_argument('--output', type=Path, help='New directory; default: release-output/<tag>')
    package.add_argument('--model-bundle', type=Path, help='Import an existing bundle instead of private local exports')
    package.add_argument('--gpg-key', default=os.environ.get('RELEASE_GPG_KEY'), help='Explicit signing key; required with --publish')
    package.add_argument('--notes', type=Path, help='Optional public notes; otherwise generated from the model manifest')
    package.add_argument('--publish', action='store_true', help='Sign, push the model tag, verify draft assets and publish')
    archive = commands.add_parser('build', help='Build and validate iOS/macOS Release archives')
    archive.add_argument('--model-bundle', type=Path, required=True)
    archive.add_argument('--output', type=Path, required=True, help='New output directory')
    archive.add_argument('--platform', choices=['iOS', 'macOS', 'both'], default='both')
    archive.add_argument('--testflight', action='store_true', help='CI only: sign, upload to Apple and wait for processing')
    remote = commands.add_parser('ci', help='Dispatch the iOS/macOS workflow on published main')
    remote.add_argument('--model-release', required=True, help='Published app or model release containing Slowth-models.tar.gz')
    remote.add_argument('--testflight', action='store_true', help='Upload to TestFlight; otherwise unsigned validation')
    tag = commands.add_parser('tag', help='Sign and push the current version tag; CI builds and publishes automatically')
    tag.add_argument('--gpg-key', default=os.environ.get('RELEASE_GPG_KEY'), help='Explicit local signing key')
    auto = commands.add_parser('automation', help='Internal tag-workflow stages; no local Apple upload')
    auto.add_argument('stage', choices=['dispatch', 'check', 'prepare', 'publish'])
    auto.add_argument('--tag', required=True)
    auto.add_argument('--output', type=Path)
    promote = commands.add_parser('version', help='Inspect legacy main-run evidence locally; publish new versions with tag')
    promote.add_argument('--run', required=True, help='Successful release-ci workflow run ID')
    promote.add_argument('--model-release', required=True, help='Release containing the exact CI model input')
    promote.add_argument('--output', type=Path, help='New directory; default: release-output/v<version>')
    promote.add_argument('--notes', type=Path, help='Optional public release notes')
    promote.add_argument('--gpg-key', default=os.environ.get('RELEASE_GPG_KEY'))
    promote.add_argument('--publish', action='store_true', help='Removed: use tag for automatic publication')
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    core.require(not os.environ.get('PYTHONOPTIMIZE'), 'PYTHONOPTIMIZE is unsupported')
    core.require(not any(os.environ.get(k) for k in (
        'GIT_INDEX_FILE', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES')),
        'Custom Git environment is unsupported')
    core.require(core.git('rev-parse', '--show-toplevel', capture=True).decode().strip() == str(core.ROOT),
                 'Run from the main repository checkout')
    if args.command == 'check':
        build.main(['check'])
    elif args.command == 'build':
        flags = ['build', '--model-bundle', str(args.model_bundle), '--output', str(args.output),
                 '--platform', args.platform]
        if args.testflight:
            flags.append('--testflight')
        build.main(flags)
    elif args.command == 'models':
        models.prepare(args)
    elif args.command == 'ci':
        models.dispatch(args.model_release, args.testflight)
    elif args.command == 'version':
        version.prepare(args)
    elif args.command == 'tag':
        automatic.tag(args)
    elif args.command == 'automation':
        if args.stage in ('prepare', 'publish'):
            core.require(args.output is not None, '--output required')
            getattr(automatic, args.stage)(args.tag, args.output.resolve())
        else:
            getattr(automatic, args.stage)(args.tag)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f'Release stopped: {error}', file=sys.stderr)
        sys.exit(1)
