#!/usr/bin/env python3
"""Build public release evidence; only public/ is safe to upload as an artifact."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sys
import tempfile

from . import core as release

ROOT = release.ROOT


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def identity(source, head, tree, version, build, official):
    committed = tree == release.git('rev-parse', f'{head}^{{tree}}', capture=True).decode().strip()
    result = {'schema_version': 1, 'marketing_version': version, 'build_number': build,
              'source_tree': tree, 'commit': head if committed else None,
              'repository': None, 'run_url': None}
    if official:
        release.require(committed and head == os.environ.get('GITHUB_SHA'),
                        'CI must build the exact committed workflow revision')
        repository = os.environ.get('GITHUB_REPOSITORY', '')
        run_id = os.environ.get('GITHUB_RUN_ID', '')
        attempt = os.environ.get('GITHUB_RUN_ATTEMPT', '')
        release.require(re.fullmatch(r'[\w.-]+/[\w.-]+', repository)
                        and run_id.isdigit() and attempt.isdigit(), 'Invalid GitHub identity')
        result.update(repository=repository,
                      run_url=f'https://github.com/{repository}/actions/runs/{run_id}/attempts/{attempt}')
    write_json(source / 'BuildIdentity.json', result)
    return result


def generate_project(source, spec):
    # Some extensions list individual Shared files, so explicitly add the resource
    # to every target instead of relying on directory inference.
    for target in spec['targets'].values():
        target.setdefault('sources', []).append({'path': 'BuildIdentity.json', 'buildPhase': 'resources'})
    write_json(source / 'project-ci.json', spec)
    release.run('xcodegen', 'generate', '--spec', 'project-ci.json', cwd=source)


def validate_bundles(app, version, build, expected_identity):
    records = []
    for bundle in [app, *sorted(app.rglob('*.appex'))]:
        content = bundle / 'Contents' if (bundle / 'Contents').is_dir() else bundle
        info = plistlib.loads((content / 'Info.plist').read_bytes())
        release.require(info['CFBundleShortVersionString'] == version
                        and info['CFBundleVersion'] == build, f'Built version differs: {bundle.name}')
        resources = content / 'Resources' if content != bundle else bundle
        release.require(json.loads((resources / 'BuildIdentity.json').read_text()) == expected_identity,
                        f'Built identity differs: {bundle.name}')
        binary = (content / 'MacOS' if content != bundle else content) / info['CFBundleExecutable']
        records.append({'bundle_id': info['CFBundleIdentifier'], 'version': version, 'build': build,
                        'executable_sha256': release.sha(binary)})
    return records


def build_archive(source, output, platform, version, build, provenance, signed):
    scheme = 'Relise - iOS' if platform == 'iOS' else 'Release - macOS'
    archive = output / f'{platform}.xcarchive'
    command = ['xcodebuild', '-quiet', '-project', 'Unscroll.xcodeproj', '-scheme', scheme,
               '-configuration', 'Release', '-destination', f'generic/platform={platform}',
               '-derivedDataPath', output / f'derived-{platform}', '-archivePath', archive]
    if not signed:
        command += ['CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO']
    release.run(*command, 'archive', cwd=source)
    apps = list((archive / 'Products/Applications').glob('*.app'))
    release.require(len(apps) == 1, 'Expected exactly one archived app')
    app = apps[0]
    bundles = validate_bundles(app, version, build, provenance)
    if signed:
        release.run('codesign', '--verify', '--deep', '--strict', app)
    if platform == 'iOS':
        release.run(sys.executable, 'scripts/verify_app_configuration.py',
                    '--configuration', 'Release', '--app', app, cwd=source)
    release.run(sys.executable, 'scripts/verify_localization_bundles.py', app, cwd=source)
    return archive, bundles


def check_source(source):
    release.versions(source)
    release.run(sys.executable, 'scripts/prepare_release_resources.py', '--check', '--runtime-only', cwd=source)
    release.run('node', '--test', *sorted((source / 'WebExt/tests').glob('*.test.cjs')), cwd=source)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['check', 'build'])
    parser.add_argument('--model-bundle', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--platform', choices=['iOS', 'macOS', 'both'], default='both')
    parser.add_argument('--testflight', action='store_true')
    args = parser.parse_args(argv)
    official = os.environ.get('GITHUB_ACTIONS') == 'true'
    release.require(not args.testflight or (args.mode == 'build' and args.platform in ('iOS', 'both') and official),
                    'TestFlight requires an official CI build including iOS')
    if args.mode != 'check':
        release.require(args.output is not None, '--output is required')
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=False)
        public = output / 'public'
        public.mkdir()
    with tempfile.TemporaryDirectory(prefix='slowth-ci-') as temp:
        source, head, tree = release.snapshot(ROOT, Path(temp))
        if args.mode == 'check':
            check_source(source)
            return
        release.require(args.model_bundle is not None, '--model-bundle is required; no private fallback in CI')
        version, build, spec = release.versions(source)
        provenance = identity(source, head, tree, version, build, official)
        signing = None
        mac_signing = None
        mac_store_signing = None
        try:
            # Local developer credentials are never copied into the CI snapshot.
            if args.testflight:
                if args.platform == 'both':
                    from .macos import MacSigning
                    mac_signing = MacSigning(output / 'macos-signing')
                    mac_signing.preflight()
                    mac_signing.configure(source, spec)
                from . import signing as ci_signing
                signing = ci_signing.Signing(output / 'signing')
                signing.preflight(version, build)
                signing.configure(source, spec)
                if args.platform == 'both':
                    from .macos_store import MacStoreSigning
                    mac_store_signing = MacStoreSigning(output / 'macos-store-signing')
                    # Check both platforms' prior builds before either upload consumes this number.
                    mac_store_signing.preflight(version, build)
                    mac_store_signing.configure(source, spec)
            else:
                shutil.copyfile(source / 'Configs/Local.xcconfig.example', source / 'Configs/Local.xcconfig')
            # Reuse model import, generated resource, version and Node-test checks.
            release.prepare(source, source, args.model_bundle.resolve(), spec)
            generate_project(source, spec)
            platforms = ['macOS', 'iOS'] if args.platform == 'both' else [args.platform]
            records = {}
            archives = {}
            for platform in platforms:
                signed = (signing if platform == 'iOS' else mac_signing) is not None
                archive, bundles = build_archive(source, output, platform, version, build, provenance,
                                                 signed=signed)
                archives[platform] = archive
                records[platform] = {'code_signed': signed, 'bundles': bundles}
            manifest = {
                **provenance, 'kind': 'testflight-upload' if signing else 'unsigned-validation',
                'tools': {name: release.run(*cmd, capture=True).decode().strip() for name, cmd in {
                    'xcode': ['xcodebuild', '-version'], 'xcodegen': ['xcodegen', '--version'],
                    'node': ['node', '--version'], 'python': [sys.executable, '--version'],
                    'macos': ['sw_vers', '-productVersion']}.items()},
                'runner_image': {'version': os.environ.get('ImageVersion'), 'os': os.environ.get('ImageOS')},
                'model_bundle_sha256': release.sha(args.model_bundle),
                'model_packages': release.MODEL_HASHES, 'runtime_metadata_sha256': release.RUNTIME_HASH,
                'platforms': records,
                'checks': ['public-snapshot', 'version-consistency', 'pinned-models',
                           'release-resources', 'webextension-tests', 'archive-build',
                           'embedded-build-identity', 'bundle-localizations'],
                'limitations': 'Provenance of this CI output only. Apple processes App Store downloads; '
                               'this is not a byte-for-byte comparison with an installed app. '
                               'Remote rules can change independently of the app. '
                               'Native language switching and WebKit UI tests are not run by this workflow.',
            }
            if mac_signing:
                manifest['macos'] = mac_signing.export_notarize(archives['macOS'], output, version, build, provenance)
                records['macOS']['bundles'] = manifest['macos'].pop('bundles')
                manifest['checks'] += ['developer-id-signature', 'universal-macos', 'apple-notarization', 'stapled-ticket', 'gatekeeper']
            if signing:
                ipa = signing.export(archives['iOS'], output, version, build, provenance, source)
                manifest['ipa'] = {'name': ipa.name, 'sha256': release.sha(ipa)}
                if mac_store_signing:
                    package, mac_bundles = mac_store_signing.export(archives['macOS'], output, version, build, provenance)
                    package_path = public / 'Slowth-macOS-TestFlight.pkg'
                    shutil.copyfile(package, package_path)
                    manifest['macos_testflight'] = {'name': package_path.name, 'sha256': release.sha(package),
                                                  'distribution': 'app-store-connect', 'bundles': mac_bundles}
                    release.require(release.sha(package_path) == manifest['macos_testflight']['sha256'], 'Retained Mac package differs')
                    manifest['macos_app_store_connect'] = mac_store_signing.upload(package, build)
                    manifest['checks'] += ['mac-app-store-package', 'mac-app-store-processing']
                # altool sends exactly this export, without rebuilding or exporting again.
                manifest['app_store_connect'] = signing.upload(ipa, build)
                shutil.copyfile(ipa, public / 'Unscroll.ipa')
                release.require(release.sha(public / 'Unscroll.ipa') == manifest['ipa']['sha256'], 'Retained IPA differs')
                manifest['checks'] += ['code-signature', 'exported-ipa', 'app-store-processing']
            path = public / 'build-manifest.json'
            write_json(path, manifest)
            release.check_contents(path.name, path.read_bytes())
            release.checksums(public, sorted(public.iterdir()))
            print(f'Public evidence: {public}')
        finally:
            try:
                if mac_store_signing:
                    mac_store_signing.cleanup()
            finally:
                try:
                    if signing:
                        signing.cleanup()
                finally:
                    if mac_signing:
                        mac_signing.cleanup()
