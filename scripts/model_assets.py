"""Pinned app model resources; dataset paths are inputs only during preparation."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import shutil
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = json.loads((Path(__file__).with_name('model-assets.json')).read_text())


def entries(configuration):
    if configuration not in ('Debug', 'Release'):
        raise ValueError('Unknown model configuration')
    return [r for r in REGISTRY['resources'] if configuration in r['profiles']]


def files(configuration):
    result = {}
    for entry in entries(configuration):
        for child, digest in entry['files'].items():
            relative = entry['path'] + ('/' + child if child else '')
            result['data-model/exports/' + relative] = ('Models/exports/' + relative, digest)
    for entry in REGISTRY['runtime_metadata']:
        if configuration in entry['profiles']:
            result[entry['path']] = (entry['path'], entry['sha256'])
    return result


def safe_file(root, relative):
    path = root / relative
    if (not path.is_file() or path.is_symlink()
            or not path.resolve().is_relative_to(root.resolve())):
        raise ValueError(f'Invalid model input: {relative}')
    # Even internal aliases should not let writes modify an unintended resource.
    if any(parent.is_symlink() for parent in path.parents if parent != root and root in parent.parents):
        raise ValueError(f'Model directory is a symlink: {relative}')
    return path


def verify(root, configuration):
    root = Path(root)
    for _, (relative, expected) in files(configuration).items():
        path = safe_file(root, relative)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f'Model SHA-256 mismatch: {relative}')
    for entry in entries(configuration):
        path = root / 'Models/exports' / entry['path']
        if path.is_dir():
            actual = {p.relative_to(path).as_posix() for p in path.rglob('*') if p.is_file() or p.is_symlink()}
            if actual != set(entry['files']):
                raise ValueError(f'Unexpected model package files: {entry["path"]}')


def resource_maps(root, configuration):
    models, metadata = {}, {}
    for entry in entries(configuration):
        path = root / 'Models/exports' / entry['path']
        (models if path.suffix == '.mlpackage' else metadata)[path.stem] = path
    for entry in REGISTRY['runtime_metadata']:
        if configuration in entry['profiles']:
            path = root / entry['path']
            metadata[path.stem] = path
    return models, metadata


def prepare(root, configuration, *, exports_root=None, bundle=None):
    root = Path(root).resolve()
    if (exports_root is None) == (bundle is None):
        raise ValueError('Supply exactly one exports root or model bundle')
    expected = files(configuration)
    (root / 'build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='model-import-', dir=root / 'build') as temp:
        stage = Path(temp)
        # Runtime metadata is owned by the app; archives cannot replace it.
        for _, (relative, digest) in expected.items():
            if relative.startswith('RealtimeShield/'):
                source = safe_file(root, relative)
                dest = stage / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, dest)
        if bundle is not None:
            seen = set()
            with tarfile.open(bundle, 'r:gz') as archive:
                for member in archive:
                    if (not member.isfile() or member.name not in expected or member.name in seen
                            or not 0 <= member.size <= 64 * 1024 * 1024):
                        raise ValueError(f'Unsafe model bundle member: {member.name}')
                    seen.add(member.name)
                    relative, digest = expected[member.name]
                    data = archive.extractfile(member).read()
                    if hashlib.sha256(data).hexdigest() != digest:
                        raise ValueError(f'Model SHA-256 mismatch: {member.name}')
                    if relative.startswith('RealtimeShield/'):
                        if data != (stage / relative).read_bytes():
                            raise ValueError('Bundle runtime metadata differs from app')
                    else:
                        dest = stage / relative
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        dest.write_bytes(data)
            if seen != set(expected):
                raise ValueError('Incomplete model bundle')
        else:
            exports_root = Path(exports_root).expanduser().resolve(strict=True)
            for entry in entries(configuration):
                src = exports_root / entry['path']
                dest = stage / 'Models/exports' / entry['path']
                for child in entry['files']:
                    relative = entry['path'] + ('/' + child if child else '')
                    safe_file(exports_root, relative)
                if src.is_dir():
                    shutil.copytree(src, dest, symlinks=True)
                else:
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(src, dest)
        verify(stage, configuration)
        # Validate every destination before writing any model. Never follow links.
        for entry in entries(configuration):
            dest = root / 'Models/exports' / entry['path']
            if any(p.is_symlink() for p in [dest, *dest.parents] if p == root or root in p.parents):
                raise ValueError(f'Unsafe model destination: {entry["path"]}')
            if dest.exists():
                if dest.is_dir():
                    actual = {p.relative_to(dest).as_posix() for p in dest.rglob('*') if p.is_file() or p.is_symlink()}
                    if actual != set(entry['files']) or any(p.is_symlink() for p in dest.rglob('*')):
                        raise ValueError(f'Unexpected existing model files: {entry["path"]}')
                elif set(entry['files']) != {''}:
                    raise ValueError(f'Expected model directory: {entry["path"]}')
        for _, (relative, _) in expected.items():
            if relative.startswith('Models/'):
                dest = root / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(stage / relative, dest)
    verify(root, configuration)


def write_bundle(root, configuration, destination):
    verify(root, configuration)
    # Exclusive create prevents overwriting an existing evidence artifact.
    with Path(destination).open('xb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for name, (relative, _) in sorted(files(configuration).items()):
                data = (root / relative).read_bytes()
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))
