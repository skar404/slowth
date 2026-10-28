"""Tag dispatch and publication fail closed without Apple credentials."""
from contextlib import nullcontext, redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from release_tools import automatic, core


class TagTests(unittest.TestCase):
    def verify(self, *, object_type=b'tag', commit=b'head', tip=b'head', remote=b'object\trefs/tags/v2026.8.3\n',
               marketing='2026.8.3', signature_failure=False, tag='v2026.8.3'):
        def git(*args, **kwargs):
            args = tuple(a.replace(tag, 'v2026.8.3') for a in args)
            return {('rev-parse', 'HEAD'): b'head',
                    ('cat-file', '-t', 'refs/slowth/verified-tags/v2026.8.3'): object_type,
                    ('rev-parse', 'refs/slowth/verified-tags/v2026.8.3^{commit}'): commit,
                    ('rev-parse', 'refs/slowth/verified-tags/v2026.8.3'): b'object',
                    ('ls-remote', '--refs', 'origin', 'refs/tags/v2026.8.3'): remote.replace(b'v2026.8.3', tag.encode()),
                    ('rev-parse', 'origin/main'): tip}.get(args, b'')
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), \
             patch.object(core, 'git', side_effect=git), \
             patch.object(core, 'origin_repo', return_value='owner/repo'), \
             patch.object(automatic, 'public_keyring', return_value=nullcontext()), \
             patch.object(automatic, 'source_version', return_value=(marketing, '18')), \
             patch.object(core, 'verify_signature', side_effect=RuntimeError('wrong signer') if signature_failure else None) as verify:
            result = automatic.verify_tag(tag)
        self.assertEqual(verify.call_count, 2)
        self.assertTrue(all(call.args[-1] == automatic.FINGERPRINT for call in verify.call_args_list))
        return result

    def test_matching_signed_tag_and_commit(self):
        self.assertEqual(self.verify(), ('owner/repo', 'head', '2026.8.3', '18'))

    def test_rc_matches_base_version_and_keeps_signature_and_tip_checks(self):
        self.assertEqual(self.verify(tag='v2026.8.3rc1'), ('owner/repo', 'head', '2026.8.3', '18'))
        for change in ({'marketing': '2026.8.4'}, {'signature_failure': True},
                       {'tip': b'other'}, {'object_type': b'commit'}):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                self.verify(tag='v2026.8.3rc1', **change)

    def test_checkout_lightweight_tag_does_not_hide_remote_annotated_object(self):
        with tempfile.TemporaryDirectory() as temp:
            source, runner = Path(temp) / 'origin', Path(temp) / 'runner'
            source.mkdir()
            def git(root, *args):
                return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL)
            git(source, 'init', '-b', 'main')
            git(source, 'config', 'user.name', 'Fixture')
            git(source, 'config', 'user.email', 'fixture@example.invalid')
            git(source, 'config', 'commit.gpgsign', 'false')
            (source / 'file').write_text('source')
            git(source, 'add', 'file')
            git(source, 'commit', '-m', 'fixture')
            git(source, '-c', 'tag.gpgsign=false', 'tag', '-a', 'v2026.8.3', '-m', 'fixture')
            git(source, 'clone', '--no-tags', str(source), str(runner))
            git(runner, '-c', 'tag.gpgsign=false', 'tag', 'v2026.8.3')
            head = git(runner, 'rev-parse', 'HEAD').decode().strip()
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), \
                 patch.object(core, 'ROOT', runner), \
                 patch.object(core, 'git', side_effect=lambda *args, **kwargs: git(runner, *args)), \
                 patch.object(core, 'origin_repo', return_value='owner/repo'), \
                 patch.object(automatic, 'public_keyring', return_value=nullcontext()), \
                 patch.object(core, 'verify_signature') as verify, \
                 patch.object(automatic, 'source_version', return_value=('2026.8.3', '18')):
                self.assertEqual(automatic.verify_tag('v2026.8.3')[1], head)
            self.assertEqual(git(runner, 'cat-file', '-t', 'refs/tags/v2026.8.3').strip(), b'commit')
            self.assertEqual(git(runner, 'cat-file', '-t', 'refs/slowth/verified-tags/v2026.8.3').strip(), b'tag')
            self.assertEqual(verify.call_args_list[0].args[2], 'refs/slowth/verified-tags/v2026.8.3')

    def test_lightweight_tag_wrong_commit_moved_main_and_wrong_version(self):
        for change in ({'object_type': b'commit'}, {'commit': b'other'}, {'tip': b'other'},
                       {'remote': b'changed\trefs/tags/v2026.8.3\n'}, {'marketing': '2026.8.2'},
                       {'signature_failure': True}):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                self.verify(**change)

    def test_tag_names_no_options_paths_or_leading_zeros(self):
        for tag in ('v2026.08.3', 'v2026.8.03', 'v2026.8', 'models-v10-1', '--all', '../v2026.8.3',
                    'v2026.8.3rc', 'v2026.8.3rc0', 'v2026.8.3rc01', 'v2026.8.3rc-1',
                    'v2026.8.3-rc1', 'v2026.8.3rc1extra'):
            with self.subTest(tag=tag), self.assertRaises(RuntimeError): automatic.app_tag(tag)

    def test_cli_creates_signed_stable_and_rc_tags(self):
        import release
        for rc, expected in (([], 'v2026.10.6'), (['--rc', '1'], 'v2026.10.6rc1')):
            args = release.parser().parse_args(['tag', '--gpg-key', automatic.FINGERPRINT, *rc])
            with patch.object(core, 'snapshot', return_value=(Path('source'), 'head', 'tree')), \
                 patch.object(automatic.models, 'published_source'), \
                 patch.object(core, 'versions', return_value=('2026.10.6', '26', {})), \
                 patch.object(core, 'remote_preflight') as preflight, \
                 patch.object(core, 'signing_key', return_value=automatic.FINGERPRINT), \
                 patch.object(core, 'verify_signature'), patch.object(core, 'git') as git, \
                 redirect_stdout(io.StringIO()):
                automatic.tag(args)
            preflight.assert_called_once_with(core.ROOT, 'head', expected)
            signing = git.call_args_list[0].args
            self.assertIn('-s', signing)
            self.assertIn(expected, signing)
            self.assertEqual(git.call_args.args[-1], f'refs/tags/{expected}:refs/tags/{expected}')

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


