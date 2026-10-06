"""Tag dispatch and publication fail closed without Apple credentials."""
from contextlib import nullcontext, redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from release_tools import automatic, core


class TagTests(unittest.TestCase):
    def verify(self, *, object_type=b'tag', commit=b'head', tip=b'head', remote=b'object\trefs/tags/v2026.8.3\n',
               marketing='2026.8.3', signature_failure=False):
        def git(*args, **kwargs):
            return {('rev-parse', 'HEAD'): b'head',
                    ('cat-file', '-t', 'refs/tags/v2026.8.3'): object_type,
                    ('rev-parse', 'refs/tags/v2026.8.3^{commit}'): commit,
                    ('rev-parse', 'refs/tags/v2026.8.3'): b'object',
                    ('ls-remote', '--refs', 'origin', 'refs/tags/v2026.8.3'): remote,
                    ('rev-parse', 'origin/main'): tip}.get(args, b'')
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), \
             patch.object(core, 'git', side_effect=git), \
             patch.object(core, 'origin_repo', return_value='owner/repo'), \
             patch.object(automatic, 'public_keyring', return_value=nullcontext()), \
             patch.object(automatic, 'source_version', return_value=(marketing, '18')), \
             patch.object(core, 'verify_signature', side_effect=RuntimeError('wrong signer') if signature_failure else None) as verify:
            result = automatic.verify_tag('v2026.8.3')
        self.assertEqual(verify.call_count, 2)
        self.assertTrue(all(call.args[-1] == automatic.FINGERPRINT for call in verify.call_args_list))
        return result

    def test_matching_signed_tag_and_commit(self):
        self.assertEqual(self.verify(), ('owner/repo', 'head', '2026.8.3', '18'))

    def test_lightweight_tag_wrong_commit_moved_main_and_wrong_version(self):
        for change in ({'object_type': b'commit'}, {'commit': b'other'}, {'tip': b'other'},
                       {'remote': b'changed\trefs/tags/v2026.8.3\n'}, {'marketing': '2026.8.2'},
                       {'signature_failure': True}):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                self.verify(**change)

    def test_tag_names_no_options_paths_or_leading_zeros(self):
        for tag in ('v2026.08.3', 'v2026.8.03', 'v2026.8', 'models-v10-1', '--all', '../v2026.8.3'):
            with self.subTest(tag=tag), self.assertRaises(RuntimeError): automatic.app_tag(tag)

    def test_no_dispatch_if_tag_verification_fails(self):
        with patch.object(automatic, 'verify_tag', side_effect=RuntimeError('bad tag')), patch.object(core, 'run') as run:
            with self.assertRaises(RuntimeError): automatic.dispatch('v2026.8.3')
            run.assert_not_called()

    def test_existing_draft_or_release_prevents_dispatch(self):
        with patch.object(core, 'run', return_value=b'[[{"tag_name":"v2026.8.3"}]]'):
            with self.assertRaisesRegex(RuntimeError, 'already exists'): automatic.absent_release('owner/repo', 'v2026.8.3')

    def test_dispatch_targets_main_with_tag_and_pinned_models(self):
        with patch.object(automatic, 'verify_tag', return_value=('owner/repo', 'head', '2026.8.3', '18')), \
             patch.object(automatic, 'absent_release'), patch.object(core, 'run') as run, redirect_stdout(io.StringIO()):
            automatic.dispatch('v2026.8.3')
        args = run.call_args.args
        self.assertEqual(args[args.index('--ref') + 1], 'main')
        for value in ('release_tag=v2026.8.3', 'testflight=true', f'model_release={automatic.MODEL_RELEASE}'):
            self.assertIn(value, args)

    def test_main_gate_rejects_unsigned_mode_and_unpinned_models(self):
        for env in ({'TESTFLIGHT': 'false'}, {'MODEL_RELEASE': 'changed'}, {'MODEL_ASSET': 'changed.tar.gz'}):
            values = {'GITHUB_REF': 'refs/heads/main', 'TESTFLIGHT': 'true',
                      'MODEL_RELEASE': automatic.MODEL_RELEASE, 'MODEL_ASSET': 'Slowth-models.tar.gz', **env}
            with patch.dict(os.environ, values), \
                 patch.object(automatic, 'verify_tag', return_value=('owner/repo', 'head', '2026.8.3', '18')), \
                 patch.object(automatic, 'absent_release'), self.assertRaises(RuntimeError):
                automatic.check('v2026.8.3')


