"""Regression checks for gates: missing translations and corrupt compiled plurals."""
import copy
import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from verify_localization_catalogs import arguments, load_catalogs, supported_locales, verify_catalog
from verify_localization_bundles import verify_table


def unit(value):
    return {'stringUnit': {'state': 'translated', 'value': value}}


class LocalizationTests(unittest.TestCase):
    def test_all_shipping_catalogs(self):
        catalogs = load_catalogs()
        locales = supported_locales(catalogs)
        registry = json.loads((Path(__file__).resolve().parents[1] / 'Localization/locales.json').read_text())
        self.assertEqual(locales, set(registry['appLanguages']))
        for name, catalog in catalogs.items():
            verify_catalog(catalog, locales, name)

    def test_argument_reordering_but_not_type_changes(self):
        self.assertEqual(arguments('%@ %lld %%'), arguments('%2$lld %1$@ %%'))
        self.assertNotEqual(arguments('%lld'), arguments('%@'))
        self.assertNotEqual(arguments('%@ %@'), arguments('%1$@ %1$@'))

    def test_bad_translations_are_rejected(self):
        valid = {'sourceLanguage': 'en', 'strings': {'%lld left': {'localizations': {'en': unit('%lld left'), 'ru': unit('Осталось %lld')}}}}
        for replacement in [unit(''), unit('Осталось %@'), {'stringUnit': {'state': 'new', 'value': 'Осталось %lld'}}, {'variations': {'plural': {'one': unit('%lld')}}}]:
            bad = copy.deepcopy(valid)
            bad['strings']['%lld left']['localizations']['ru'] = replacement
            with self.assertRaises(AssertionError):
                verify_catalog(bad, {'en', 'ru'}, 'Interface')
        del valid['strings']['%lld left']['localizations']['ru']
        with self.assertRaises(AssertionError):
            verify_catalog(valid, {'en', 'ru'}, 'Interface')

    def test_compiled_plural_values_are_checked(self):
        catalog = {'sourceLanguage': 'en', 'strings': {'%lld minutes': {'localizations': {'en': {'variations': {'plural': {'one': unit('%lld minute'), 'other': unit('%lld minutes')}}}}}}}
        verify_catalog(catalog, {'en'}, 'Interface')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'en.lproj').mkdir()
            path = root / 'en.lproj/Interface.stringsdict'
            data = {'%lld minutes': {'NSStringLocalizedFormatKey': '%#@count@', 'count': {'NSStringFormatSpecTypeKey': 'NSStringPluralRuleType', 'NSStringFormatValueTypeKey': 'lld', 'one': '%lld minute', 'other': '%lld minutes'}}}
            path.write_bytes(plistlib.dumps(data))
            verify_table(root, 'Interface', catalog, {'en'})
            data['%lld minutes']['count']['other'] = 'wrong'
            path.write_bytes(plistlib.dumps(data))
            with self.assertRaises(AssertionError):
                verify_table(root, 'Interface', catalog, {'en'})

    def test_english_fallback_and_wrong_punjabi_script_are_rejected(self):
        key = 'Start screen recording'
        catalog = {'sourceLanguage': 'en', 'strings': {key: {'localizations': {
            'en': unit(key), 'pa': unit('ਸਕ੍ਰੀਨ ਰਿਕਾਰਡਿੰਗ ਸ਼ੁਰੂ ਕਰੋ')
        }}}}
        verify_catalog(catalog, {'en', 'pa'}, 'Interface')
        for value in [key, 'سکرین ریکارڈنگ شروع کرو']:
            catalog['strings'][key]['localizations']['pa'] = unit(value)
            with self.assertRaises(AssertionError):
                verify_catalog(catalog, {'en', 'pa'}, 'Interface')


if __name__ == '__main__':
    unittest.main()
