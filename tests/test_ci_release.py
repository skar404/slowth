"""CI provenance and signing boundaries, without Apple credentials or network."""
import base64
from datetime import datetime, timedelta
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import ci_release
import ci_signing
import release


class EvidenceTests(unittest.TestCase):
    def test_ci_refuses_modified_tree_and_wrong_workflow_revision(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            (source / 'Shared').mkdir()
            for tree, sha in [('modified', 'commit'), ('tree', 'different')]:
                with patch.object(release, 'git', return_value=b'tree\n'), \
                     patch.dict('os.environ', {'GITHUB_SHA': sha}):
                    with self.assertRaisesRegex(RuntimeError, 'exact committed'):
                        ci_release.identity(source, 'commit', tree, '2026.8.2', '13', True)
            self.assertFalse((source / 'BuildIdentity.json').exists())

    def test_local_uncommitted_build_does_not_claim_commit_or_ci(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            (source / 'Shared').mkdir()
            with patch.object(release, 'git', return_value=b'old-tree\n'):
                evidence = ci_release.identity(source, 'commit', 'new-tree', '2026.8.2', '13', False)
            self.assertIsNone(evidence['commit'])
            self.assertIsNone(evidence['run_url'])

    def test_extension_version_and_identity_are_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / 'Slowth.app'
            ext = app / 'PlugIns/Shield.appex'
            expected = {'commit': 'a' * 40}
            for bundle in (app, ext):
                bundle.mkdir(parents=True, exist_ok=True)
                (bundle / 'Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleShortVersionString': '2026.8.2', 'CFBundleVersion': '13',
                    'CFBundleIdentifier': 'example.' + bundle.stem, 'CFBundleExecutable': 'binary'}))
                (bundle / 'binary').write_bytes(b'code')
                (bundle / 'BuildIdentity.json').write_text(json.dumps(expected))
            self.assertEqual(len(ci_release.validate_bundles(app, '2026.8.2', '13', expected)), 2)
            info = plistlib.loads((ext / 'Info.plist').read_bytes())
            info['CFBundleVersion'] = '12'
            (ext / 'Info.plist').write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(RuntimeError, 'version differs'):
                ci_release.validate_bundles(app, '2026.8.2', '13', expected)
            info['CFBundleVersion'] = '13'
            (ext / 'Info.plist').write_bytes(plistlib.dumps(info))
            (ext / 'BuildIdentity.json').write_text('{}')
            with self.assertRaisesRegex(RuntimeError, 'identity differs'):
                ci_release.validate_bundles(app, '2026.8.2', '13', expected)

    def test_only_reviewed_workflows_are_public(self):
        self.assertTrue(release.public_path('.github/workflows/ci.yml'))
        self.assertTrue(release.public_path('.github/workflows/release-ci.yml'))
        self.assertFalse(release.public_path('.github/private.key'))
        self.assertFalse(release.public_path('.github/workflows/unknown.yml'))


