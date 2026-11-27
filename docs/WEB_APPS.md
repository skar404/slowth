# Web apps (Beta)

Slowth's iOS/iPadOS catalog opens Instagram, YouTube, TikTok, Facebook and X with
system WKWebView and the bundled Slowth WebExtension on iOS 18.4+. It remains
**Beta** until the signed Google/passkey and physical-device acceptance below
passes. The Apple request is prepared in [WEB_BROWSER_REQUEST.md](WEB_BROWSER_REQUEST.md),
not submitted. A successful build does not establish provider sign-in support.

## Profiles and page lifetime

`WebAppProfile` assigns fixed UUIDs to four persistent `WKWebsiteDataStore`s and
four `WKWebExtensionController.Configuration`s. Meta is shared by Instagram and
Facebook; YouTube, TikTok and X each have their own profile. Each profile owns one
extension context and its extension storage. `SharedStore` blocking settings stay
common to all profiles and Safari.

The old `.default()` website store and `slowth.web-apps.v1` extension storage are
left intact. Cookies are not copied from the old mixed store. A dismissible,
one-time catalog notice explains the new sign-in requirement and Meta sharing.

`WebAppProfileRuntime` retains a separate main session for each service. Closing
the browser screen suspends ordinary media and retains the page, history and login
windows in memory. YouTube's active PiP or full-screen presentation is exempt from
this suspension, including the full-screen-to-PiP transition. An asynchronous
presentation check is ignored if the screen has reopened or changed tabs meanwhile.
Reopening resumes that session. Cold launches restore only a successful
same-service HTTPS GET destination without credentials, port, query, fragment or
an authentication-related path. Other destinations fall back to the service home.
Forms, POST bodies and temporary windows are never serialized. Restoration stores
only the last eligible URL per service, not a global browsing history.

An explicit request from a native app's Shield closes the browser cover and waits
for dismissal before presenting recording, pause or an existing detection rest.
The target is retained throughout the transition; a rest's countdown is not
restarted. Website links can likewise dismiss these prompts before opening the
browser. Background rest polling alone does not interrupt browsing.

Clicked external links open a temporary window with the originating profile.
Google/Apple authentication destinations and links within a redirected login
provider retain their current browsing context, including sessionStorage.
WebKit-created windows keep the exact supplied configuration and real
`window.opener`; a window closed by the website returns to its opener.
The compact bar shows the current domain and protection state, alongside Close
and Blocking settings. Tapping the domain opens Copy link for the full current
HTTP(S) URL, including its path, query and fragment. Pulling down at the top of
the page reloads it, including pages shorter than the viewport. Refresh controls
belong to each web view and stop on completion, failure or a tab switch.
Settings reuse the existing site controls,
filtered to the service matching the visible URL. On unsupported sites, such as
external login providers, the settings button is disabled. The unified Web apps tab lists every site with Open, Add to Home Screen and
expandable blocking settings. Add to Home Screen opens the HTTPS setup page
directly in the external browser, without an intermediate instructions sheet;
the action uses a transition arrow. Safari extension setup has an Enable in Safari
help card at the top of Web apps. Rule updates stay below the catalog. iPad and Duo use the same catalog in their Web apps column.
There is no separate Safari tab or browser overflow menu.
Instagram's mobile bottom navigation uses equal-width slots for the visible
icons, including when Reels is hidden. This adjustment uses the bottom bar's
links and geometry, and leaves post actions and desktop sidebars unchanged.
Each site can be hidden through its expanded blocking settings. Hidden sites move
to a collapsed, neutral list below Rules, without service icons or launch
buttons; its restore action returns a site to the main list. The local visibility
preference survives app restarts and does not change blocking rules, sign-ins or
Home Screen shortcuts. Current-site browser settings remain available when hidden.
Website custom-scheme navigation is cancelled; there is no confirmation action
that launches another application (including social apps, mail and phone).
Clicked main-frame/new-window HTTP(S) GET links load explicitly in WKWebView
instead of allowing the original click to hand off a Universal Link. System link
context menus and previews are disabled in every tab, including replacement views.
Cross-host main-frame GET navigations initiated by scripts or redirects also
reload through the public WKWebView load API in the existing window. A per-tab
one-shot marker prevents replaying that native load recursively. POST requests
are not replayed. The browser bar has no copy/share or "Open in browser" actions.
Forms and script-created
OAuth popups retain WebKit's normal browsing context. Physical-device coverage of
provider-specific script redirects and installed-app Universal Links is still
required; simulator tests do not establish that coverage.
Certificate validation uses WebKit's default handling.

