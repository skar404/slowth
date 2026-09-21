"""Safety boundaries for release automation; no network, signing or Xcode required."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'scripts/release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / 'repo'
        self.root.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Release Tests')
        self.git('config', 'user.email', 'release@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.write('README.md', 'Public\n')
        self.git('add', 'README.md')
        self.git('commit', '-qm', 'Initial')
        self.work = self.base / 'snapshot'
        self.work.mkdir()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, stderr=subprocess.PIPE)

    def write(self, name, data):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(data)
        return p

    def test_allowlist_python_and_index_unchanged(self):
        self.write('scripts/tool.py', 'print("public")\n')
        self.write('tests/test_tool.py', '# public\n')
        self.write('data-model/private.py', '# never publish\n')
        self.write('unknown/secret', 'private\n')
        before = (self.root / '.git/index').read_bytes()
        source, _, tree = release.snapshot(self.root, self.work)
        self.assertTrue((source / 'scripts/tool.py').exists())
        self.assertFalse((source / 'data-model').exists())
        self.assertFalse((source / 'unknown').exists())
        self.assertEqual(before, (self.root / '.git/index').read_bytes())
        self.assertEqual(len(tree), 40)

    def test_private_staged_file_stops_without_changing_index(self):
        self.write('data-model/private.py', '# private\n')
        self.git('add', 'data-model/private.py')
        before = (self.root / '.git/index').read_bytes()
        with self.assertRaisesRegex(RuntimeError, 'Non-public staged'):
            release.snapshot(self.root, self.work)
        self.assertEqual(before, (self.root / '.git/index').read_bytes())

    def test_nested_private_path_is_rejected(self):
        self.write('scripts/dataset/private.csv', 'private\n')
        with self.assertRaisesRegex(RuntimeError, 'Non-public file'):
            release.snapshot(self.root, self.work)

    def test_symlink_is_rejected(self):
        (self.root / 'App').mkdir()
        (self.root / 'App/key').symlink_to('/etc/passwd')
        with self.assertRaisesRegex(RuntimeError, 'Symlink'):
            release.snapshot(self.root, self.work)

    def test_unknown_tracked_path_is_rejected(self):
        self.write('private.txt', 'private\n')
        self.git('add', 'private.txt')
        self.git('commit', '-qm', 'Private local ancestor')
        with self.assertRaisesRegex(RuntimeError, 'Non-public file'):
            release.snapshot(self.root, self.work)

    def test_deleted_retired_tools_are_removed(self):
        old = self.write('pyproject.toml', '[project]\n')
        self.git('add', 'pyproject.toml')
        self.git('commit', '-qm', 'Old tool')
        old.unlink()
        source, _, _ = release.snapshot(self.root, self.work)
        self.assertFalse((source / 'pyproject.toml').exists())

    def test_export_ignore_cannot_hide_file(self):
        (self.root / '.git/info/attributes').write_text('README.md export-ignore\n')
        with self.assertRaisesRegex(RuntimeError, 'omitted files'):
            release.snapshot(self.root, self.work)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'RealtimeShield').mkdir()
        (self.root / release.RUNTIME).write_text('{}')

    def archive(self, names, kind=tarfile.REGTYPE):
        path = self.root / 'models.tar.gz'
        with tarfile.open(path, 'w:gz') as tar:
            for name in names:
                entry = tarfile.TarInfo(name)
                entry.type = kind
                entry.linkname = '/etc/passwd' if kind == tarfile.SYMTYPE else ''
                entry.size = 2 if kind == tarfile.REGTYPE else 0
                tar.addfile(entry, io.BytesIO(b'{}') if entry.size else None)
        return path

    def test_traversal_links_duplicates_and_extras(self):
        for names, kind in [(['../escape'], tarfile.REGTYPE),
                            (['/tmp/escape'], tarfile.REGTYPE),
                            ([release.RUNTIME], tarfile.SYMTYPE),
                            ([release.RUNTIME, release.RUNTIME], tarfile.REGTYPE),
                            (['data-model/private.py'], tarfile.REGTYPE)]:
            with self.subTest(names=names, kind=kind):
                with self.assertRaisesRegex(RuntimeError, 'Unsafe'):
                    release.install_models(self.root, self.root, self.archive(names, kind))

    def test_incomplete_bundle(self):
        with self.assertRaisesRegex(RuntimeError, 'Incomplete'):
            release.install_models(self.root, self.root, self.archive([release.RUNTIME]))

    def test_runtime_mismatch(self):
        (self.root / release.RUNTIME).write_text('changed')
        with self.assertRaisesRegex(RuntimeError, 'metadata differs'):
            release.install_models(self.root, self.root, self.archive([release.RUNTIME]))

    def test_complete_but_corrupt_bundle(self):
        with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
            release.install_models(self.root, self.root, self.archive(sorted(release.model_files())))

    def test_real_model_roundtrip(self):
        if not (release.ROOT / release.MODEL_DIR).exists():
            self.skipTest('Private local model inputs are unavailable')
        (self.root / release.RUNTIME).write_bytes((release.ROOT / release.RUNTIME).read_bytes())
        (self.root / 'RealtimeShield/CascadePolicy.swift').write_bytes((release.ROOT / 'RealtimeShield/CascadePolicy.swift').read_bytes())
        release.install_models(self.root, release.ROOT, None)
        bundle = self.root / 'roundtrip.tar.gz'
        release.model_bundle(self.root, bundle)
        release.install_models(self.root, release.ROOT, bundle)
        weight = next((self.root / release.MODEL_DIR).rglob('weight.bin'))
        weight.write_bytes(b'corrupted')
        with self.assertRaisesRegex(RuntimeError, 'Model SHA-256 mismatch'):
            release.verify_models(self.root)


class PreflightTests(unittest.TestCase):
    def test_reject_private_material_and_bad_json(self):
        for data in [b'-----BEGIN ' + b'PRIVATE KEY-----', b'/Users/' + b'alice/private/checkpoint.pt']:
            with self.assertRaises(RuntimeError):
                release.check_contents('file.txt', data)
        with self.assertRaises(ValueError):
            release.check_contents('metadata.json', b'{broken')

    def test_unpublished_history_or_existing_tag_blocks(self):
        for remote in [b'other\trefs/heads/main\n', b'head\trefs/heads/main\nsha\trefs/tags/v1.0.0\n']:
            with patch.object(release, 'git', side_effect=[b'main\n', remote]):
                with self.assertRaisesRegex(RuntimeError, 'origin/main'):
                    release.remote_preflight(release.ROOT, 'head', 'v1.0.0')

    def test_no_automatic_signing_key(self):
        with patch.object(release, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Explicit GPG'):
                release.signing_key(None)
            run.assert_not_called()

    def test_signature_must_match_requested_primary_key(self):
        result = subprocess.CompletedProcess([], 0, b'', b'[GNUPG:] VALIDSIG SUBKEY 2026-01-01 0 0 4 0 22 8 00 PRIMARY\n')
        with patch.object(release.subprocess, 'run', return_value=result):
            release.verify_signature(release.ROOT, 'commit', 'sha', 'PRIMARY')
            with self.assertRaisesRegex(RuntimeError, 'requested GPG key'):
                release.verify_signature(release.ROOT, 'tag', 'tag', 'WRONG')

    def test_build_failure_never_signs_or_pushes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            index = root / 'index'
            index.write_bytes(b'unchanged')
            notes = root / 'notes.txt'
            notes.write_text('Release notes')
            calls = []

            def fake_git(*args, **kwargs):
                calls.append(args)
                if args == ('rev-parse', '--show-toplevel'):
                    return str(root).encode()
                if args == ('rev-parse', '--path-format=absolute', '--git-path', 'index'):
                    return str(index).encode()
                if args == ('show', 'head:project.yml'):
                    return b'CURRENT_PROJECT_VERSION: 1\n'
                self.fail(f'Unexpected Git operation after failed build: {args}')

            with patch.object(release, 'ROOT', root), \
                 patch.object(release, 'git', side_effect=fake_git), \
                 patch.object(release, 'run') as run, \
                 patch.object(release, 'signing_key', return_value='PRIMARY'), \
                 patch.object(release, 'snapshot', return_value=(root, 'head', 'tree')), \
                 patch.object(release, 'versions', return_value=('1.0.0', '2', {})), \
                 patch.object(release, 'origin_repo', return_value='owner/repo'), \
                 patch.object(release, 'remote_preflight'), \
                 patch.object(release, 'prepare'), \
                 patch.object(release, 'model_bundle'), \
                 patch.object(release, 'install_models'), \
                 patch.object(release, 'archives', side_effect=RuntimeError('archive failed')), \
                 patch.object(sys, 'argv', ['release.py', '--gpg-key', 'A' * 40, '--release-notes', str(notes)]):
                with self.assertRaisesRegex(RuntimeError, 'archive failed'):
                    release.main()
                self.assertEqual(index.read_bytes(), b'unchanged')
                self.assertFalse(any('commit-tree' in c or 'push' in c or 'tag' in c for c in calls))
                self.assertFalse(any(c.args[:2] == ('gh', 'release') for c in run.call_args_list))

    def test_version_target_override_and_ui_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'WebExt').mkdir()
            (root / 'WebExt/manifest.json').write_text('{"version":"1.2.3"}')
            (root / 'WebExt/app.html').write_text('Slowth v1.2.3')
            spec = {'settings': {'base': {'MARKETING_VERSION': '1.2.3', 'CURRENT_PROJECT_VERSION': 12}},
                    'targets': {'Ext': {'settings': {'base': {'CURRENT_PROJECT_VERSION': 11}}}}}
            with patch.object(release, 'run', return_value=json.dumps(spec).encode()):
                with self.assertRaisesRegex(RuntimeError, 'Inconsistent'):
                    release.versions(root)
            del spec['targets']
            (root / 'WebExt/app.html').write_text('Slowth v1.2.2')
            with patch.object(release, 'run', return_value=json.dumps(spec).encode()):
                with self.assertRaisesRegex(RuntimeError, 'UI version'):
                    release.versions(root)


if __name__ == '__main__':
    unittest.main()
