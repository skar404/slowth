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