Settings → Web apps → Clear all website data asks for confirmation, then closes
all profile sessions, cancels downloads, removes unexported temporary files,
website data and extension storage, and forgets saved URLs. It also clears the
legacy shared store used before profile separation. System Screen Time history
is explicitly excluded from website-data removal: it is not a login/cache and
its deletion requires registered-browser access on newer WebKit versions.
New browser starts wait until
cleanup completes. Exported Files documents and SharedStore rules are unaffected. The internal
reset-permissions operation recreates
profile pages so websites ask again; OS grants are managed in Settings.

## Website capabilities

File/photo inputs use WKWebView's system picker; no custom full-library access is
added. Camera/microphone requests use `.prompt` for a visible HTTPS page, allowing
WebKit to name the requesting origin; hidden or insecure pages are denied. Both
usage descriptions are present in Debug and Release. Release retains no Debug
full-photo-library privacy keys.

`WKDownload` handles download actions and unsupported response types. The download
screen code remains available internally, but the compact bar no longer exposes
its progress, cancellation, Files export or PDF preview. Server filenames are confined to a random temporary
directory and cannot overwrite an existing download. Inline playback and PiP are
enabled in ordinary website configurations; actual support depends on the site.
Both iOS host configurations declare the audio background mode. Opening YouTube
configures the audio session for movie playback without eagerly activating it.
This permits system PiP/background playback; it does not force PiP to reopen after
the user closes it, override interruptions, or retain a video that YouTube replaces
on navigation. Calls, push notifications and guaranteed background playback are
outside this release.

PiP follow-up (2026-11-22): the hosted WebKit regression uses generated local audio
to check actual playing/suspended states while simulating the video's presentation
mode. PiP/full-screen exemptions, inline suspension and reopening during a pending
check passed. The other 11 browser tests passed in the preceding run. Signed Release
2026.11.1 (35), with `UIBackgroundModes = [audio]`, passed bundle verification and
was installed on chalk (installation sequence 2972). Real YouTube PiP persistence
is not yet verified: iPhone Mirroring could not connect while the phone was in use.

WebAuthn is handled by system WebKit. The compact bar does not expose a request
for system browser credential access. No user-agent spoofing, injected WebAuthn
implementation or third-party Associated Domains are used.

## Protection protocol and recovery

The profile loads the embedded extension (including the existing iOS pause
adapter), grants its declared permissions, and waits for a native `getState` round
trip plus a native message port before opening a website. Safari receives no
embedded-host flag and retains its previous refresh mechanism.

SharedStore writes and in-process pause changes notify the profiles immediately.
The profile sends a fresh revision challenge through `WKWebExtension.MessagePort`.
The background re-reads native state, applies it through the content script on
every supported open page, and returns matching acknowledgements. All-disabled
settings are a successful application. Login-provider pages and the internal block
page have no supported-site script and are excluded from that acknowledgement set.
This proves the settings path is active, not that a site's changing markup is
scientifically or manually qualified for every rule.

The UI distinguishes starting, working, recovering and failed protection. Visible
sessions check every three seconds and on foreground/navigation; a missing reply
for twelve seconds, port failure or unloaded extension produces an error overlay
instead of a success indicator. Revision checks ignore stale replies. Reconnection
is automatic; explicit recovery unloads/reloads the profile extension and recreates
pages from safe saved destinations. WebContent termination reloads only an eligible
GET URL or home, never a form or unfinished authentication request.

## Shortcuts and publication

- `slowth://web/<service>` keeps the existing strict five-service contract.
- `https://slowth.app/shortcuts/<service>/` remains the installation page, with
  individual manifest identity, scope, icon and `?launch=1` start URL.
