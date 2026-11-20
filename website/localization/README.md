# Static translations

This catalog covers the 64 app language/region variants in `Localization/locales.json` as checked on 17 November 2026. Three page types are generated for each variant.

- `source.json`: stable message IDs, English copy and HTML/plain-text format.
- `messages/*.json`: complete editable translations. No runtime fallback to English.
- `templates/` and `schema.json`: shared page structure and structured data.
- `locales.json`: language names and text direction used by navigation.
- `terminology.json`: reference labels from the app localization catalog.
- `translation-source.json`: clearer English paraphrases used during translation preparation; the English website retains its original copy.

Initial new translations used Google Translate for public website text, followed by editorial corrections and structural checks. Russian received an extensive editorial pass; Nigerian Pidgin was authored separately. Headlines were revised across locales. This is machine-assisted localization, not certified translation or native-speaker review in every language. The existing seven privacy translations continue to come from `../privacy-content.json` without changes to their policy paragraphs.

From the repository root, run `python3 scripts/render_slowth.py` after editing copy or shared CSS, then `python3 scripts/render_slowth.py --check` and `python3 scripts/check_slowth.py`. CSS URLs include a content hash, so visitors receive the current layout after publication. Do not edit generated HTML directly. Keep the source/message key sets synchronized when adding content.

All translation is done during preparation. Visitors do not contact a translation service, and changing language sets no cookie or local storage. Original screenshots and the App Store badge remain in English; alternative text and the screenshot-language note are localized.
