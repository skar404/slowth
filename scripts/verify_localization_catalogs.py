#!/usr/bin/env python3
"""Offline checks for native catalogs. Localization/locales.json defines the agreed supported locales.

Run before building; verify_localization_bundles.py checks the compiled output.
"""
import collections
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATHS = ('Localization/Localizable.xcstrings', 'iOS/Interface.xcstrings',
                 'iOS/ApplicationNavigation.xcstrings', 'iOS/PauseActivity.xcstrings', 'iOS/ShieldNotifications/ShieldNotifications.xcstrings')
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(lld|llu|ld|lu|d|u|f|g|s|@)')
PLURAL_CATEGORIES = {'zero', 'one', 'two', 'few', 'many', 'other'}
FALLBACK_POLICY = json.loads((ROOT / 'Localization/english-fallbacks.json').read_text())


def fallback_locales(table, key):
    if key in FALLBACK_POLICY['tables'].get(table, []):
        return set(FALLBACK_POLICY['locales'])
    return set()


def verify_fallback_policy(catalogs, locales):
    allowed = FALLBACK_POLICY['locales']
    assert len(allowed) == len(set(allowed)), 'Duplicate fallback locales'
    assert set(allowed) <= locales - {'en', 'ru'}, 'Fallback must preserve English and Russian'
    for table, keys in FALLBACK_POLICY['tables'].items():
        assert table in catalogs, ('Unknown fallback table', table)
        assert len(keys) == len(set(keys)), ('Duplicate fallback keys', table)
        for key in keys:
            entry = catalogs[table]['strings'].get(key)
            assert entry is not None and entry.get('shouldTranslate') is not False, ('Unknown or untranslatable fallback key', table, key)
            # Missing compiled keys resolve to the source key. Only plain strings
            # whose English value equals that key may use this temporary policy.
            assert entry.get('localizations', {}).get('en') == {'stringUnit': {'state': 'translated', 'value': key}}, ('Fallback needs a plain English source key', table, key)


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
    expected = set(json.loads((ROOT / 'Localization/locales.json').read_text())['appLanguages'])
    actual = set().union(*(e.get('localizations', {}) for e in catalogs['Localizable']['strings'].values()))
    assert actual == expected, ('Localizable locale set', 'missing', expected - actual, 'extra', actual - expected)
    return expected


def verify_catalog(catalog, locales, name):
    assert catalog['sourceLanguage'] == 'en', name
    for key, entry in catalog['strings'].items():
        if entry.get('shouldTranslate') is False:
            continue
        translations = entry.get('localizations', {})
        missing = locales - translations.keys()
        assert missing <= fallback_locales(name, key) and not translations.keys() - locales, (name, key, 'missing', missing, 'extra', translations.keys() - locales)
        english_values = {u['value'] for _, u in units(translations['en'])}
        for locale, node in translations.items():
            # Substitution dictionaries require separate argument accounting; fail
            # explicitly rather than silently skipping a newly introduced schema.
            assert not node.get('substitutions'), (name, key, locale, 'unsupported substitution schema')
            values = list(units(node, f'{name}/{locale}/{key}'))
            assert values, (name, key, locale, 'no translations')
            for context, unit in values:
                assert unit.get('state') == 'translated', (context, 'untranslated state')
                assert unit.get('value', '').strip(), (context, 'empty translation')
                assert '\ufffd' not in unit['value'], (context, 'Unicode replacement character')
                assert arguments(unit['value']) == arguments(key), (context, 'format arguments', unit['value'])
                if locale not in {'en', 'pcm'} and not locale.startswith('en-'):
                    assert not (len(unit['value']) > 14 and unit['value'] in english_values
                                and re.search(r'[A-Za-z]{4}', unit['value'])), (context, 'unexpected English copy')
                if locale == 'pa':
                    assert not re.search(r'[\u0600-\u06ff]', unit['value']), (context, 'Punjabi requires Gurmukhi, not Arabic script')
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
    verify_fallback_policy(catalogs, locales)
    for name, catalog in catalogs.items():
        verify_catalog(catalog, locales, name)
        print(f'{name}: {len(catalog["strings"])} entries, {len(locales)} locales; values and format arguments verified')


if __name__ == '__main__':
    main()