- Safari tabs always show installation instructions, including `?launch=1`, without
  a link that opens Slowth. Standalone Home Screen launches make one automatic
  launch attempt per foreground visit, starting from inline HTML before fetching
  styles, icons or the UI script. Visibility and page lifecycle events rearm the
  redirect when the saved window returns, including back-forward cache restores;
  duplicate events within the same visit do not repeat the attempt. The page says
  “Opening [service]…” with “in Slowth” below it. The transit screen has no card or manual button.
  `?setup=1` shows help without automatic launches.
- Shortcut pages live in `website/shortcuts/`, use the site's 64 locale catalogs
  (including RTL and regional language matching), and are included by
  `.github/workflows/website.yml`. No new backend or hosting account is needed.

Publication is a separate action. After authorized deployment, check all five
production pages, their manifests/icons, and Home Screen installation plus repeat
launch on physical iPhone and iPad. Local shortcut tests are not that evidence.

## Repeatable checks

```sh
node --test WebExt/tests/*.test.cjs
python3 -m unittest discover -s tests -p 'test_*.py'
bash scripts/test_ios_blocking.sh
bash scripts/test_ios_welcome.sh
bash scripts/test_web_apps.sh --simulator auto
python3 scripts/render_slowth.py --check
python3 scripts/check_slowth.py --app-locales Localization/locales.json
```

The browser test script reports contract compilation, app/test compilation,
simulator boot and hosted test execution separately. It waits for `simctl
bootstatus` before launching the test host, with a 180-second boot limit; individual
tests retain their 120-second limit. With `auto`, it creates a dedicated simulator
and deletes it on exit; it never reuses or erases an existing device. Pass a
simulator UDID instead of `auto` to compare runs on the same runtime.
The test scheme passes `--web-app-tests` to a Debug-only simulator host with a
real key window but no production onboarding, Screen Time or recording-state
poller. Tests still load the real browser runtime and bundled WebExtension. Xcode results remain in
`build/webapps-tests/Logs/Test/`; source-check CI retains them for seven days,
including failed runs. A passing local run does not establish CI startup latency.

The hosted XCTest suite exercises actual WebKit cookie isolation, Meta sharing,
retained sessions, nested-window return, a real JavaScript opener, startup with the
bundled extension/native port, extension unload/recovery, HTTP downloads and cancel.
Node tests cover native freshness, successful/failed content acknowledgements,
disconnection and Safari compatibility. Foundation tests cover routing, shared
Strict mode policy and conservative URL restoration.

Debug simulator launch `--preview-web-apps` selects the catalog;
`--preview-web-app-service youtube` renders the real browser screen directly for
visual checks. Neither preview switch is compiled into Release.

## Physical acceptance still required

Record each row separately for **all five services on iPhone and iPad**:

| Scenario | Required evidence |
|---|---|
| Sign-in | Password/AutoFill, second factor, cancel and retry; Google/passkey inside Slowth |
| Session | Close/reopen, kill/relaunch, profile logout; Meta shared and others isolated |
| Windows | OAuth opener/return, external link, back/forward, tel/mail/custom-app cancellation, installed-app Universal Links |
| Files | Photo/file upload, download, cancel, Files export, PDF preview |
| Permissions | Correct domain, camera/mic approval and denial, reset, usable page after denial |
| Media | Full-screen video, rotation, audio and supported PiP |
| Protection | Each selected rule, all rules off, Strict mode, live settings and pause expiry |
| Recovery | Background/resume, killed WebContent, native port failure and retry |
| UI | VoiceOver, large text, light/dark, portrait/landscape, iPad window sizes |
| Shortcuts | Published setup page, install, cold/warm and repeated Home Screen launch |

Keep Beta if Apple approval, provider policy or any required physical acceptance
blocks the release. A simulator pass, signed build or installation does not replace
those checks. Version/build are unchanged for this local implementation.

## Local evidence — 2026-11-22 implementation

- Second navigation follow-up: all 10 hosted WebKit tests passed with an added
  cross-host JavaScript navigation and HTTP 302 return, preserving sessionStorage
  in the original window. Foundation contracts passed. This closes the tested
  script/redirect path without replaying POST requests. The owner will verify the
  actual Instagram "Open Instagram" button: Mirroring showed the page, but remote
  touches could not be established reliably and the phone returned to "in use".
  No successful physical button-blocking result is claimed from that observation.
  The signed Release with this follow-up passed signature/resource verification
  and was installed on chalk (installation database sequence 2932); version/build
  remains 2026.11.1 (35). The owner is performing the physical button check.
