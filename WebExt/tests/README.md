# Safari settings checks

Run the JavaScript regression suite (Node.js built-in test runner):

```sh
node --test WebExt/tests/*.test.cjs
```

Run native migration/storage checks on macOS, using an isolated, temporary
UserDefaults suite that is removed when the test exits:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftc \
  Shared/AppLocalization.swift Shared/WebSettingsNotifications.swift \
  Shared/SharedStore.swift WebExt/tests/NativeSettingsTests.swift \
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

Instagram also has a separate, default-off **Stories** hard-block switch in the
native Safari settings and extension popup. It hides known Stories links and
returns `/stories/...` viewers to the Instagram home page, including direct links,
SPA routes and history navigation. It works with Reels and Infinite Feed off;
turning it off removes its CSS and routing block. The pre-existing Infinite Feed
Stories nudge is unchanged. Verify that profiles, posts, messages and Reels remain
available when only Stories is enabled. Whole-site blocking takes priority while
preserving the saved Stories choice; Strict mode permits enabling but not disabling
it. On iOS, temporary pause suspends Stories and restores it at the normal deadline.

Physical check on chalk (2026-11-22, local Release 2026.11.1/35): installed and
confirmed the separate Stories switch under Safari → Instagram through iPhone
Mirroring. It was enabled. In the embedded Instagram page, tapping a story was
followed by a reload of the home feed, without an observed story viewer. Story
circles remained visible: this page uses controls not covered by the known-link
selectors. A follow-up fix recognizes the mobile tray's horizontal scroller and
canvas-ring buttons, including single-child wrappers reserving its height. It
does not depend on Instagram's generated class names. Tested the rule on the live
page through Safari's remote inspector and Mirroring: the circles and reserved
space disappeared while posts remained visible. Temporary inspectability was
removed before installing the final signed Release build.
The user then checked the installed fix on chalk and confirmed it works.

`testStoriesTraySelectorsHideButtonsAndReservedSpaceWithoutHidingPosts` exercises
the bundled selectors in real WebKit against a sanitized version of that DOM:
zero through four wrappers, dynamically inserted trays, removal of the rule,
post avatars, a message scroller, and an unrelated canvas. This is not a full
physical Safari extension acceptance pass.

Check macOS app language switching against the real compiled translations:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  scripts/test_app_localization.sh /path/to/Slowth.app
```

This uses a temporary application bundle and preference domain. It covers all
46 languages, switching without restarting, preference loading in a new process,
interpolation, right-to-left direction, and system/unsupported-language fallback.

Popup site sections: open the extension on YouTube (including m.youtube.com),
Instagram, and the other supported sites. The current site's section should move to the top and
start expanded, preserving the order of the remaining sites; an unrelated or inaccessible tab leaves all sections collapsed.
Repeat on the extension's own whole-site blocked page. Each section can be opened
and closed manually with touch, mouse, or keyboard, including in Strict mode.
Changing switches must preserve the existing whole-site priority and Strict mode
rules. Verify the bundled icons in light/dark appearance, narrow widths, and RTL.

YouTube also has an independent, default-off **Hide home feed** switch in the
native settings and extension popup. Missing legacy values decode as false.
It hides Home navigation and replaces `/` (including query parameters) with
`/feed/subscriptions`. The logo also reaches subscriptions through that redirect.
Shorts, search, channels, library, watch recommendations and autoplay retain their
separate behavior. Live disabling restores Home navigation.
While home is hidden, the Infinite Feed overlay and scroll lock are removed;
its saved setting is preserved. Whole-site blocking and Strict mode retain their
existing priority, and an iOS pause temporarily suspends home hiding.

`testYouTubeHomeRedirectAndNavigationRestoreAcrossLiveSettings` loads the actual bundled
iOS content scripts (including pause policy) in WebKit over a local HTTP fixture.
It covers desktop/mobile Home controls, dynamically inserted navigation, query
strings, initial and logo redirects, search/watch/library/channel transitions,
real back navigation, live changes, and visible subscriptions/player recommendations. Node tests
add setting combinations, Shorts/whole-site priority and SPA/restoration events.
The native settings and shared-message tests cover migration, persistence,
serialization, independent switches and Strict mode.

Initial empty-home validation on 2026-11-22 (before the subscriptions change):
369 extension tests, 11 pause-policy tests, native settings
and shared-message tests, and all 13 simulator WebKit tests passed. Signed iOS
Release 2026.11.1 (35) built and installed on chalk without a version/build change.
On physical YouTube inside Slowth, observed a blank home with header/search/bottom
navigation preserved, working search results and subscriptions, Home/logo return,
and recommendations returning after disabling the switch in the shared settings.
Physical Safari on the same iPhone also passed: blank home, visible search results
and subscription feed, Home return, and immediate feed restoration/re-hiding
through the extension popup without reloading. The final saved setting was
restored to Hide home feed on, Shorts on, Infinite Feed off, whole-site off.
Desktop DOM coverage is automated WebKit fixture coverage; the installed macOS
extension and live desktop player/PiP behavior were not separately requalified.

Follow-up: Hide home feed now removes the Home navigation control and replaces
home visits with subscriptions, including logo clicks and history restores.
The replacement does not add a Home entry to history. Mobile Home controls with
`pivot-w2w` are covered as well as desktop guide entries. Other routes retain
visible navigation/content, and disabling the option restores Home controls.
The follow-up suite passed 370 extension tests and 15 WebKit tests, including
X policy-interruption and user-agent regression coverage. Release 2026.11.1 (35) was rebuilt
and installed on chalk; the temporary diagnostic Debug build was replaced.
Physical follow-up on the final Release: YouTube opened the subscription feed;
the Home control was absent (Subscriptions and You remained); tapping the YouTube
logo returned to subscriptions. X rendered its landing page and account-entry
form with Settings applied after the user-agent compatibility fix. No completed
X sign-in or authenticated-feed behavior is claimed.
