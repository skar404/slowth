"""Check install metadata and real launch JS without a browser or external account."""
import json
from pathlib import Path
import subprocess
import unittest
from html.parser import HTMLParser

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ('instagram', 'youtube', 'tiktok', 'facebook', 'x')

class Tags(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.tags = []
        self.feed(source)
    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))

class ShortcutTests(unittest.TestCase):
    def test_manifest_and_install_assets(self):
        for service in SERVICES:
            folder = ROOT / 'website/shortcuts' / service
            manifest = json.loads((folder / 'manifest.webmanifest').read_text())
            self.assertEqual(manifest['id'], f'/shortcuts/{service}/')
            self.assertEqual(manifest['scope'], manifest['id'])
            self.assertEqual(manifest['start_url'], manifest['id'] + '?launch=1')
            self.assertEqual(manifest['display'], 'standalone')
            self.assertTrue((folder / manifest['icons'][0]['src']).is_file())
            tags = Tags((folder / 'index.html').read_text()).tags
            self.assertIn(('meta', {'name': 'apple-mobile-web-app-capable', 'content': 'yes'}), tags)
            self.assertTrue(any(tag == 'a' and a.get('href') == f'slowth://web/{service}' for tag, a in tags))
            for tag, attrs in tags:
                for key in ('src', 'href'):
                    value = attrs.get(key, '')
                    if value and not value.startswith(('/', '?', 'slowth:')):
                        self.assertTrue((folder / value).exists(), value)

    def test_launch_behavior(self):
        result = subprocess.run(['node', '--test', str(ROOT / 'WebExt/tests/shortcuts.test.cjs')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