- Follow-up navigation hardening: custom-scheme app launches and the system link
  menu are disabled; clicked web GET links are loaded inside the originating
  profile. All 10 hosted WebKit tests passed, including same-window/new-window
  clicks, native-scheme cancellation and the existing real popup-opener test.
  Foundation contracts also passed. The signed Release was rebuilt, its signature
  and resources verified, and installed on chalk as 2026.11.1 (35).
  Installed-app Universal Link/device acceptance remains pending: iPhone Mirroring
  reported that the phone was in use. Logs: `build/webapps-validation/slowth-webapps-no-handoff.log`
  and `build/webapps-validation/slowth-webapps-no-handoff-release.log`.
- Foundation route/profile/restoration/native-message contracts passed.
- 360 shared WebExtension tests and the iOS-adapted extension suite passed.
- 125 Python tests passed, including the candidate configuration and shortcuts.
- 9 hosted WebKit tests passed on iPhone simulator, including a recovery request
  during an unfinished extension startup.
- Blocking/pause/Strict mode and welcome/admission checks passed in Debug and Release.
  The welcome source-wiring assertion was updated to the existing RecordingHealthStore
  start/stop calls, replacing obsolete SharedStore.setBroadcastActive references.
- The browser chrome and live YouTube page were visually inspected on iPhone and
  iPad simulators, with the actual domain and a successful settings acknowledgement.
- Signed local Release built; signature/resource checks passed. Host and all six
  extensions remain 2026.11.1 (35). Camera/microphone descriptions are included;
  browser-preview code and Debug photo-library descriptions are absent from Release.
- The Beta Release was installed on chalk. Its signature has no managed browser
  entitlement. The owner supplied a Google “Something went wrong / We weren’t able to sign
  you in” screen immediately after account selection. This is not the explicit
  “unsafe browser” / disallowed_useragent screen. The owner then confirmed that the error occurs when Google requests a passkey.
  The signed app and its provisioning profile both lack the browser entitlement.
  WebKit requires an entitled browser or an authorized associated domain for
  passkeys; Google is not an associated domain of Slowth. Password-only login
  remains unverified. A navigation edge case that could split account-selection links
  into a new window was corrected, but that has not yet established the cause
  or a successful physical sign-in. This remains an open acceptance blocker.
- No physical iPad, authenticated five-service/media/permission matrix, VoiceOver,
  published-shortcut Home Screen acceptance, or Google/passkey pass is claimed.
- No Apple entitlement request, website publication, commit, push or App Store
  Connect upload was performed.

New browser checks are wired into source-check CI via `scripts/test_web_apps.sh
--simulator auto`; a hosted CI run has not been triggered in this session.

### X navigation failure (2026-11-22)

On chalk, a bare WKWebView user agent made X return an HTTP redirect to
`x-safari-https://redirect.x.com/`. Slowth correctly refused the native scheme,
but reported `WebKitErrorDomain` 102 as a connection failure. Ignoring the policy
interruption alone removed the error panel but left a blank page.

The X browser configuration now adds `Safari/604.1 Slowth` through
`applicationNameForUserAgent`, preserving WebKit's device/OS identity and leaving
other services unchanged. HTTP comparison returned 302 with the bare user agent
and 200 with the compatibility suffix. Custom schemes remain blocked; nothing
is handed to Safari. X starts at its canonical `https://x.com/` address.
`navigationFailed` also ignores the exact WebKit policy-interruption domain/code
and URL cancellation while retaining genuine network errors.

All 15 simulator WebKit tests passed, including actual WebKit user-agent coverage
and policy-interruption versus offline-error coverage. The final signed Release
2026.11.1 (35) was installed on chalk, replacing the temporary Debug diagnostics.
Physical verification: X's landing page rendered, Sign in opened the account-entry
form inside Slowth, and protection reported Settings applied. Authenticated feeds
and sign-in completion were not tested. Temporary inspection and detailed
navigation logging were removed before the final Release build.
