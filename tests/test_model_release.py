"""Publication boundaries: corrupted inputs or assets must never become public."""
import contextlib
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from release_tools import core, models


class PreparationTests(unittest.TestCase):
    def test_tag_cannot_be_a_path_or_git_option(self):
        for tag in ('../models-v10', '--delete', 'models-', 'v2026.8.2', 'models-x/y', 'models-@{x}'):
            with self.subTest(tag=tag), self.assertRaises(RuntimeError):
                models.model_tag(tag)

    def test_missing_explicit_key_stops_before_snapshot(self):
        args = SimpleNamespace(tag='models-v10-1', publish=True, gpg_key=None)
        with patch.object(core, 'snapshot') as snapshot:
            with self.assertRaisesRegex(RuntimeError, 'requires --gpg-key'):
                models.prepare(args)
            snapshot.assert_not_called()

    def test_dirty_public_source_is_rejected_before_remote_lookup(self):
        with patch.object(core, 'git', return_value=b'committed-tree\n'), \
             patch.object(core, 'origin_repo') as origin:
            with self.assertRaisesRegex(RuntimeError, 'Commit and push'):
                models.published_source('head', 'modified-tree')
            origin.assert_not_called()

    def test_model_validation_failure_never_signs_or_publishes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = SimpleNamespace(tag='models-v10-1', output=root/'out', publish=True,
                                   gpg_key='A'*40, model_bundle=None, notes=None)
            with patch.object(core, 'snapshot', return_value=(root, 'head', 'tree')), \
                 patch.object(models, 'published_source', return_value='owner/repo'), \
                 patch.object(core, 'remote_preflight'), \
                 patch.object(core, 'signing_key', return_value='A'*40), \
                 patch.object(core, 'verify_signature'), patch.object(core, 'run'), \
                 patch.object(models, 'check_source'), \
                 patch.object(core, 'install_models', side_effect=RuntimeError('Model SHA-256 mismatch')), \
                 patch.object(models, 'sign_checksums') as sign, \
                 patch.object(models, 'publish') as publish:
                with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
                    models.prepare(args)
                sign.assert_not_called()
                publish.assert_not_called()
                self.assertFalse(args.output.exists())

    def test_checksum_signature_must_use_requested_key(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(core, 'run', side_effect=[None, b'[GNUPG:] VALIDSIG WRONG 2026-01-01 0 0 4 0 1 8 00 WRONG\n']):
                with self.assertRaisesRegex(RuntimeError, 'Checksum signer differs'):
                    models.sign_checksums(Path(temp), 'A'*40)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)
        for name in models.ASSETS:
            (self.output/name).write_text('expected bytes '+name)
        (self.output/'release-notes.md').write_text('Public notes')

    def run_publication(self, corrupt=False, fail_create=False, source_changed=False):
        operations = []
        def git(*args, **kwargs):
            operations.append(('git', *map(str,args)))
            if args[0] == 'rev-parse': return b'head\n'
            return b''
        def run(*args, **kwargs):
            operations.append(tuple(map(str,args)))
            if args[:3] == ('gh','release','create') and fail_create:
                raise RuntimeError('upload failed')
            if args[:3] == ('gh','release','download'):
                download = Path(args[args.index('--dir')+1])
                for name in models.ASSETS:
                    shutil.copyfile(self.output/name,download/name)
                if corrupt:
                    (download/models.ASSET).write_text('unexpected bytes')
            if args[:3] == ('gh','release','view'):
                return json.dumps({'isDraft':False,'tagName':'models-v10-1','url':'https://example.invalid/release',
                                   'assets':[{'name':name} for name in models.ASSETS]}).encode()
            return b''
        with patch.object(core, 'snapshot', return_value=(self.output, 'head', 'other' if source_changed else 'tree')), \
             patch.object(core, 'origin_repo', return_value='owner/repo'), \
             patch.object(core, 'remote_preflight'), patch.object(core, 'verify_signature'), \
             patch.object(core, 'git', side_effect=git), patch.object(core, 'run', side_effect=run), \
             contextlib.redirect_stdout(io.StringIO()):
            try:
                models.publish(self.output, 'owner/repo', 'models-v10-1', 'head', 'tree', 'A'*40)
            except RuntimeError as error:
                return operations, str(error)
        return operations, None

    def test_changed_source_stops_before_tag_or_push(self):
        ops, error = self.run_publication(source_changed=True)
        self.assertIn('Source changed',error)
        self.assertEqual(ops,[])

    def test_changed_uploaded_bytes_leave_draft_unpublished(self):
        ops, error = self.run_publication(corrupt=True)
        self.assertIn('checksum mismatch',error)
        self.assertFalse(any(op[:3] == ('gh','release','edit') for op in ops))

    def test_upload_failure_does_not_publish_or_automatically_retry(self):
        ops, error = self.run_publication(fail_create=True)
        self.assertEqual(error,'upload failed')
        self.assertEqual(sum(op[:3] == ('gh','release','create') for op in ops),1)
        self.assertFalse(any(op[:3] == ('gh','release','edit') for op in ops))

    def test_success_pushes_only_model_tag_and_verifies_before_publication(self):
        ops, error = self.run_publication()
        self.assertIsNone(error)
        pushes=[op for op in ops if op[0]=='git' and 'push' in op]
        self.assertEqual(len(pushes),1)
        self.assertEqual(pushes[0][-1],'refs/tags/models-v10-1:refs/tags/models-v10-1')
        self.assertFalse(any('commit' in op or 'commit-tree' in op for op in ops))
        self.assertLess(next(i for i,op in enumerate(ops) if op[:3]==('gh','release','download')),
                        next(i for i,op in enumerate(ops) if op[:3]==('gh','release','edit')))

    def test_extra_asset_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            download=Path(temp)
            for name in models.ASSETS: shutil.copyfile(self.output/name,download/name)
            (download/'credentials.txt').write_text('unexpected')
            with self.assertRaisesRegex(RuntimeError,'asset list differs'):
                models.verify_download(self.output,download)


class DispatchTests(unittest.TestCase):
    def test_corrupt_download_never_dispatches_an_apple_upload(self):
        calls=[]
        def run(*args, **kwargs):
            calls.append(args)
            if args[:3]==('gh','release','view'):
                return json.dumps({'isDraft':False,'tagName':'models-v10-1','assets':[{'name':models.ASSET}]}).encode()
            return b''
        with patch.object(core,'snapshot',return_value=(Path('/unused'), 'head', 'tree')), \
             patch.object(models,'published_source',return_value='owner/repo'), \
             patch.object(core,'run',side_effect=run), \
             patch.object(core,'install_models',side_effect=RuntimeError('Model SHA-256 mismatch')):
            with self.assertRaisesRegex(RuntimeError,'SHA-256 mismatch'):
                models.dispatch('models-v10-1',True)
        self.assertFalse(any(call[:2]==('gh','workflow') for call in calls))


if __name__ == '__main__':
    unittest.main()
