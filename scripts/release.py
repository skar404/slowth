#!/usr/bin/env python3
"""Build and publish a signed public snapshot. Python standard library only."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_DIRS = {
    'App', 'Extension', 'ExtensionIOS', 'DeviceActivityIOS', 'iOS', 'Localization',
    'RealtimeShield', 'Shared', 'ShieldActionIOS', 'ShieldConfigIOS', 'WebExt',
    'scripts', 'tests',
}
PUBLIC_FILES = {
    'project.yml', 'README.md', 'LICENSE', 'APP_STORE_DESCRIPTION.txt',
    'APP_REVIEW_NOTES.md', '.gitignore', 'Configs/Local.xcconfig.example',
    'Configs/Slowth.storekit', 'docs/icon.png', 'docs/showcase-00.jpg',
    'docs/showcase-01.jpg', 'docs/showcase-02.jpg',
}
PRIVATE_PARTS = {
    'data-model', 'logs', 'build', '.venv', '.hermes', '.playwright-mcp',
    'analitics', 'app-store', 'tmp', 'temp', 'sandbox', 'dataset', 'datasets',
    '__pycache__', '.git', '.agents', '.codex', 'DerivedData', 'node_modules',
}
# Retired tracked artifacts are removed from the release tree, kept on disk.
RETIRED = ('RealtimeShield/SurfaceDetector.mlpackage/',
           'RealtimeShield/SurfaceDetectorMetadata.json')
MODEL_DIR = 'data-model/exports/v15-v6-app-20260920-154340/ios-resources'
MODEL_HASHES = {
    'AppRouterV6': '6701a2b056a75cb0d54690658c7e9bfb5ed2823eacae3e50fb0dc7cea8f40728',
    'YouTubeDetectorV6': '83ccc751b04944c3a2561a00d5c0ecd2e6409a57bf5787e6a2b63ac151d87125',
    'InstagramDetectorV6': 'a28cc67c39930d440620727adb09016877db828f20fb757a230f88c0db459cd8',
}
RUNTIME = 'RealtimeShield/CascadeV6RuntimeMetadata.json'
RUNTIME_HASH = 'b56dfc94cecd8f6165c3a94bc3781fb76cff98df87516a40bc09577887e4fcbd'
PACKAGE_FILES = {'Manifest.json', 'Data/com.apple.CoreML/model.mlmodel',
                 'Data/com.apple.CoreML/weights/weight.bin'}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(*args, cwd=ROOT, env=None, capture=False, input=None):
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                            input=input, stdout=subprocess.PIPE if capture else None,
                            check=True)
    return result.stdout if capture else None


def git(*args, **kwargs):
    return run('git', *args, **kwargs)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def public_path(name):
    p = PurePosixPath(name)
    return (not p.is_absolute() and '..' not in p.parts
            and not any(x in PRIVATE_PARTS or x.startswith('.env') or x in {'.gitattributes', '.gitmodules'} for x in p.parts)
            and not any(x.endswith(('.mlpackage', '.mlmodelc')) for x in p.parts)
            and p.suffix.lower() not in {'.pt', '.pth', '.ckpt', '.pem', '.key', '.p12', '.mobileprovision', '.pyc'}
            and name != 'RealtimeShield/SurfaceDetectorMetadata.json'
            and (name in PUBLIC_FILES or p.parts[0] in PUBLIC_DIRS))


def check_contents(name, data):
    require(not re.search(rb'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----', data),
            f'Private key in {name}')
    require(not re.search(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/', data),
            f'Local user path in {name}')
    if name.endswith(('.json', '.xcstrings', '.storekit')):
        json.loads(data)


def check_staged(root):
    names = git('diff', '--cached', '--name-only', '-z', '--diff-filter=ACMRTUXB',
                cwd=root, capture=True).decode().split('\0')
    for name in filter(None, names):
        require(public_path(name), f'Non-public staged path: {name}; unstage it first')


def snapshot(root, temp):
    check_staged(root)
    git('diff', '--check', cwd=root)
    git('diff', '--cached', '--check', cwd=root)
    head = git('rev-parse', 'HEAD', cwd=root, capture=True).decode().strip()
    env = dict(os.environ, GIT_INDEX_FILE=str(temp / 'index'))
    git('read-tree', head, cwd=root, env=env)
    tracked = git('ls-files', '-z', cwd=root, capture=True).decode().split('\0')
    # Existing worktree deletions are intentional, including retired root tooling.
    for name in filter(None, tracked):
        if not (root / name).exists() or any(name.startswith(p) for p in RETIRED):
            git('update-index', '--force-remove', '--', name, cwd=root, env=env)
    for name in sorted(PUBLIC_DIRS | PUBLIC_FILES):
        if (root / name).exists():
            git('add', '-A', '--', name, cwd=root, env=env)
    # Broad source directories must never sneak model artifacts back into git.
    entries = {}
    for record in git('ls-files', '--stage', '-z', cwd=root, env=env, capture=True).split(b'\0'):
        if not record:
            continue
        info, raw_name = record.split(b'\t', 1)
        name = raw_name.decode()
        if any(name.startswith(p) for p in RETIRED):
            git('update-index', '--force-remove', '--', name, cwd=root, env=env)
            continue
        require(public_path(name), f'Non-public file in proposed commit: {name}')
        require(info.split()[0] in (b'100644', b'100755'), f'Symlink/submodule forbidden: {name}')
        entries[name] = info.split()[1].decode()
    git('diff', '--cached', '--check', cwd=root, env=env)
    tree = git('write-tree', cwd=root, env=env, capture=True).decode().strip()
    source = temp / 'source'
    source.mkdir()
    archive = git('archive', '--format=tar', tree, cwd=root, capture=True)
    extracted = set()
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        # Entries come from the path/mode-validated tree, not user supplied tar.
        for member in tar:
            require(member.isdir() or member.isfile(), f'Unexpected git archive entry: {member.name}')
            target = source / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                require(member.name in entries, f'Unexpected archive path: {member.name}')
                target.parent.mkdir(parents=True, exist_ok=True)
                data = tar.extractfile(member).read()
                blob = git('hash-object', '--stdin', input=data, cwd=root, capture=True).decode().strip()
                require(blob == entries[member.name], f'Git attributes modified snapshot: {member.name}')
                extracted.add(member.name)
                check_contents(member.name, data)
                target.write_bytes(data)
                target.chmod(member.mode & 0o777)
    require(extracted == set(entries), 'Git attributes omitted files from snapshot')
    return source, head, tree


def versions(source):
    spec = json.loads(run('xcodegen', 'dump', '--type', 'json', '--no-env',
                          cwd=source, capture=True))
    version = str(spec['settings']['base']['MARKETING_VERSION'])
    build = str(spec['settings']['base']['CURRENT_PROJECT_VERSION'])
    require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'Invalid marketing version')
    require(re.fullmatch(r'[1-9]\d*', build), 'Build must be a positive integer')
    def walk(value):
        if isinstance(value, dict):
            for k, v in value.items():
                if k in ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION'):
                    require(str(v) == (version if k == 'MARKETING_VERSION' else build),
                            f'Inconsistent {k}: {v}')
                walk(v)
        elif isinstance(value, list):
            for v in value:
                walk(v)
    walk(spec)
    require(json.loads((source / 'WebExt/manifest.json').read_text())['version'] == version,
            'WebExtension version differs')
    labels = re.findall(r'Slowth v([0-9.]+)', (source / 'WebExt/app.html').read_text())
    require(labels == [version], 'UI version differs')
    return version, build, spec


def model_files():
    return {f'{MODEL_DIR}/{name}.mlpackage/{part}' for name in MODEL_HASHES for part in PACKAGE_FILES} | {RUNTIME}


def package_sha(package):
    digest = hashlib.sha256()
    for path in sorted(package.rglob('*')):
        require(not path.is_symlink(), f'Model symlink: {path.name}')
        if path.is_file():
            digest.update(path.relative_to(package).as_posix().encode() + b'\0')
            digest.update(path.read_bytes())
    return digest.hexdigest()


def verify_models(source):
    require(sha(source / RUNTIME) == RUNTIME_HASH, 'Runtime metadata SHA-256 mismatch')
    require(RUNTIME_HASH in (source / 'RealtimeShield/CascadePolicy.swift').read_text(),
            'Swift runtime metadata pin differs')
    for name, expected in MODEL_HASHES.items():
        path = source / MODEL_DIR / (name + '.mlpackage')
        actual = {p.relative_to(path).as_posix() for p in path.rglob('*') if p.is_file()}
        require(actual == PACKAGE_FILES, f'Unexpected/missing model files: {name}')
        require(package_sha(path) == expected, f'Model SHA-256 mismatch: {name}')
        for file in path.rglob('*'):
            if file.is_file():
                check_contents(file.name, file.read_bytes())


def install_models(source, local_root, bundle):
    if bundle:
        # Never extractall: reject links, traversal, duplicates, extras and tar bombs.
        seen = set()
        with tarfile.open(bundle, 'r:gz') as tar:
            for member in tar:
                require(member.isfile() and member.name in model_files()
                        and member.name not in seen and 0 <= member.size <= 64 * 1024 * 1024,
                        f'Unsafe model bundle member: {member.name}')
                seen.add(member.name)
                data = tar.extractfile(member).read()
                dest = source / member.name
                if member.name == RUNTIME:
                    require(data == dest.read_bytes(), 'Bundle runtime metadata differs from source')
                else:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(data)
        require(seen == model_files(), 'Incomplete model bundle')
    else:
        for name in model_files() - {RUNTIME}:
            src = local_root / name
            require(src.is_file() and not src.is_symlink()
                    and src.resolve().is_relative_to(local_root.resolve()), f'Invalid model input: {name}')
            dest = source / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
    verify_models(source)


def model_bundle(source, destination):
    with tarfile.open(destination, 'w:gz', format=tarfile.USTAR_FORMAT) as tar:
        for name in sorted(model_files()):
            data = (source / name).read_bytes()
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mode = 0o644
            tar.addfile(entry, io.BytesIO(data))


def prepare(source, root, bundle, spec):
    install_models(source, root, bundle)
    if not bundle and (root / 'data-model').exists():
        # Verify derivation from the private export locally; never copy it to snapshot.
        run(sys.executable, root / 'scripts/prepare_release_resources.py', '--check', cwd=root)
    run(sys.executable, 'scripts/prepare_release_resources.py', '--check', '--runtime-only', cwd=source)
    config = root / 'Configs/Local.xcconfig'
    require(config.is_file() and not config.is_symlink(), 'Configure Configs/Local.xcconfig before building')
    shutil.copyfile(config, source / 'Configs/Local.xcconfig')
    run('xcodegen', 'generate', cwd=source)
    # Check generated project settings without invoking provisioning/network access.
    pbx = plistlib.loads(run('plutil', '-convert', 'xml1', '-o', '-',
                            source / 'Unscroll.xcodeproj/project.pbxproj', capture=True))
    version, build = str(spec['settings']['base']['MARKETING_VERSION']), str(spec['settings']['base']['CURRENT_PROJECT_VERSION'])
    for obj in pbx['objects'].values():
        settings = obj.get('buildSettings', {})
        for key, expected in [('MARKETING_VERSION', version), ('CURRENT_PROJECT_VERSION', build)]:
            if key in settings:
                require(str(settings[key]) == expected, f'Generated project {key} differs')
    run('node', '--test', *sorted((source / 'WebExt/tests').glob('*.test.cjs')), cwd=source)


def archives(source, output, prefix, version, build, spec):
    assets = []
    apps = []
    for platform, scheme in [('iOS', 'Unscroll (iOS)'), ('macOS', 'Unscroll')]:
        archive = output / f'{prefix}-{platform}.xcarchive'
        run('xcodebuild', '-quiet', '-project', 'Unscroll.xcodeproj', '-scheme', scheme,
            '-configuration', 'Release', '-destination', f'generic/platform={platform}',
            '-derivedDataPath', output / f'derived-{platform}', '-archivePath', archive,
            '-allowProvisioningUpdates', 'archive', cwd=source)
        found = list((archive / 'Products/Applications').glob('*.app'))
        require(len(found) == 1, f'Missing app in {platform} archive')
        app = found[0]
        apps.append(app)
        for bundle in [app, *app.rglob('*.appex')]:
            info_path = bundle / ('Contents/Info.plist' if (bundle / 'Contents').exists() else 'Info.plist')
            info = plistlib.loads(info_path.read_bytes())
            require(info['CFBundleShortVersionString'] == version and info['CFBundleVersion'] == build,
                    f'Built version/build differs: {bundle.name}')
        run('codesign', '--verify', '--deep', '--strict', app, cwd=source)
        if platform == 'iOS':
            run(sys.executable, 'scripts/verify_app_configuration.py', '--configuration', 'Release', '--app', app, cwd=source)
        target = output / f'{prefix}-{platform}.xcarchive.zip'
        run('ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', archive, target)
        run('unzip', '-tq', target)
        assets.append(target)
    run(sys.executable, 'scripts/verify_localization_bundles.py', *apps, cwd=source)
    run('bash', 'scripts/test_app_localization.sh', apps[1], cwd=source)
    webkit = output / 'webkit-localization'
    run('xcrun', 'swiftc', '-parse-as-library', '-o', webkit, 'scripts/verify_webkit_localization.swift', cwd=source)
    run(sys.executable, 'scripts/verify_webkit_localizations.py', webkit, output / 'webkit-results', cwd=source)
    return assets


def origin_repo(root):
    urls = git('remote', 'get-url', '--push', '--all', 'origin', cwd=root, capture=True).decode().splitlines()
    require(len(urls) == 1, 'origin must have exactly one push URL')
    url = urls[0]
    require(git('remote', 'get-url', 'origin', cwd=root, capture=True).decode().strip() == url,
            'origin fetch and push URLs must match')
    match = re.fullmatch(r'(?:git@github\.com:|https://github\.com/)([\w.-]+/[\w.-]+?)(?:\.git)?', url)
    require(match, 'origin must be a github.com SSH/HTTPS repository URL')
    return match[1]


def remote_preflight(root, head, tag):
    require(git('symbolic-ref', '--short', 'HEAD', cwd=root, capture=True).decode().strip() == 'main', 'Release requires main')
    refs = git('ls-remote', '--refs', 'origin', 'refs/heads/main', f'refs/tags/{tag}', cwd=root, capture=True).decode().splitlines()
    require(refs == [f'{head}\trefs/heads/main'],
            'origin/main must equal HEAD and the release tag must not exist remotely; do not push unaudited local history')
    require(not git('tag', '--list', tag, cwd=root, capture=True).strip(), 'Tag already exists locally')


def signing_key(key):
    require(key and re.fullmatch(r'[A-Fa-f0-9]{16,64}!?', key), 'Explicit GPG key ID/fingerprint required (--gpg-key or RELEASE_GPG_KEY)')
    lines = run('gpg', '--batch', '--with-colons', '--list-secret-keys', key, capture=True).decode().splitlines()
    fingerprints = []
    primary = False
    for line in lines:
        fields = line.split(':')
        if fields[0] == 'sec':
            primary = True
        elif fields[0] == 'fpr' and primary:
            fingerprints.append(fields[9])
            primary = False
    require(len(fingerprints) == 1, 'GPG key must resolve to one secret primary key')
    return fingerprints[0]


def verify_signature(root, kind, ref, fingerprint):
    proc = subprocess.run(['git', '-c', 'gpg.format=openpgp', '-c', 'gpg.program=gpg',
                           f'verify-{kind}', '--raw', ref], cwd=root, capture_output=True, check=True)
    valid = [line.split() for line in proc.stderr.decode().splitlines() if line.startswith('[GNUPG:] VALIDSIG ')]
    require(any(fingerprint in (line[2], line[-1]) for line in valid), 'Signature does not match requested GPG key')


def checksums(output, assets):
    result = {p.name: sha(p) for p in assets}
    (output / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in sorted(result.items())))
    run('shasum', '-a', '256', '-c', 'SHA256SUMS', cwd=output)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', nargs='?', choices=['publish', 'build', 'check'], default='publish')
    parser.add_argument('--gpg-key', default=os.environ.get('RELEASE_GPG_KEY'))
    parser.add_argument('--release-notes', type=Path)
    parser.add_argument('--model-bundle', type=Path)
    parser.add_argument('--output', type=Path, help='New output directory (default: release-output/<tag>-build<N>)')
    args = parser.parse_args()
    require(not os.environ.get('PYTHONOPTIMIZE'), 'PYTHONOPTIMIZE would disable existing verification assertions')
    require(not any(os.environ.get(k) for k in ('GIT_INDEX_FILE', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES')), 'Custom Git environment is unsupported')
    publish = args.mode == 'publish'
    fingerprint = signing_key(args.gpg_key) if publish else None
    notes = args.release_notes.read_bytes() if args.release_notes else None
    if publish:
        require(notes and notes.strip(), '--release-notes must name a nonempty file')
        check_contents('release notes', notes)
    require(git('rev-parse', '--show-toplevel', capture=True).decode().strip() == str(ROOT), 'Run from the main repository checkout')
    index_path = Path(git('rev-parse', '--path-format=absolute', '--git-path', 'index', capture=True).decode().strip())
    original_index = index_path.read_bytes()
    with tempfile.TemporaryDirectory(prefix='slowth-release-') as temporary:
        temp = Path(temporary)
        source, head, tree = snapshot(ROOT, temp)
        version, build, spec = versions(source)
        tag = f'v{version}'
        repo = None
        if publish:
            repo = origin_repo(ROOT)
            remote_preflight(ROOT, head, tag)
            run('gh', 'auth', 'status')
            run('gh', 'repo', 'view', repo, '--json', 'nameWithOwner')
            # Compare the prior public build. Unknown App Store uploads must be
            # reflected in project.yml by the release operator before invocation.
            previous = git('show', f'{head}:project.yml', capture=True).decode()
            old_builds = [int(x) for x in re.findall(r'CURRENT_PROJECT_VERSION:\s*["\']?(\d+)', previous)]
            require(old_builds and int(build) > max(old_builds), 'Increment every build setting above the previous public build before publishing')
        prepare(source, ROOT, args.model_bundle.resolve() if args.model_bundle else None, spec)
        if args.mode == 'check':
            print(f'Public snapshot verified: {tag} build {build}, tree {tree}. No commit, tag or publication.')
            return
        output = (args.output or ROOT / 'release-output' / f'{tag}-build{build}').resolve()
        output.mkdir(parents=True, exist_ok=False)
        prefix = f'Slowth-{tag}-build{build}'
        bundle = output / f'{prefix}-models.tar.gz'
        model_bundle(source, bundle)
        # Read our own asset through the same strict importer used by rebuilds.
        install_models(source, ROOT, bundle)
        assets = [bundle, *archives(source, output, prefix, version, build, spec)]
        commit = head if tree == git('rev-parse', f'{head}^{{tree}}', capture=True).decode().strip() else None
        if publish:
            require(origin_repo(ROOT) == repo, 'origin changed during build')
            remote_preflight(ROOT, head, tag)
            require(index_path.read_bytes() == original_index, 'Index changed during build; retry with stable staging')
            require(git('rev-parse', 'HEAD', capture=True).decode().strip() == head, 'HEAD changed during build')
            commit = git('-c', 'gpg.format=openpgp', '-c', 'gpg.program=gpg', 'commit-tree', tree,
                         '-p', head, f'-S{args.gpg_key}', input=f'Release {tag}\n'.encode(), capture=True).decode().strip()
            verify_signature(ROOT, 'commit', commit, fingerprint)
        manifest = {
            'schema_version': 1, 'marketing_version': version, 'build_number': build,
            'tag': tag, 'commit': commit, 'source_tree': tree, 'base_commit': head,
            'xcode': run('xcodebuild', '-version', capture=True).decode().strip(),
            'macos': run('sw_vers', capture=True).decode().strip(),
            'models': [{'path': f'{MODEL_DIR}/{name}.mlpackage', 'sha256': digest} for name, digest in MODEL_HASHES.items()],
            'package_hash_algorithm': 'SHA256 of sorted relative UTF-8 file paths, NUL, file bytes',
            'model_files': {name: sha(source / name) for name in sorted(model_files())},
            'runtime_metadata': {'path': RUNTIME, 'sha256': RUNTIME_HASH},
            'assets': {p.name: sha(p) for p in assets},
            'rebuild': [f'git checkout {tag}', 'cp Configs/Local.xcconfig.example Configs/Local.xcconfig',
                        '# Set your signing team and bundle prefix in Configs/Local.xcconfig',
                        f'shasum -a 256 -c SHA256SUMS',
                        f'scripts/release.sh build --model-bundle {shlex.quote(bundle.name)}'],
            'unpack_models': f'tar -xzf {shlex.quote(bundle.name)}',
            'note': 'Rebuild uses the pinned inputs; code signatures and archive timestamps are not reproducible byte-for-byte.',
        }
        manifest_path = output / 'release-manifest.json'
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        check_contents(manifest_path.name, manifest_path.read_bytes())
        assets.append(manifest_path)
        checksums(output, assets)
        assets.append(output / 'SHA256SUMS')
        if not publish:
            print(f'Build verified. Assets: {output}')
            return
        # Sign checksums too: a signed source tag alone does not authenticate binaries.
        signature = output / 'SHA256SUMS.asc'
        run('gpg', '--batch', '--armor', '--local-user', args.gpg_key, '--detach-sign', '--output', signature, output / 'SHA256SUMS')
        run('gpg', '--verify', signature, output / 'SHA256SUMS')
        assets.append(signature)
        git('-c', 'gpg.format=openpgp', '-c', 'gpg.program=gpg', 'tag', '-s', '-u', args.gpg_key, tag, commit,
            '-m', f'Release {tag}\n\nSHA256SUMS SHA-256: {sha(output / "SHA256SUMS")}')
        verify_signature(ROOT, 'tag', tag, fingerprint)
        require(index_path.read_bytes() == original_index, 'Index changed before commit installation')
        git('update-ref', 'refs/heads/main', commit, head)
        git('read-tree', tree)
        # Atomic push prevents a branch-only publication when tag push fails.
        git('-c', 'push.followTags=false', 'push', '--atomic', 'origin', f'{commit}:refs/heads/main', f'refs/tags/{tag}:refs/tags/{tag}')
        notes_path = temp / 'release-notes.txt'
        notes_path.write_bytes(notes)
        # Stage assets in a draft; only make the release public after hash validation.
        run('gh', 'release', 'create', tag, *assets, '--repo', repo, '--verify-tag', '--draft', '--title', f'Slowth {tag}', '--notes-file', notes_path)
        download = temp / 'download'
        run('gh', 'release', 'download', tag, '--repo', repo, '--dir', download)
        require({p.name for p in download.iterdir()} == {p.name for p in assets}, 'Uploaded asset list differs')
        for path in assets:
            require(sha(download / path.name) == sha(path), f'Uploaded checksum mismatch: {path.name}')
        run('gh', 'release', 'edit', tag, '--repo', repo, '--draft=false')
        result = json.loads(run('gh', 'release', 'view', tag, '--repo', repo, '--json', 'url,isDraft,tagName,assets', capture=True))
        require(not result['isDraft'] and result['tagName'] == tag
                and {x['name'] for x in result['assets']} == {p.name for p in assets}, 'Published release verification failed')
        print(f'Published {result["url"]}\nLocal assets: {output}')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f'Release stopped: {error}', file=sys.stderr)
        sys.exit(1)
