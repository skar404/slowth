"""Check the iOS Safari integration using real source resources."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from prepare_ios_pause_resources import prepare


class PauseResourcesTests(unittest.TestCase):
    def test_overlay_is_repeatable_and_preserves_shared_sources(self):
        source = ROOT / 'WebExt'
        adapter = ROOT / 'iOS/WebPause'
        originals = {name: (source / name).read_bytes() for name in
                     ('manifest.json', 'background.js', 'content/common.js')}
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp)
            prepare(source, adapter, bundle)
            first = {str(p.relative_to(bundle)): p.read_bytes()
                     for p in bundle.rglob('*') if p.is_file()}
            prepare(source, adapter, bundle)
            self.assertEqual(first, {str(p.relative_to(bundle)): p.read_bytes()
                                    for p in bundle.rglob('*') if p.is_file()})
            manifest = json.loads((bundle / 'manifest.json').read_text())
            background = manifest['background']['scripts']
            self.assertEqual(background.count('pause-background.js'), 1)
            self.assertLess(background.index('rules-loader.js'), background.index('pause-background.js'))
            self.assertLess(background.index('pause-background.js'), background.index('background.js'))
            self.assertIn('alarms', manifest['permissions'])
            for script in manifest['content_scripts']:
                self.assertEqual(script['js'].count('pause-policy.js'), 1)
            self.assertIn('ns.pauseSettings(', (bundle / 'content/common.js').read_text())
            self.assertIn('ns.getStateCached(site)', (bundle / 'background.js').read_text())
        self.assertEqual(originals, {name: (source / name).read_bytes() for name in originals})

    def test_changed_integration_anchor_fails_closed(self):
        from prepare_ios_pause_resources import replace_once
        for text in ('missing', 'anchor anchor'):
            with self.assertRaises(ValueError):
                replace_once(text, 'anchor', 'replacement')
