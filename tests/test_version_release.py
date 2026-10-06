"""A version must retain verified bytes from the intended successful CI build."""
from datetime import datetime, timedelta
import json
import shutil
import contextlib
import io
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from release_tools import core, macos, version


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name)
        for name in version.EVIDENCE:
            (self.output / name).write_text('artifact ' + name)
        self.manifest = {
            'repository': 'owner/repo', 'commit': 'head', 'source_tree': 'tree',
            'marketing_version': '2026.8.2', 'build_number': '15', 'kind': 'testflight-upload',
            'run_url': 'https://github.com/owner/repo/actions/runs/123/attempts/1',
            'model_packages': core.MODEL_HASHES, 'runtime_metadata_sha256': core.RUNTIME_HASH,
            'platforms': {'iOS': {'code_signed': True}, 'macOS': {'code_signed': True}},
            'ipa': {'name': 'Unscroll.ipa', 'sha256': core.sha(self.output / 'Unscroll.ipa')},
            'macos': {'name': 'Slowth-macOS.zip', 'sha256': core.sha(self.output / 'Slowth-macOS.zip'),
                      'notarization_status': 'Accepted'},
            'app_store_connect': {'build_number': '15', 'build_id': 'apple-build', 'processing_state': 'VALID',
                                  'app_store_published': False, 'platform': 'IOS', 'marketing_version': '2026.8.2'},
            'macos_app_store_connect': {'build_number': '15', 'build_id': 'mac-build', 'processing_state': 'VALID',
                                         'app_store_published': False, 'platform': 'MAC_OS', 'marketing_version': '2026.8.2'},
            'macos_testflight': {'name': 'Slowth-macOS-TestFlight.pkg',
                                'sha256': core.sha(self.output / 'Slowth-macOS-TestFlight.pkg')},
        }

    def verify(self):
        (self.output / 'build-manifest.json').write_text(json.dumps(self.manifest))
        return version.validate_evidence(self.output, 'owner/repo', '123', '1', 'head', 'tree', '2026.8.2', '15')

    def test_other_source_build_or_attempt_rejected(self):
        for field, wrong in [('commit', 'other'), ('source_tree', 'other'), ('build_number', '14'),
                             ('run_url', 'https://github.com/owner/repo/actions/runs/123/attempts/2')]:
            with self.subTest(field=field), patch.object(core, 'run') as run:
                old = self.manifest[field]
                self.manifest[field] = wrong
                with self.assertRaisesRegex(RuntimeError, 'identity'): self.verify()
                run.assert_not_called()
                self.manifest[field] = old

    def test_changed_binary_rejected_before_attestation(self):
        (self.output / 'Unscroll.ipa').write_text('changed binary')
        with patch.object(core, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Artifact differs'): self.verify()
            run.assert_not_called()

    def test_extra_private_artifact_rejected(self):
        (self.output / 'private.p12').write_text('not an allowed asset')
        with self.assertRaisesRegex(RuntimeError, 'asset list'): self.verify()

    def test_mac_testflight_cannot_claim_ios_processing_result(self):
        self.manifest['macos_app_store_connect'] = self.manifest['app_store_connect']
        with self.assertRaisesRegex(RuntimeError, 'MAC_OS'): self.verify()

    def test_changed_mac_testflight_package_is_rejected(self):
        (self.output / 'Slowth-macOS-TestFlight.pkg').write_bytes(b'changed package')
        with self.assertRaisesRegex(RuntimeError, 'Artifact differs'): self.verify()

    def test_unnotarized_mac_is_not_publishable(self):
        self.manifest['macos']['notarization_status'] = 'In Progress'
        with self.assertRaisesRegex(RuntimeError, 'notarized'): self.verify()

    def test_attestation_failure_stops_verification(self):
        with patch.object(core, 'run', side_effect=RuntimeError('untrusted attestation')) as run:
            with self.assertRaisesRegex(RuntimeError, 'untrusted'): self.verify()
            self.assertEqual(run.call_count, 1)

    def test_all_four_subjects_require_source_and_hosted_runner(self):
        with patch.object(core, 'run') as run:
            self.verify()
        self.assertEqual(run.call_count, 4)
        for call in run.call_args_list:
            args = call.args
            self.assertIn('--deny-self-hosted-runners', args)
            self.assertEqual(args[args.index('--source-digest') + 1], 'head')
            self.assertEqual(args[args.index('--source-ref') + 1], 'refs/heads/main')

    def test_wrong_workflow_or_failed_run_rejected(self):
        good = {'status': 'completed', 'conclusion': 'success', 'head_sha': 'head', 'head_branch': 'main',
                'event': 'workflow_dispatch', 'path': '.github/workflows/release-ci.yml'}
        version.validate_run(good, 'head')
        for field, value in [('conclusion', 'failure'), ('path', '.github/workflows/ci.yml'),
                             ('head_sha', 'other'), ('event', 'pull_request')]:
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                version.validate_run({**good, field: value}, 'head')


class VersionPublicationTests(unittest.TestCase):
    def publish(self, corrupt):
        operations = []
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)
            for name in version.ASSETS: (output / name).write_text('expected ' + name)
            (output / 'release-notes.md').write_text('Public notes')
            def run(*args, **kwargs):
                operations.append(args)
                if args[:3] == ('gh', 'release', 'download'):
                    destination = Path(args[args.index('--dir') + 1])
                    for name in version.ASSETS: shutil.copyfile(output / name, destination / name)
                    if corrupt: (destination / 'Unscroll.ipa').write_text('changed')
                if args[:3] == ('gh', 'release', 'view'):
                    return json.dumps({'isDraft': False, 'tagName': 'v2026.8.2', 'url': 'https://example.invalid',
                                       'assets': [{'name': n} for n in version.ASSETS]}).encode()
                return b''
            with patch.object(core, 'snapshot', return_value=(output, 'head', 'tree')), \
                 patch.object(core, 'origin_repo', return_value='owner/repo'), \
                 patch.object(core, 'remote_preflight'), patch.object(core, 'verify_signature'), \
                 patch.object(core, 'git', return_value=b'head\n') as git, \
                 patch.object(core, 'run', side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                if corrupt:
                    with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
                        version.publish(output, 'owner/repo', 'v2026.8.2', 'head', 'tree', 'A'*40)
                else:
                    version.publish(output, 'owner/repo', 'v2026.8.2', 'head', 'tree', 'A'*40)
                pushes = [c.args for c in git.call_args_list if 'push' in c.args]
                self.assertEqual(len(pushes), 1)
                self.assertEqual(pushes[0][-1], 'refs/tags/v2026.8.2:refs/tags/v2026.8.2')
        return operations

    def test_corrupted_uploaded_binary_leaves_release_as_draft(self):
        calls = self.publish(corrupt=True)
        self.assertFalse(any(c[:3] == ('gh', 'release', 'edit') for c in calls))

    def test_assets_verified_before_making_version_public(self):
        calls = self.publish(corrupt=False)
        downloaded = next(i for i, c in enumerate(calls) if c[:3] == ('gh', 'release', 'download'))
        published = next(i for i, c in enumerate(calls) if c[:3] == ('gh', 'release', 'edit'))
        self.assertLess(downloaded, published)


class MacProfileTests(unittest.TestCase):
    def profile(self):
        return {'TeamIdentifier': ['TEAM'], 'ProvisionsAllDevices': True,
                'ExpirationDate': datetime.now() + timedelta(days=1),
                'Entitlements': {'com.apple.application-identifier': 'TEAM.com.example.app',
                                 'com.apple.security.application-groups': ['group.com.example.shared']}}

    def test_development_device_limited_or_wrong_group_rejected(self):
        for mutation in ('development', 'device', 'group', 'expired', 'team'):
            profile = self.profile()
            if mutation == 'development': profile['Entitlements']['com.apple.security.get-task-allow'] = True
            if mutation == 'device': profile['ProvisionedDevices'] = ['device']
            if mutation == 'group': profile['Entitlements']['com.apple.security.application-groups'] = []
            if mutation == 'expired': profile['ExpirationDate'] = datetime(2020, 1, 1)
            if mutation == 'team': profile['TeamIdentifier'] = ['OTHER']
            with self.subTest(mutation=mutation), patch.object(macos, 'required', return_value='com.example'):
                with self.assertRaises(RuntimeError): macos.validate_profile(profile, 'com.example.app', 'TEAM')

    def test_distribution_profile_accepted(self):
        with patch.object(macos, 'required', return_value='com.example'):
            macos.validate_profile(self.profile(), 'com.example.app', 'TEAM')


class MacStoreProfileTests(unittest.TestCase):
    def test_rejects_developer_id_development_wrong_platform_and_expired_profiles(self):
        from release_tools.macos_store import validate_profile
        from copy import deepcopy
        good = {'Platform': ['OSX'], 'TeamIdentifier': ['TEAM'],
                'ExpirationDate': datetime.now() + timedelta(days=1),
                'Entitlements': {'com.apple.application-identifier': 'TEAM.com.example.app',
                                 'com.apple.security.application-groups': ['group.com.example.shared']}}
        validate_profile(good, 'com.example.app', 'TEAM', 'group.com.example.shared')
        for change in ('developer-id', 'development', 'platform', 'expired', 'group'):
            profile = deepcopy(good)
            if change == 'developer-id': profile['ProvisionsAllDevices'] = True
            if change == 'development': profile['ProvisionedDevices'] = ['device']
            if change == 'platform': profile['Platform'] = ['iOS']
            if change == 'expired': profile['ExpirationDate'] = datetime(2020, 1, 1)
            if change == 'group': profile['Entitlements']['com.apple.security.application-groups'] = []
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                validate_profile(profile, 'com.example.app', 'TEAM', 'group.com.example.shared')


if __name__ == '__main__':
    unittest.main()
