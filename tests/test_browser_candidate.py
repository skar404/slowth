import importlib.util
import plistlib
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('browser_candidate', ROOT / 'scripts/prepare_browser_candidate.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class BrowserCandidateTests(unittest.TestCase):
    def test_prepares_host_only_configuration_without_modifying_beta(self):
        source = (ROOT / 'iOS/Unscroll.entitlements').read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            destination = module.prepare(Path(directory))
            info = plistlib.loads((destination / 'Info.plist').read_bytes())
            entitlements = plistlib.loads((destination / 'Browser.entitlements').read_bytes())
            self.assertTrue(entitlements['com.apple.developer.web-browser'])
            self.assertNotIn('com.apple.developer.associated-domains', entitlements)
            self.assertNotIn('com.apple.developer.browser.app-installation', entitlements)
            schemes = {scheme for group in info['CFBundleURLTypes'] for scheme in group['CFBundleURLSchemes']}
            self.assertEqual(schemes, {'http', 'https', 'slowth'})
            self.assertTrue(info['SlowthBrowserEntitlementCandidate'])
            self.assertNotIn('NSPhotoLibraryUsageDescription', info)
            for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription'):
                self.assertTrue(info[key])
        self.assertEqual((ROOT / 'iOS/Unscroll.entitlements').read_bytes(), source)
        self.assertNotIn('com.apple.developer.web-browser', plistlib.loads(source))