class BuildEvidenceTests(unittest.TestCase):
    def responses(self, conclusion='success', source='head'):
        return [json.dumps({'head_sha': source, 'head_branch': 'main', 'event': 'workflow_dispatch',
                            'path': '.github/workflows/release-ci.yml'}).encode(),
                b'[{"artifacts":[{"name":"build-evidence-123-1","expired":false}]}]',
                json.dumps([{'jobs': [{'name': 'build', 'conclusion': conclusion}]}]).encode()]

    def test_publish_retry_uses_retained_successful_build_attempt(self):
        with patch.object(core, 'run', side_effect=self.responses()) as run:
            self.assertEqual(automatic.successful_build('owner/repo', '123', 'head'), '1')
        self.assertIn('/attempts/1/jobs?', run.call_args.args[-1])

    def test_failed_build_and_other_source_rejected(self):
        for change in ({'conclusion': 'failure'}, {'source': 'other'}):
            with patch.object(core, 'run', side_effect=self.responses(**change)), self.assertRaises(RuntimeError):
                automatic.successful_build('owner/repo', '123', 'head')


class PublicationTests(unittest.TestCase):
    def test_untrusted_checksums_never_create_release(self):
        with patch.object(automatic, 'run_context'), \
             patch.object(automatic, 'verify_tag', return_value=('owner/repo', 'head', '2026.8.3', '18')), \
             patch.object(automatic, 'absent_release'), \
             patch.object(core, 'run', side_effect=RuntimeError('untrusted checksums')) as run, \
             patch.object(automatic, 'publish_assets') as publish:
            with self.assertRaisesRegex(RuntimeError, 'untrusted checksums'):
                automatic.publish('v2026.8.3', Path('unused'))
            publish.assert_not_called()
            self.assertEqual(run.call_count, 1)

    def publication(self, corrupt=False):
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            for name in automatic.ASSETS | {'release-notes.md'}: (output / name).write_text('expected ' + name)
            def run(*args, **kwargs):
                calls.append(args)
                if args[:3] == ('gh', 'release', 'download'):
                    destination = Path(args[args.index('--dir') + 1])
                    for name in automatic.ASSETS: shutil.copyfile(output / name, destination / name)
                    if corrupt: (destination / 'Unscroll.ipa').write_text('corrupt')
                if args[:3] == ('gh', 'release', 'view'):
                    return json.dumps({'isDraft': False, 'tagName': 'v2026.8.3', 'url': 'https://example.invalid',
                                       'assets': [{'name': n} for n in automatic.ASSETS]}).encode()
            with patch.object(core, 'run', side_effect=run), redirect_stdout(io.StringIO()):
                if corrupt:
                    with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
                        automatic.publish_assets(output, 'owner/repo', 'v2026.8.3')
                else:
                    automatic.publish_assets(output, 'owner/repo', 'v2026.8.3')
        return calls

    def test_corrupt_download_stays_draft(self):
        calls = self.publication(corrupt=True)
        self.assertFalse(any(c[:3] == ('gh', 'release', 'edit') for c in calls))

    def test_publish_only_after_download_verified_no_tag_mutation(self):
        calls = self.publication()
        download = next(i for i, c in enumerate(calls) if c[:3] == ('gh', 'release', 'download'))
        edit = next(i for i, c in enumerate(calls) if c[:3] == ('gh', 'release', 'edit'))
        self.assertLess(download, edit)
        self.assertFalse(any(c[0] == 'git' for c in calls))


if __name__ == '__main__':
    unittest.main()
