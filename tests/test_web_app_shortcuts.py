"""Check install metadata and real launch JS without a browser or external account."""
import json
from pathlib import Path
import struct
import subprocess
import unittest
from html.parser import HTMLParser
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ('instagram', 'youtube', 'tiktok', 'facebook', 'x', 'threads', 'reddit', 'linkedin')

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
            icon_url = f'../assets/slowth-{service}-linen.png'
            icon = manifest['icons'][0]
            self.assertEqual(icon['src'], icon_url)
            self.assertEqual(icon['sizes'], '1024x1024')
            with (folder / icon_url).open('rb') as png:
                self.assertEqual(png.read(16), b'\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR')
                self.assertEqual(struct.unpack('>II', png.read(8)), (1024, 1024))
            tags = Tags((folder / 'index.html').read_text()).tags
            for rel in ('apple-touch-icon', 'icon'):
                self.assertEqual([a['href'] for t, a in tags if t == 'link' and a.get('rel') == rel], [icon_url])
            for css_class in ('icon', 'launch-service'):
                self.assertEqual([a['src'] for t, a in tags if t == 'img' and a.get('class') == css_class], [icon_url])
            self.assertFalse(any(a.get('class') == 'launch-slowth' for _, a in tags))
            self.assertIn(('meta', {'name': 'apple-mobile-web-app-capable', 'content': 'yes'}), tags)
            launch = next(a for tag, a in tags if tag == 'a' and a.get('id') == 'open')
            self.assertIn('hidden', launch)
            self.assertNotIn('href', launch)
            for tag, attrs in tags:
                for key in ('src', 'href'):
                    value = attrs.get(key, '')
                    if value and not value.startswith(('/', '?', 'slowth:')):
                        self.assertTrue((folder / urlsplit(value).path).exists(), value)

    def test_launch_behavior(self):
        result = subprocess.run(['node', '--test', str(ROOT / 'WebExt/tests/shortcuts.test.cjs')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
