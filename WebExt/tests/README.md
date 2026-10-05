# Safari settings checks

Run the JavaScript regression suite (Node.js built-in test runner):

```sh
node --test WebExt/tests/*.test.cjs
```

Run native migration/storage checks on macOS, using an isolated, temporary
UserDefaults suite that is removed when the test exits:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc \
  Shared/AppLocalization.swift Shared/SharedStore.swift WebExt/tests/NativeSettingsTests.swift \
  -o /tmp/safari-native-tests
/tmp/safari-native-tests
```

Coverage includes legacy mode/boolean migration, fresh defaults, persistence,
Strict mode, supported features, independent Reels/feed combinations, whole-site
priority, live CSS/overlay removal, Stories, background redirects, cache upgrades,
native messaging failures, and localized popup switches.

YouTube tests cover the independent default-off feed switch, four-window-height
home threshold on desktop/mobile URLs, query parameters, live setting changes,
SPA/back/forward/restored visits, scroll lock cleanup, the home reset action,
Shorts independence, and whole-site priority.

Manual YouTube verification in Safari on iPhone and Mac: enable Infinite Feed
with Shorts both on and off; scroll `/` (also `/?app=desktop`) four window heights.
Verify the localized overlay prevents background scrolling and “Back to home”
opens `/` at the top. Search, subscriptions, channels and ordinary videos must
remain available. Navigate away and back, restore a scrolled tab, and change the
switch from both the host app and extension. Confirm disabling the switch removes
the overlay and restores scrolling, and Strict mode allows enabling but prevents
disabling the switch. A whole-site block takes precedence and preserves both
content choices. Physical Safari checks are separate from the Node fixtures.

Manual Safari verification: test Instagram and Facebook with each Reels/Infinite
Feed combination; open direct Reels links, scroll the home feed, and view Instagram
Stories. Infinite Feed retains the existing thresholds (including continuous
scrolling in chained/DM reels); the separate Reels flag controls hiding and URL
redirects. Verify disabling a whole-site block restores the previous choices.
Change a setting in the host app and allow up to 30 seconds for a visible tab to
refresh. Repeat in light/dark appearance and with Strict mode enabled.

Check macOS app language switching against the real compiled translations:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  scripts/test_app_localization.sh /path/to/Slowth.app
```

This uses a temporary application bundle and preference domain. It covers all
46 languages, switching without restarting, preference loading in a new process,
interpolation, right-to-left direction, and system/unsupported-language fallback.
