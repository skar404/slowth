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
swiftc -DPAUSE_TESTS iOS/Pause/IOSPauseLedger.swift tests/IOSPauses/LedgerTests.swift -o /tmp/slowth-main-pause-tests
/tmp/slowth-main-pause-tests
node --test tests/IOSPauses/*.test.cjs WebExt/tests/*.test.cjs
python3 -m unittest discover -s tests -p 'test_*.py'

Ledger tests cover quota, idempotency, reservations, strict policy, deadlines,
clock/boot changes, compensation, SQLite rollback/concurrency, reward migration,
DST, cross-midnight refunds, persistence, and concurrent switching.
Safari tests use mocks; bundle tests verify ordering, repeatability and isolation.
Release builds and real-device checks must be reported separately.
