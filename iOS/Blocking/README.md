# iOS and iPadOS blocking

## Grouped-app MVP (2026-11-02)

The new iOS UI offers one multi-app selection. Saving it opts into
`groupedApps.enabled.v1`; `GroupedApps` (in `Shared/PauseOnlyApps.swift`) stores
`groupedApps.selection.v1`. Select the list once after installing this MVP.
Legacy per-service selections are retained for rollback, but their stores and
rest bindings are retired when the group is saved. Safari is unchanged.

- One coordinator target, `apps`, owns the full token set, pause lease, progressive
  rest, inference-failure state and selection revision. A pause opens the whole
  group, including soft YouTube. No app chooser is shown when starting a pause.
- With no recording the group is blocked. With recording, the existing supported
  Shorts/Reels/Stories heads can trigger a rest for the entire group. Model coverage
  has not expanded: selecting an arbitrary app does not add a detector for it.
- The soft YouTube picker is requested when enabling soft mode. Its token is added
  to the group. The system stores split into `RealtimeShield.group` and
  `RealtimeShield.youtube`; only YouTube gets the stopped-recording soft deferral.
  Both stores obey the same ordinary pause and unfinished detection rest.
- Additional settings includes shared Short videos (YouTube Shorts, Instagram/
  Facebook Reels, X videos supported by the active model) and Stories (Instagram/
  Facebook) switches. Both default to on. Their values are frozen when recording
  starts/resumes. Editing requires stopped recording; strict mode prevents weakening.
  With both off, recording needs no classifier and creates no new detection rests;
  the coordinator still preserves pending rests, pauses, and at-rest protection.
- App exceptions are stored by opaque application token (`groupedApps.exceptions.v1`).
  Each app may allow short videos and/or Stories. They apply to detection events,
  not recording-off protection or classifier/storage failure. The coordinator
  persists the event's content families and blocked token subset with the full
  selection as its binding. A second family unions affected tokens into the same
  rest without restarting the clock. Empty subsets create no rest/progression.
  Ordinary pauses still open the entire group. Stopped-recording exception edits
  recompute an existing subset; strict mode prevents adding permissions.
- List and soft-binding edits require stopped recording and no strict lock.
  Categories/sites are rejected. Removing all apps clears protection for the group.
- Shield handoff always targets the group. Known service display names observed
  by Shield configuration are used only for navigation to known URL schemes;
  never for enforcement. Unknown apps require the app switcher. No identity picker.
- New UI copy has English/Russian translations; other locales fall back to English.
  The legacy implementation remains as fallback before the first group save.

Automated validation: `bash scripts/test_ios_blocking.sh` includes production
coordinator tests for multi-app pause/rest/grace/fault handling, soft YouTube
priority, replacement bindings and stale detection rejection, in Debug/Release.
A device build/install is not physical behavior qualification.

Device MVP checklist:

1. Stop recording; choose at least two apps. Confirm both are blocked.
2. Start a pause from either app: both open; ending/expiry restores both.
3. Start recording: ordinary content opens; supported Shorts/Reels/Stories closes
   the entire group. Confirm one shared rest, including when opening a second app.
4. Complete the rest; test navigation grace and a new detection. Stop recording:
   ordinary selected apps must block again.
5. Enable soft YouTube via its picker. Check podcasts/background playback, the
   existing foreground usage threshold, common pause, and common detection rest.
6. Replace/remove apps with recording stopped; old tokens must no longer be blocked.
   Check launch after force quit, device lock, recording interruption, and reboot.
7. Check Shield → Slowth → return for YouTube/Instagram, and app-switcher guidance
   for an arbitrary app. Verify Safari pauses still behave as before.

The sections below describe the retained legacy implementation where applicable.

Start with **BlockingRules.swift**. It contains the ordered policy, its input
`BlockingContext`, incoming `BlockingEvent`, and output `BlockingDecision`.
A decision names the Shield action, monitor action, deferred-access change,
observation reset and reason. The rules read no clocks, defaults, database or
Apple APIs. Durations are 60 seconds of rest, five seconds of navigation grace,
and one second of soft YouTube usage.

Read next:

1. `BlockingCoordinator.swift`: foreground/background, settings, recording-stop
   and usage callbacks. It loads current state, runs policy and performs effects.
2. `IOSPauseCoordinator.swift`: durable pause/rest orchestration. Its existing
   public name is retained for UI, Safari and extension callers. Transactions,
   binding checks and revision rechecks remain here.
