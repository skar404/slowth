Pause integration — 2026.10.3

The host and iOS extensions share a durable SQLite pause ledger in Debug and
Release. PauseProbe has been retired. macOS keeps its existing behavior; the
Safari pause adapter is applied only to the iOS extension bundle.

Policy
- Three starts per calendar day, duration 1/3/5 minutes (default 3).
- Preparing is free. Activation charges once; early completion does not refund.
  Only known failures before access was granted may compensate the charge.
- A fixed time zone, continuous clock and boot identity prevent clock rollback
  or reboot from extending a lease when a participating process next checks it.
- Strict mode can forbid pauses. It cannot be weakened while active, and pause
  duration cannot change while strict mode is active.
- Native pauses bind to exactly one configured application token. Switching
  restores the old target before clearing the new target; it retains the same
  deadline, monitor and charge. Revision checks reject stale mutations.
- Pauses started with recording active end when recording stops. Pauses started
  without recording do not subsequently require it. Existing records retain
  their original recording requirement.
- Preferences are never rewritten by a pause. Current enforcement is recomputed
  when it ends, including the existing soft YouTube navigation policy.
- Leaf rewards accrue for unused starts on completed days, including missed
  days. They cannot be spent. Migration does not award days before installation.
- SQLite transactions serialize processes. Ambiguous post-grant failures retain
  their charge. Existing durable state remains compatible with this release.

Presentation
- Live Activity is available on iOS 16.2+, interactive controls on iOS 17+.
  It displays a deadline and stale state; it does not drive enforcement.
- The host performs LiveActivityIntent mutations. The widget shares only the
  intent declaration, attributes and presentation, and has its own CI profile.
- Diagnostic quota/reward controls and simulator previews remain Debug-only.

Safari
- iOS-only bundle preparation is deterministic and runs in both configurations.
  Shared WebExt inputs and macOS bundles are not modified by the adapter.
- Activation requires a request from the selected site and a verified browser
  return alarm. A lost acknowledgement retains the alarm. Preferences are
  cached independently from the temporary lease.
- Preparation expires after 15 seconds. A non-Safari default browser cannot
  acknowledge it. Foreground refresh and visible-page expiry are extra checks.

Enforcement limits / physical acceptance still required
- DeviceActivity registers a 15-minute interval ending at the chosen deadline.
  Registration success does not prove callback delivery at that deadline.
- Suspended processes/pages, force-quit, reboot and missing/delayed callbacks
  can delay enforcement. There is no guaranteed background process.
- Activity dismissal is not an enforcement signal. Stale presentation must not
  claim protection has been restored. Simulator previews do not prove lifecycle.
- Test each native service and Safari site on a real iPhone, foreground, locked,
  background, reboot and force-quit; measure the actual unprotected duration.
- Test start/end/switch races, strict-mode and token changes, interruption during
  switching, storage failures, disabled Live Activities, and locked-screen intents.