class RecoveryTests(unittest.TestCase):
    def test_source_run_requires_numeric_previous_run_on_main(self):
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'GITHUB_REF': 'refs/heads/main',
                                     'GITHUB_RUN_ID': '456'}):
            self.assertEqual(automatic.evidence_run('123'), '123')
            self.assertEqual(automatic.evidence_run(None), '456')
            for value in ('456', '../123', '0', '-1'):
                with self.subTest(value=value), self.assertRaises(RuntimeError):
                    automatic.evidence_run(value)
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'GITHUB_REF': 'refs/heads/other'}):
            with self.assertRaises(RuntimeError): automatic.evidence_run('123')

    def test_historical_tag_uses_signed_source_version_and_requires_ancestor(self):
        calls = []
        def git(*args, **kwargs):
            calls.append(args)
            return {('rev-parse', 'HEAD'): b'publisher',
                    ('cat-file', '-t', 'refs/slowth/verified-tags/v2026.10.4'): b'tag',
                    ('rev-parse', 'refs/slowth/verified-tags/v2026.10.4^{commit}'): b'app',
                    ('rev-parse', 'refs/slowth/verified-tags/v2026.10.4'): b'object',
                    ('ls-remote', '--refs', 'origin', 'refs/tags/v2026.10.4'):
                        b'object\trefs/tags/v2026.10.4\n'}.get(args, b'')
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': 'owner/repo',
                                     'GITHUB_SHA': 'publisher'}), \
             patch.object(core, 'git', side_effect=git), \
             patch.object(core, 'origin_repo', return_value='owner/repo'), \
             patch.object(automatic, 'public_keyring', return_value=nullcontext()), \
             patch.object(core, 'verify_signature') as signature, \
             patch.object(automatic, 'source_version', return_value=('2026.10.4', '24')) as version:
            self.assertEqual(automatic.verify_tag('v2026.10.4', tip=False, historical=True),
                             ('owner/repo', 'app', '2026.10.4', '24'))
            version.assert_called_once_with('app')
            self.assertIn(('merge-base', '--is-ancestor', 'app', 'publisher'), calls)
            self.assertIn(('merge-base', '--is-ancestor', 'app', 'origin/main'), calls)
            self.assertEqual(signature.call_args.args[2], 'app')
            with patch.object(core, 'git', side_effect=RuntimeError('not ancestor')):
                with self.assertRaises(RuntimeError):
                    automatic.verify_tag('v2026.10.4', tip=False, historical=True)

    def test_recovery_checksums_attest_publisher_not_original_app_commit(self):
        with patch.dict(os.environ, {'GITHUB_SHA': 'publisher'}), \
             patch.object(automatic, 'evidence_run', return_value='123'), \
             patch.object(automatic, 'verify_tag', return_value=('owner/repo', 'app', '2026.10.4', '24')), \
             patch.object(automatic, 'successful_build') as evidence, \
             patch.object(automatic, 'absent_release'), patch.object(core, 'run') as run, \
             patch.object(automatic, 'publish_assets'):
            automatic.publish('v2026.10.4', Path('output'), source_run='123')
            evidence.assert_called_once_with('owner/repo', '123', 'app')
            args = run.call_args_list[0].args
            self.assertEqual(args[args.index('--source-digest') + 1], 'publisher')

    def test_flat_archive_verification_in_empty_workspace_keeps_swift_pin_check(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            hashes = {}
            for model, directory in core.MODEL_DIRS.items():
                package = root / directory / (model + '.mlpackage')
                for name in core.PACKAGE_FILES:
                    path = package / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b'{}' if path.suffix == '.json' else b'model fixture')
                hashes[model] = core.package_sha(package)
            source = {'RealtimeShield/FlatClassifier.swift':
                      (core.ROOT / 'RealtimeShield/FlatClassifier.swift').read_bytes()}
            for runtime in core.RUNTIME_HASHES:
                data = (core.ROOT / runtime).read_bytes()
                target = root / runtime
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                source[runtime] = data
            bundle = root / 'models.tar.gz'
            core.model_bundle(root, bundle)
            def git(*args, **kwargs):
                self.assertEqual(args[0], 'show')
                self.assertTrue(args[1].startswith('signed-source:'))
                return source[args[1].split(':', 1)[1]]
            with patch.object(core, 'MODEL_HASHES', hashes), \
                 patch.object(core, 'git', side_effect=git):
                automatic.verify_model_archive(bundle, 'signed-source')
                source['RealtimeShield/FlatClassifier.swift'] = b'wrong runtime pin'
                with self.assertRaisesRegex(RuntimeError, 'Swift runtime metadata pin differs'):
                    automatic.verify_model_archive(bundle, 'signed-source')


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

    def publication(self, corrupt=False, tag='v2026.8.3', reported_prerelease=None):
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
                    return json.dumps({'isDraft': False, 'tagName': tag,
                                       'isPrerelease': ('rc' in tag if reported_prerelease is None else reported_prerelease), 'url': 'https://example.invalid',
                                       'assets': [{'name': n} for n in automatic.ASSETS]}).encode()
            with patch.object(core, 'run', side_effect=run), redirect_stdout(io.StringIO()):
                if corrupt:
                    with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
                        automatic.publish_assets(output, 'owner/repo', tag)
                else:
                    automatic.publish_assets(output, 'owner/repo', tag)
        return calls

    def test_rc_is_prerelease_and_never_latest(self):
        calls = self.publication(tag='v2026.8.3rc1')
        for operation in ('create', 'edit'):
            args = next(c for c in calls if c[:3] == ('gh', 'release', operation))
            self.assertIn('--prerelease', args)
            self.assertIn('--latest=false', args)
            self.assertNotIn('--latest', args)
        stable = self.publication()
        edit = next(c for c in stable if c[:3] == ('gh', 'release', 'edit'))
        self.assertIn('--latest', edit)
        self.assertNotIn('--prerelease', edit)

    def test_wrong_published_prerelease_flag_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'Published release verification failed'):
            self.publication(tag='v2026.8.3rc1', reported_prerelease=False)

    def test_corrupt_rc_download_stays_draft(self):
        calls = self.publication(corrupt=True, tag='v2026.8.3rc1')
        self.assertFalse(any(c[:3] == ('gh', 'release', 'edit') for c in calls))

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