3. `IOSPauseLedger.swift`: compatible Codable records, quota, rest clock
   arithmetic and recorder binding tracking. Presentation remains in `iOS/Pause`.
4. Adapters: `BlockingShield`, `BlockingActivityMonitor`, `BlockingPauseMonitor`,
   `BlockingClock`, `BlockingStorage`, `BlockingDatabase`, `BlockingSettings`.
   `ManagedSettingsApplier` translates legacy callers into coordinator requests.

The app and relevant iOS extensions compile these sources directly. There is no
framework, package, dependency, new settings format or migration. macOS does not
compile this directory; shared soft-mode settings delegate here only on iOS.
Safari retains its existing quota/prepare/acknowledge interface.

## Policy scenarios

| Situation | Result |
| --- | --- |
| Valid ordinary app pause | Clear its Shield, including a classifier fault |
| Active recording, classifier unavailable | Protect the current binding; rest cannot unlock |
| Bound unfinished detection rest | Keep Shield; applying Shield starts its clock |
| Completed rest with healthy active recording | Commit release, then clear with fixed five-second grace |
| Recording startup/resume | Commit fresh grace; faults still block |
| Expired pause, stale recorder intent | Restore protection |
| TikTok or Snapchat | Protect independently of recording; a valid pause can open |
| Soft YouTube, Slowth foreground | Open, cancel previous monitor |
| Soft YouTube, leaving Slowth | Arm a fresh one-second usage monitor |
| Monitor cannot start | Clear deferred permission and restore protection immediately |
| Old usage callback | Stop only its generation; do not change current protection |
| Recording starts while usage monitor waits | Reject callback under current recording state |
| Binding or pause revision changes | Reset detector observations, reject stale in-flight detections |
| No video frames | Serialized recorder watchdog reconciles pauses and rest |
| SQLite failure | Never authorize an unbounded clear |
| Strict disallows pauses | Reject new pauses and invalidate existing permission |

The policy entry point is not a replacement for transactional authorization.
Never directly call `BlockingShield` from UI, ReplayKit or a callback. Every
Shield write goes through that adapter inside the durable coordinator.
The historical store names `RealtimeShield.<target>`, SQLite location and
single-row encoding, settings keys, generations and revision binding are unchanged.
Persist a grant before clearing Shield; then recheck it in a separate transaction.
Soft callbacks also retain the foreground/generation check after writing Shield.

## Changing a rule

For example, changing the soft usage threshold means editing `softUsageSeconds`,
then updating the expectations below. Changing the priority of rest and classifier
failure means changing the ordered branches of `.shieldRequest` and `.pauseEnded`,
then adding the corresponding coordinator sequence. Do not implement exceptions
in a UI setter or detector frame loop.

Detector classification, vote windows and model selection remain in ReplayKit.
It submits recording/observation decisions and content detections to this module.
The ledger owns rest state transitions and fixed deadlines; UI displays them.

## Verification

From the repository root:

```sh
bash scripts/test_ios_blocking.sh
node --test tests/IOSPauses/*.test.cjs WebExt/tests/*.test.cjs
python3 -m unittest discover -s tests -p 'test_*.py'
xcodegen generate
```

The script runs ledger, rest, rules and production coordinator tests both with
and without `DEBUG`. Rules compare 4096 combinations against frozen pre-refactor
decisions. Coordinator tests execute real SQLite transactions with fake OS
boundaries, including stale callback/new foreground, recording during monitor
wait, registration failure, duplicate callback, Strict, storage failure,
selection replacement, pause-only apps and no-frame reconciliation.
Both CI workflows run this script.

Build iOS Debug/Release and macOS separately. Tests and simulator builds do not
qualify physical Shield, ReplayKit or DeviceActivity delivery. On a device check
foreground/background, screen lock, force-quit/relaunch, recording stop/resume,
a stationary Shield with no new frames, rest completion, and stale usage events.
See `tests/IOSPauses/README.txt` for the detailed physical acceptance cases.

Exception device checks:
- Choose two apps. Allow Stories for one, detect Stories, confirm only the other
  app receives Shield. Repeat with short videos and swap the exceptions.
- Allow both types for all apps: detections must not create a rest or increase
  the progressive rest count. Stopping recording should still protect the group.
- During an active rest, view a different forbidden content family in an exempt
  app. Its affected tokens join the existing rest without extending its deadline.
- Pause during a partial rest; end it both before and after the rest timer elapses.
  Exempt apps must not acquire a temporary Shield. Check soft YouTube separately.
