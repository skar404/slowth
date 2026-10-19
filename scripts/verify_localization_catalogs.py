#!/usr/bin/env python3
"""Offline checks for native catalogs. The main catalog defines supported locales.

Run before building; verify_localization_bundles.py checks the compiled output.
"""
import collections
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATHS = ('Localization/Localizable.xcstrings', 'iOS/Interface.xcstrings', 'iOS/PauseActivity.xcstrings')
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(lld|llu|ld|lu|d|u|f|g|s|@)')
PLURAL_CATEGORIES = {'zero', 'one', 'two', 'few', 'many', 'other'}


def arguments(value):
    """Compare argument positions and types, permitting explicit reordering."""
    result = collections.Counter()
    position = 0
    for match in FORMAT.finditer(value.replace('%%', '')):
        position += 1
        result[(int(match[1] or position), match[2])] += 1
    return result


def units(node, context=''):
    if 'stringUnit' in node:
        yield context, node['stringUnit']
    for axis, variants in node.get('variations', {}).items():
        if axis == 'plural':
            assert 'other' in variants, f'{context}: plural needs other'
            assert set(variants) <= PLURAL_CATEGORIES, f'{context}: invalid plural categories'
        for name, child in variants.items():
            yield from units(child, f'{context}/{axis}/{name}')


def load_catalogs(root=ROOT):
    return {Path(p).stem: json.loads((root / p).read_text()) for p in CATALOG_PATHS}


def supported_locales(catalogs):
    return set().union(*(e.get('localizations', {}) for e in catalogs['Localizable']['strings'].values()))


def verify_catalog(catalog, locales, name):
    assert catalog['sourceLanguage'] == 'en', name
    for key, entry in catalog['strings'].items():
        if entry.get('shouldTranslate') is False:
            continue
        translations = entry.get('localizations', {})
        assert set(translations) == locales, (name, key, 'missing', locales - translations.keys(), 'extra', translations.keys() - locales)
        for locale, node in translations.items():
            # Substitution dictionaries require separate argument accounting; fail
            # explicitly rather than silently skipping a newly introduced schema.
            assert not node.get('substitutions'), (name, key, locale, 'unsupported substitution schema')
            values = list(units(node, f'{name}/{locale}/{key}'))
            assert values, (name, key, locale, 'no translations')
            for context, unit in values:
                assert unit.get('state') == 'translated', (context, 'untranslated state')
                assert unit.get('value', '').strip(), (context, 'empty translation')
                assert arguments(unit['value']) == arguments(key), (context, 'format arguments', unit['value'])
                if name != 'Localizable' and '\n' in key:
                    assert unit['value'].count('\n') == key.count('\n'), (context, 'line breaks')
                depth = 0
                for character in unit['value']:
                    if character in '\u2066\u2067\u2068':
                        depth += 1
                    elif character == '\u2069':
                        depth -= 1
                    assert depth >= 0, (context, 'unbalanced bidi isolation')
                assert depth == 0, (context, 'unbalanced bidi isolation')



def main():
    catalogs = load_catalogs()
    locales = supported_locales(catalogs)
    assert len(locales) == 46, f'Expected 46 locales, got {len(locales)}'
    for name, catalog in catalogs.items():
        verify_catalog(catalog, locales, name)
        print(f'{name}: {len(catalog["strings"])} entries, {len(locales)} locales; values and format arguments verified')


if __name__ == '__main__':
    main()
