#!/usr/bin/env python3
"""Verify compiled native tables (including plurals) in hosts and their consumers.

Usage: python3 scripts/verify_localization_bundles.py /path/to/Unscroll.app
"""
import argparse
import json
import plistlib
from pathlib import Path

from verify_localization_catalogs import ROOT, arguments, load_catalogs, supported_locales, verify_catalog


def read_plist(path):
    data = path.read_bytes()
    if data.startswith((b'\xff\xfe', b'\xfe\xff')):
        data = data.decode('utf-16').encode('utf-8')
    return plistlib.loads(data)


def verify_table(resources, table, catalog, locales):
    keys = {k for k, v in catalog['strings'].items() if v.get('shouldTranslate') is not False}
    actual = {p.stem for p in resources.glob('*.lproj') if any((p / f'{table}.{ext}').exists() for ext in ('strings', 'stringsdict'))}
    assert actual == locales, (resources, table, 'locale mismatch', locales - actual, actual - locales)
    for locale in sorted(locales):
        folder = resources / f'{locale}.lproj'
        strings_path = folder / f'{table}.strings'
        plural_path = folder / f'{table}.stringsdict'
        strings = read_plist(strings_path) if strings_path.exists() else {}
        plurals = read_plist(plural_path) if plural_path.exists() else {}
        assert keys <= strings.keys() | plurals.keys(), (resources, table, locale, keys - (strings.keys() | plurals.keys()))
        for key in keys:
            expected = catalog['strings'][key]['localizations'][locale]
            context = (resources, table, locale, key)
            if 'stringUnit' in expected:
                assert strings.get(key) == expected['stringUnit']['value'], context
            else:
                variants = expected.get('variations', {}).get('plural')
                assert variants, (*context, 'unsupported compiled variation schema')
                compiled = plurals.get(key, {})
                assert 'NSStringLocalizedFormatKey' in compiled, context
                rules = [v for v in compiled.values() if isinstance(v, dict) and v.get('NSStringFormatSpecTypeKey') == 'NSStringPluralRuleType']
                assert len(rules) == 1, context
                types = {kind for _, kind in arguments(key)}
                assert len(types) == 1 and rules[0].get('NSStringFormatValueTypeKey') in types, context
                for category, value in variants.items():
                    assert rules[0].get(category) == value['stringUnit']['value'], (*context, category)
                assert 'other' in rules[0], context


def verify_app(app, catalogs, locales):
    assert app.is_dir(), app
    bundles = [app, *app.rglob('*.appex')]
    is_mac = (app / 'Contents').is_dir()
    assert len(bundles) == (2 if is_mac else 7), (app, len(bundles))
    web_locales = {p.name for p in (ROOT / 'WebExt/_locales').iterdir() if (p / 'messages.json').exists()}
    for bundle in bundles:
        resources = bundle / 'Contents/Resources' if is_mac else bundle
        info = read_plist(bundle / ('Contents/Info.plist' if is_mac else 'Info.plist'))
        identifier = info['CFBundleIdentifier']
        tables = ['Localizable']
        if not is_mac:
            if bundle == app or identifier.endswith('.ShieldConfig'):
                tables.append('Interface')
            if bundle == app or identifier.endswith('.PauseActivity'):
                tables.append('PauseActivity')
            if bundle == app or identifier.endswith(('.ShieldConfig', '.ShieldAction')):
                tables.append('ShieldNotifications')
        for table in tables:
            verify_table(resources, table, catalogs[table], locales)
        if (resources / 'manifest.json').exists():
            assert json.loads((resources / 'manifest.json').read_text())['default_locale'] == 'en'
            assert {p.name for p in (resources / '_locales').iterdir()} == web_locales
            for locale in web_locales:
                assert (resources / '_locales' / locale / 'messages.json').read_bytes() == (ROOT / 'WebExt/_locales' / locale / 'messages.json').read_bytes(), (bundle, locale)
        print(f'{bundle.name}: {len(locales)} locales verified in {", ".join(tables)}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apps', nargs='+', type=Path)
    args = parser.parse_args()
    catalogs = load_catalogs()
    locales = supported_locales(catalogs)
    for name, catalog in catalogs.items():
        verify_catalog(catalog, locales, name)
    for app in args.apps:
        verify_app(app, catalogs, locales)


if __name__ == '__main__':
    main()
