# iOS and iPadOS blocking

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
