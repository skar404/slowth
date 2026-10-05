#!/usr/bin/env python3
"""Public snapshot, model import, and signing safety boundaries."""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
PUBLIC_DIRS = {
    'App', 'Extension', 'ExtensionIOS', 'DeviceActivityIOS', 'iOS', 'Localization',
    'RealtimeShield', 'Shared', 'ShieldActionIOS', 'ShieldConfigIOS', 'WebExt',
    'scripts', 'tests',
}
PUBLIC_FILES = {
    '.github/workflows/ci.yml', '.github/workflows/release-ci.yml',
    'docs/BUILD_TRUST.md',
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
MODEL_DIR = 'data-model/exports/cascade-v10-study-20260929-1356/diverse/ios-resources'
MODEL_HASHES = {
    'AppRouterV10': '275be8a74dcb00f2382071fc5fde6b8ff110878f8b56e66dd0a25c63c11651d5',
    'YouTubeDetectorV10': '10daf9a48edddba4a480e0376648563094f2196621bf10eb93731cf8c4bd755e',
    'InstagramDetectorV10': '64a05d722c785cc62bb4420e6aa1ff14dcc751a30e35b6edbcc93eb396c8b09a',
    'FacebookDetectorV10': '807e5f31e091db26c8285e92e04f7ebc9cf224db1d25be4d72dbcf8306136c8d',
    'XDetectorV10': 'eec050ecc6ba357eac0f430cd2f76ca3c9765bd8130304ef81d8a1a86f6e3b99',
}
RUNTIME = 'RealtimeShield/CascadeV10RuntimeMetadata.json'
RUNTIME_HASH = '41ee86e2d0410dd455297c31c8a839aa2d72fb2b39a9698060e0a412ae63896a'
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
    if config.resolve() != (source / 'Configs/Local.xcconfig').resolve():
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
