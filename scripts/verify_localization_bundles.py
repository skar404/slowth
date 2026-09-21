#!/usr/bin/env python3
"""Verify the compiled app AND every embedded extension have the full catalog.

Usage: python3 scripts/verify_localization_bundles.py /path/to/Slowth.app /path/to/Unscroll.app
"""
import json
import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
catalog = json.loads((ROOT / 'Localization/Localizable.xcstrings').read_text())
keys = {key for key, entry in catalog['strings'].items() if entry.get('shouldTranslate') is not False}
locales = set(catalog['strings'][next(iter(keys))]['localizations'])
web_locales = {p.name for p in (ROOT / 'WebExt/_locales').iterdir() if (p / 'messages.json').exists()}

for argument in sys.argv[1:]:
    app = Path(argument)
    assert app.is_dir(), app
    bundles = [app, *app.rglob('*.appex')]
    expected_count = 2 if (app / 'Contents').is_dir() else 6
    assert len(bundles) == expected_count, (app, len(bundles))
    for bundle in bundles:
        resources = bundle / 'Contents/Resources' if (bundle / 'Contents').is_dir() else bundle
        actual = {p.stem for p in resources.glob('*.lproj') if (p / 'Localizable.strings').exists()}
        assert actual == locales, (bundle, locales - actual, actual - locales)
        for locale in locales:
            data = (resources / f'{locale}.lproj/Localizable.strings').read_bytes()
            # Xcode may emit UTF-16 XML with a UTF-8 declaration.
            if data.startswith((b'\xff\xfe', b'\xfe\xff')):
                data = data.decode('utf-16').encode('utf-8')
            strings = plistlib.loads(data)
            assert keys <= strings.keys(), (bundle, locale, keys - strings.keys())
            for key in keys:
                assert strings[key] == catalog['strings'][key]['localizations'][locale]['stringUnit']['value'], (bundle, locale, key)
        if (resources / 'manifest.json').exists():
            assert json.loads((resources / 'manifest.json').read_text())['default_locale'] == 'en'
            assert {p.name for p in (resources / '_locales').iterdir()} == web_locales
            for locale in web_locales:
                assert (resources / '_locales' / locale / 'messages.json').read_bytes() == (ROOT / 'WebExt/_locales' / locale / 'messages.json').read_bytes(), (bundle, locale)
        print(f'{bundle.name}: {len(locales)} native locales verified' + (' + all WebExtension dictionaries' if (resources / 'manifest.json').exists() else ''))