class SigningTests(unittest.TestCase):
    def test_der_es256_conversion_and_rejection(self):
        self.assertEqual(ci_signing.jwt_signature(bytes.fromhex('3006020101020102')),
                         (1).to_bytes(32, 'big') + (2).to_bytes(32, 'big'))
        r = b'\x00' + b'\x80' * 32
        s = b'\x01' * 32
        der = bytes([0x30, 69, 2, 33]) + r + bytes([2, 32]) + s
        self.assertEqual(ci_signing.jwt_signature(der), r[1:] + s)
        for bad in (b'', der[:-1], der + b'\x00', b'\x30\x06\x03\x01\x01\x02\x01\x02'):
            with self.subTest(bad=bad):
                with self.assertRaises(RuntimeError):
                    ci_signing.jwt_signature(bad)

    def test_reject_wrong_team_bundle_expired_or_development_profiles(self):
        good = {'TeamIdentifier': ['ABCDEFGHIJ'], 'UUID': '11111111-2222-3333-4444-555555555555',
                'ExpirationDate': datetime.now() + timedelta(days=1),
                'Entitlements': {'application-identifier': 'ABCDEFGHIJ.example.ios', 'get-task-allow': False}}
        ci_signing.validate_profile(good, 'example.ios', 'ABCDEFGHIJ')
        for changes in ({'TeamIdentifier': ['OTHER']}, {'ProvisionedDevices': ['device']},
                        {'ProvisionsAllDevices': True}, {'ExpirationDate': datetime.now() - timedelta(days=1)},
                        {'Entitlements': {'application-identifier': 'ABCDEFGHIJ.wrong'}},
                        {'Entitlements': {'application-identifier': 'ABCDEFGHIJ.example.ios', 'get-task-allow': True}}):
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                ci_signing.validate_profile(good | changes, 'example.ios', 'ABCDEFGHIJ')

    def test_preflight_checks_all_build_pages_and_rejects_reused_number(self):
        env = {'GITHUB_REF': 'refs/heads/main', 'APPLE_TEAM_ID': 'ABCDEFGHIJ',
               'BUNDLE_ID_PREFIX': 'example.slowth', 'ASC_APP_ID': '123', 'ASC_KEY_ID': '1234567890',
               'ASC_ISSUER_ID': '11111111-2222-3333-4444-555555555555',
               'ASC_KEY_P8_BASE64': base64.b64encode(b'test-key').decode()}
        pages = [{'data': {'attributes': {'bundleId': 'example.slowth.ios'}}},
                 {'data': [{'attributes': {'version': '11'}}], 'links': {'next': '/page2'}},
                 {'data': [{'attributes': {'version': '14'}}], 'links': {'next': None}}]
        with tempfile.TemporaryDirectory() as temp, patch.dict('os.environ', env):
            signer = ci_signing.Signing(Path(temp) / 'signing')
            with patch.object(signer, 'api', side_effect=pages) as api:
                with self.assertRaisesRegex(RuntimeError, 'exceed uploaded build 14'):
                    signer.preflight('2026.8.2', '13')
                self.assertEqual(api.call_count, 3)
            signer.cleanup()

    def test_api_does_not_send_token_to_pagination_redirect_host(self):
        with tempfile.TemporaryDirectory() as temp:
            signer = ci_signing.Signing(Path(temp) / 'signing')
            with self.assertRaisesRegex(RuntimeError, 'pagination host'):
                signer.api('https://example.invalid/steal')
            signer.cleanup()

    def test_failed_upload_does_not_poll_or_claim_success(self):
        with tempfile.TemporaryDirectory() as temp:
            signer = ci_signing.Signing(Path(temp) / 'signing')
            signer.key_id, signer.issuer = 'key', 'issuer'
            ipa = Path(temp) / 'app.ipa'
            ipa.write_bytes(b'app')
            with patch.object(ci_signing, 'quiet', side_effect=RuntimeError('upload failed')), \
                 patch.object(signer, 'api') as api:
                with self.assertRaisesRegex(RuntimeError, 'upload failed'):
                    signer.upload(ipa, '13')
                api.assert_not_called()
            signer.cleanup()

    def test_upload_records_processed_build_without_claiming_store_publication(self):
        with tempfile.TemporaryDirectory() as temp:
            signer = ci_signing.Signing(Path(temp) / 'signing')
            signer.key_id, signer.issuer, signer.app_id = 'key', 'issuer', '123'
            signer.previous_build = 12
            ipa = Path(temp) / 'app.ipa'
            ipa.write_bytes(b'exact-export')
            pages = [{'data': []}, {'data': [{'id': 'apple-build-id', 'attributes': {'processingState': 'VALID'}}]}]
            with patch.object(ci_signing, 'quiet', return_value=b'--api-key <string>') as upload, \
                 patch.object(signer, 'api', side_effect=pages), \
                 patch.object(ci_signing.time, 'sleep'):
                result = signer.upload(ipa, '13')
                self.assertEqual(upload.call_count, 2)
                self.assertIn(ipa, upload.call_args.args)
                self.assertIn('--api-key', upload.call_args.args)
                self.assertEqual(result['build_id'], 'apple-build-id')
                self.assertFalse(result['app_store_published'])
            with patch.object(ci_signing, 'quiet', return_value=b''), patch.object(signer, 'api', return_value={
                'data': [{'id': 'apple-build-id', 'attributes': {'processingState': 'INVALID'}}]}):
                with self.assertRaisesRegex(RuntimeError, 'Apple rejected'):
                    signer.upload(ipa, '13')
            signer.cleanup()

    def test_modified_ipa_is_rejected_after_transport(self):
        with tempfile.TemporaryDirectory() as temp:
            signer = ci_signing.Signing(Path(temp) / 'signing')
            signer.key_id, signer.issuer = 'key', 'issuer'
            ipa = Path(temp) / 'app.ipa'
            ipa.write_bytes(b'exact-export')
            def transport(*args, **kwargs):
                if '--upload-app' in args:
                    ipa.write_bytes(b'changed')
                return b''
            with patch.object(ci_signing, 'quiet', side_effect=transport), \
                 patch.object(signer, 'api') as api:
                with self.assertRaisesRegex(RuntimeError, 'IPA changed'):
                    signer.upload(ipa, '13')
                api.assert_not_called()
            signer.cleanup()


if __name__ == '__main__':
    unittest.main()
