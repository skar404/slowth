# iOS and iPadOS localization

The supported set is the 46 BCP 47 identifiers already in
`Localization/Localizable.xcstrings`, including `ar-EG`, `pa-Arab`, `pt-BR`,
`pt-PT`, `yue`, `zh-Hans` and `zh-Hant` as separate entries.

## Catalog ownership

| Table | Entries | Bundles |
| --- | ---: | --- |
| Localizable | 216 | Host and all embedded extensions |
| Interface | 110 | iOS host and Shield Configuration extension |
| PauseActivity | 14 | iOS host and Live Activity extension |

The original eight Live Activity strings are supplemented by the intent title,
four parameter labels and a user-facing action error. These use an explicit
`PauseActivity` table, including `LocalizedStringResource` metadata. The error
leaves the underlying pause operation and resynchronization behavior intact.

The release UI audit covered `ContentView_iOS`, welcome, app summaries, pause
panels and dynamic status-card keys, Shield Configuration, Live Activity,
Family Activity selection, shared help sheets, errors, accessibility labels and
Safari setup. `Stories` in the app summaries previously selected the wrong
(default) table; it now uses `Interface`. Shorts/Reels and service names remain
product names. Debug-only screens and system-owned permission text are excluded.
The non-discoverable action intent's metadata is localized as well.

Safari instructions already have all 46 translations in the main table. The
197 WebExtension localization tests pass, so no shared web or macOS resources
were changed. No version, build counter, extension data format or public API
was changed by this work. Existing worktree changes were preserved.

## Translation provenance and review limits

Existing translations were retained, with small German terminology corrections
(App-Schutz, strenger Modus, Storys). Matching main-catalog translations were
reused. Missing translations were drafted using Google Translate; Nigerian
Pidgin was drafted separately. Product names and format arguments were protected.
There is no generated English fallback for missing languages.

Follow-up review corrected short labels that had been translated as verbs,
minute abbreviations misread as “minimum”, feed terminology (reusing the web
catalog’s social-media terms), heading grammar/line breaks, and
Apple feature names. Arabic, Japanese and German terminology was checked against
Apple's localized documentation, including
[Arabic Screen Time](https://support.apple.com/ar-eg/108806),
[Japanese screen recording](https://support.apple.com/ja-jp/102653) and
[German Screen Time](https://support.apple.com/de-de/guide/iphone/-iphbfa595995/ios).
Other locales reuse the existing catalog's Screen Time access label where
appropriate. This is not professional review by native speakers of 46 languages;
idiom, inflection and terminology still benefit from native-language review.

The variable minute label uses localized unit abbreviations (or invariant units).
The remaining-pause label is a numeric counter without an inflected pause noun.
The 1-, 3- and 5-minute action labels are separate complete translations.
Formatting uses the current locale, and RTL numeric placeholders are isolated.
No artificial plural branches were added where the wording needs none.

## Verification

- `python3 scripts/verify_localization_catalogs.py`: all three catalogs pass.
- `python3 -m unittest discover -s tests -p 'test_localization_catalogs.py'`:
  four tests pass, including missing/empty/untranslated values, argument type and
  position mismatches, invalid plural fallback and compiled `.stringsdict` values.
- `node --test WebExt/tests/localization.test.cjs`: 197 tests pass.
- Xcode 27.1 Debug builds succeed for generic iOS Simulator and signed iOS device.
- `verify_localization_bundles.py` passes for both builds: 46 locales in every
  required table in the host and all six extensions. Versions remain 2026.10.3
  (23) in the host and every extension. `git diff --check` passes.
- iOS 18.6 iPhone 16e and iPad Pro 11-inch simulators: 70 screenshots captured
  across English, Russian, German, Arabic and Japanese. Routes: welcome, apps,
  Safari, settings, Safari instructions, Live Activity **preview**, and welcome
  at the largest accessibility text size. Light/dark appearances are sampled;
  this is not an exhaustive cross-product of every screen, theme and text size.
- Visual review found a truncated Russian Live Activity action and narrow welcome
  text at accessibility sizes. Actions now allow two lines; welcome steps stack
  vertically at accessibility sizes. Affected screenshots were repeated.
- Debug was installed on the paired physical iPhone. Launch initially failed
  because it was locked, then succeeded after the user unlocked it.

Local build logs and screenshots are under `/tmp/slowth-l10n-work/` (temporary,
not checked in). Build outputs are under `/tmp/slowth-l10n-build-sim/` and
`/tmp/slowth-l10n-build-device/`.

## Remaining manual checks

Computer Use could not access Simulator and reported missing permissions for
iPhone Mirroring. Screenshots validate visible text and layout, not interaction,
VoiceOver speech/order or scrolling reachability. The unsigned simulator build
shows the localized unavailable-state message for App Group pause storage;
it does not validate real pause operations.

On the physical iPhone, check a protected app's system shield, transition back
into Slowth, and real Live Activity start/switch/end behavior. Preview rendering
and successful device installation/launch do not establish these results.
Also check VoiceOver, scrolling at maximum text sizes, and actual Safari
extension operation on the device. No recording, authorization or protection
settings were enabled automatically for these checks.

The system shield’s app-opening button uses the invariant product name `Slowth`
in all locales. The system controls its width and font; longer action labels
wrapped on the physical iPhone. The subtitle explains the action. The close action (including the older-iOS fallback) uses the compact localized
“Close” label. Its translations explicitly mean the closing action, not “nearby”.
