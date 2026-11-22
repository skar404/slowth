"""Artifact boundary tests: offline builds, old archives, and failed import isolation."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import model_assets as assets


class ModelAssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'app'
        self.exports = self.root / 'exports'
        runtime = self.app / 'RealtimeShield/TestMetadata.json'
        runtime.parent.mkdir(parents=True)
        runtime.write_bytes(b'{}')
        self.weight = b'frozen weights'
        path = self.exports / 'run/Test.mlpackage/weight.bin'
        path.parent.mkdir(parents=True)
        path.write_bytes(self.weight)
        registry = {'resources': [{'path': 'run/Test.mlpackage', 'profiles': ['Debug', 'Release'],
                                  'files': {'weight.bin': hashlib.sha256(self.weight).hexdigest()}}],
                    'runtime_metadata': [{'path': 'RealtimeShield/TestMetadata.json',
                                          'profiles': ['Debug', 'Release'],
                                          'sha256': hashlib.sha256(b'{}').hexdigest()}]}
        self.mock = patch.object(assets, 'REGISTRY', registry)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def archive(self, *, corrupt=False, extra=None):
        archive = self.root / 'input.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for name in assets.files('Release'):
                data = b'{}' if name.startswith('RealtimeShield/') else (b'bad' if corrupt else self.weight)
                member = tarfile.TarInfo(name)
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
            if extra:
                member = tarfile.TarInfo(extra)
                tar.addfile(member, io.BytesIO(b''))
        return archive

    def test_export_import_and_archive_roundtrip_without_dataset(self):
        assets.prepare(self.app, 'Debug', exports_root=self.exports)
        output = self.root / 'output.tar.gz'
        assets.write_bundle(self.app, 'Release', output)
        with tarfile.open(output) as tar:
            self.assertIn('data-model/exports/run/Test.mlpackage/weight.bin', tar.getnames())
        self.exports.rename(self.root / 'dataset-unavailable')
        assets.prepare(self.app, 'Release', bundle=output)
        assets.verify(self.app, 'Debug')
        self.assertFalse((self.app / 'data-model').exists())

    def test_failed_import_preserves_prepared_resources(self):
        assets.prepare(self.app, 'Release', exports_root=self.exports)
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            assets.prepare(self.app, 'Release', bundle=self.archive(corrupt=True))
        assets.verify(self.app, 'Release')

    def test_unexpected_archive_members_are_rejected(self):
        for extra in ('../escape', '/absolute', 'data-model/private.txt', 'RealtimeShield/TestMetadata.json'):
            with self.subTest(extra=extra), self.assertRaisesRegex(ValueError, 'Unsafe'):
                assets.prepare(self.app, 'Release', bundle=self.archive(extra=extra))
        self.assertFalse((self.app / 'Models').exists())

    def test_source_escape_and_unexpected_files_are_rejected(self):
        source = self.exports / 'run/Test.mlpackage/weight.bin'
        source.unlink()
        outside = self.root / 'outside.bin'
        outside.write_bytes(self.weight)
        source.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'Invalid model input'):
            assets.prepare(self.app, 'Release', exports_root=self.exports)
        source.unlink()
        source.write_bytes(self.weight)
        (source.parent / 'extra').write_bytes(b'private')
        with self.assertRaisesRegex(ValueError, 'Unexpected model package'):
            assets.prepare(self.app, 'Release', exports_root=self.exports)

    def test_destination_link_cannot_redirect_import(self):
        outside = self.root / 'elsewhere'
        outside.mkdir()
        (self.app / 'Models').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'Unsafe model destination'):
            assets.prepare(self.app, 'Release', exports_root=self.exports)
        self.assertEqual(list(outside.iterdir()), [])

    def test_xcode_and_registry_model_resources_agree(self):
        # Real registry: additions to Xcode must not silently bypass import checks.
        import re
        root = Path(__file__).resolve().parents[1]
        registry = json.loads((root / 'scripts/model-assets.json').read_text())
        references = set(re.findall(r'- path: Models/exports/(\S+)', (root / 'project.yml').read_text()))
        self.assertEqual(references, {entry['path'] for entry in registry['resources']})
        self.assertEqual([r['path'].split('/')[-1] for r in registry['resources'] if 'Release' in r['profiles']],
                         ['FlatDetector15.mlpackage'])


if __name__ == '__main__':
    unittest.main()