Local verification (also included in CI)
swiftc -DPAUSE_TESTS iOS/Blocking/IOSPauseLedger.swift iOS/Blocking/BlockingDatabase.swift iOS/Blocking/BlockingRules.swift tests/IOSPauses/LedgerTests.swift -o /tmp/slowth-main-pause-tests
/tmp/slowth-main-pause-tests
node --test tests/IOSPauses/*.test.cjs WebExt/tests/*.test.cjs
python3 -m unittest discover -s tests -p 'test_*.py'

Ledger tests cover quota, idempotency, reservations, strict policy, deadlines,
clock/boot changes, compensation, SQLite rollback/concurrency, reward migration,
DST, cross-midnight refunds, persistence, and concurrent switching.
Safari tests use mocks; bundle tests verify ordering, repeatability and isolation.
Release builds and real-device checks must be reported separately.

Mandatory detection rest (independent of pause quota):
  swiftc -DPAUSE_TESTS iOS/Blocking/IOSPauseLedger.swift iOS/Blocking/BlockingDatabase.swift iOS/Blocking/BlockingRules.swift tests/IOSPauses/DetectionRestTests.swift -o /tmp/slowth-rest-tests
  /tmp/slowth-rest-tests

The rest record is optional in the existing SQLite ledger. Detection creates a
cycle whose continuous clock starts when the coordinator applies its Shield.
Host opening displays that same deadline. Calendar time is not an expiry source.
Legacy records without a start begin on Shield application or host opening.
After reboot, the next watchdog, Shield write or host opening restarts an
unfinished running minute. Completed records do not restart.
A committed cycle ID authorizes one release with a fixed five-second grace.
Pause revision changes invalidate old grants. Existing pauses retain their rules.

Debug UI preview: launch with --preview-rest (presentation only; no grant or
settings changes). Verify Russian and RTL layouts, iPhone/iPad and Dynamic Type.
Physical acceptance still requires real Screen Time authorization and ReplayKit:
- Detection -> Shield -> open Slowth immediately: about 60 seconds remain.
- Open after 40 seconds: about 20 seconds remain. Reopening, repeated detection
  and Shield writes never extend the deadline.
- Never open Slowth: the recorder watchdog completes the minute and grants five
  seconds with healthy active recording. A later opening shows no completed rest.
- Close/lock/force-quit Slowth, reopen: remaining time must be preserved.
- Before 60 seconds, no release; afterwards the rest disappears automatically.
  Active recording grants a fixed five-second grace; recording off keeps protection.
- Stop recording: the completed rest disappears without clearing protection.
- Process the same completed cycle twice: deadline must not extend.
- Return to blocked content after five seconds: a new cycle must be created.
- Reboot while waiting/counting; move calendar forward/back; change selection;
  test two services independently, existing pause, strict mode, stale cycle IDs.
Simulator previews and pure clock tests do not verify system Shield handoff.

Detection rest lasts 60 seconds in both Debug and Release builds.
Run DetectionRestTests.swift with both -DPAUSE_TESTS and -DPAUSE_TESTS -DDEBUG.

The recording extension checks rest completion on a serialized 250ms watchdog,
independently of video frame delivery. Pause/finish cancel it; resume starts it.
Host and extensions use the same boot-time identity even when only the host can
read kern.bootsessionuuid. Classifier votes during navigation grace are ignored.
Device verification must include a stationary Shield with no new video frames.

Starting/resuming recording grants five safe seconds immediately for enabled
recording-based apps and supersedes their old waiting rests. Pause-only apps
are excluded. Host reopen and repeated grant consumption do not extend it.
Continue on a released cycle clears any stale system Shield and returns .none,
without opening Slowth or extending grace. Continue on an unfinished cycle only
prioritizes its presentation. Only the detector creates a new cycle after release.
Debug builds publish token-free rest phase/clock/grant diagnostics under
App Group defaults debug.rest.host and debug.rest.broadcast.
Real-device regression: AuthorizationCenter can report no local authorization
inside Broadcast/ShieldAction even when the host is approved. Rest grants in
extensions therefore use the host-synchronized realtimeShieldEnabled state;
the host additionally checks its live authorization. Selection, active recording,
pause state and current cycle are still rechecked transactionally.

Rest presentation remembers the cycle and acknowledged shield request, not only
the cycle ID. Dismissal suppresses automatic reopening; another Continue request
reopens the same pending countdown. Requests received while visible are acknowledged
too. ShieldAction rechecks completion after requesting presentation before opening
the host, so a concurrently completed rest can return to the monitored app.

The pending rest now renders inline in its app card, replacing disclosure/settings
until completion. Explicit Continue requests select Apps and scroll to that card;
the rest sheet also opens. Dismissing it leaves the inline countdown visible. Verify repeated routing, countdown, automatic return
of settings, large text and RTL on device. --preview-rest is a simulator-only UI fixture.

Rest sheet uses the shared PausePanel with preferredTarget for direct app pause
activation. Normal startApplication gates, quota charging, monitoring and rollback
remain in effect. A valid active pause hides that target from openRests without
resetting its rest deadline; other targets remain visible. Device checks: start
from rest sheet, exhausted/strict rejection, failure feedback, and early pause end.

Blocking transition regressions (production coordinator, fake OS boundaries):
  bash scripts/test_ios_blocking.sh
This runs ledger, rest, pure rules and coordinator suites with and without DEBUG.
Start at iOS/Blocking/README.md for module ownership and rule changes.

The harness controls continuous/wall time, SQLite location, authorization and named
ManagedSettings stores. It executes real coordinator transactions, including pause
start/end, rest grants, failures, replacement, and watchdog reconciliation.

Enforcement order:
- Disabled/unconfigured services have no content-detection protection.
- A valid ordinary app pause temporarily overrides the target's protection.
- A classifier failure protects the current binding, even with a released rest.
- Pending detection rests retain Shield; applying Shield starts their 60-second clock.
- Completed rests grant five seconds only with recording active and no failure.
- Healthy recognition resumes after grace; pause observations are discarded.
- Recording stopped uses the existing at-rest policy, including soft YouTube.
- TikTok/Snapchat are recording-independent and open only during a valid pause.
- Safari keeps its independent iOS adapter, confirmed alarm and native lease.

Regression requirements:
- A detection suppressed by a pause never sets a recorder latch. Pause revisions
  reset evidence even if start/end occur between two watchdog polls.
- In-flight detections carry selection and revision; stale work is rejected.
- Continue can recover an obsolete released cycle after pause revision changes.
- Faults survive process restart and cannot be bypassed by Continue or old grace.
  Explicit ordinary pauses still work; their end restores fault protection.
- Replacing a binding removes the old token, lease, rest and fault. No new grace
  is granted. Existing duplicate selections remain stored but cannot pause;
  new selections reject collisions across all six services.
- No-frame watchdog ticks reconcile expired pauses while the recorder is running.
  They do not guarantee execution if iOS kills/suspends the recorder.

The 60-second rest still completes automatically. Starting/resuming recording
still supersedes pending rests with five safe seconds when the classifier works.
Physical acceptance remains required for actual Shield presentation and callbacks.

Expanded rest QA matrix:
- 128 independent combinations of recording, local authorization, extension
  context, classifier fault, changed binding, active pause and enabled target.
  Each case creates a real SQLite rest, applies Shield and checks completion and
  release permission after 60 seconds. Runs in both Debug and Release harnesses.
- Subsecond checks on either side of the 60-second rest and five-second grace;
  independently staggered YouTube/Instagram cycles and fresh detection after grace.
- Simulator UI fixtures accept --preview-rest-remaining 20 in Debug only.
  These cannot qualify Screen Time/ReplayKit; see Debug/README.md for setup.

QA run 2026-10-19:
- Blocking harness passed with and without DEBUG: 4096 pure-policy combinations,
  128 transactional runtime gate combinations, timing boundaries and regressions.
- 74 Python and 258 JavaScript tests passed. iOS Simulator Debug and Release
  builds passed; compiled localization checks passed for all seven bundles and
  46 locales. Release model/debug-symbol verification passed; the preview timer
  flag is absent from the Release host binary.
- iPhone Russian, iPad Arabic RTL, English dark and maximum accessibility text
  were inspected. Fixed the rest header splitting YouTube inside the word at
  maximum text size; accessibility sizes now place the title below the icons.
- Unsigned simulator builds showed a pause-storage error. Rebuilding with ad-hoc
  signing restored App Group access and the real quota display without a code fix.
- Physical Screen Time/ReplayKit, device lock/reboot/force-quit, VoiceOver and
  interactive pause/Shield handoff remain unverified. UI launch fixtures cover
  presentation only; no physical device settings were changed in this run.
