# Broadcast blocking (WIP, rolled back 2026-09-10)

Experimental feature: block YouTube Shorts specifically (not the whole
YouTube app) using ReplayKit screen recording + a pixel heuristic, since
Family Controls / ManagedSettings alone can only shield an app or activity
category as a whole — it has no API for "this app, but only this in-app
screen." Rolled back out of `project.yml` / the Xcode targets to keep the
shipped app on the stable MVP; this folder preserves the source and the
open questions so the feature can be resumed later without starting over.

## How it was supposed to work

1. User grants Family Controls (Screen Time) authorization and picks the
   YouTube app via `FamilyActivityPickerHost` (pre-existing file, see
   `iOS/FamilyActivityPickerHost.swift` — still in the repo, still excluded
   from the build, untouched by this rollback).
2. User taps a system broadcast-picker button (`BroadcastPickerView`,
   wraps `RPSystemBroadcastPickerView`) to start a screen-recording session
   backed by `UnscrollBroadcastIOS` (a Broadcast Upload Extension,
   `BroadcastIOS/SampleHandler.swift`). This shows the system's persistent
   red recording indicator — there is no silent/background mode, ReplayKit
   doesn't allow one.
3. `SampleHandler.processSampleBuffer` samples every ~15th video frame and
   runs `ShortsHeuristics.looksLikeShorts` on it: a cheap, non-ML pixel
   check (looks for YouTube's translucent vertical icon rail along the
   right edge, and rules out ordinary letterboxed landscape video). Needed
   to be cheap because broadcast upload extensions have a hard ~50MB memory
   ceiling that rules out Vision/CoreML/CIContext.
4. On a positive detection, `ManagedSettingsApplier.apply(selection:)`
   shields the whole YouTube app via a **named** `ManagedSettingsStore`
   (`"UnscrollShield"`) — named so the same store can be reached from the
   main app, the broadcast extension, and the shield action extension,
   which all run in different processes.
5. The system shows its Shield UI over YouTube, customized by
   `UnscrollShieldConfigIOS` (`ShieldConfigurationExtension` — title/icon/
   button labels only, no logic) with a primary "OK" button and a secondary
   "Remove block" button.
6. Tapping either button calls `UnscrollShieldActionIOS`
   (`ShieldActionExtension`). "OK" just closes the shield. "Remove block"
   additionally calls `ManagedSettingsApplier.clear()` and
   `SharedStore.setBroadcastBlockingEnabled(false)` (see race note below)
   before closing.
7. `broadcastFinished()` (session stopped) also clears the shield
   unconditionally.

## Files preserved in this folder

- `BroadcastIOS/` — `UnscrollBroadcastIOS` target (Broadcast Upload
  Extension): `SampleHandler.swift`, `ShortsHeuristics.swift`, Info.plist,
  entitlements. Also `BroadcastPickerView.swift`, which actually compiled
  into the **host app** target, not the extension (SwiftUI wrapper for the
  system picker button).
- `ShieldConfigIOS/` — `UnscrollShieldConfigIOS` target (Shield
  Configuration Extension, UI only, no App Group entitlement needed since
  it never touches `SharedStore`).
- `ShieldActionIOS/` — `UnscrollShieldActionIOS` target (Shield Action
  Extension, handles the shield's button taps).

Not moved (pre-existing, tracked, untouched by this work):
`iOS/FamilyActivityPickerHost.swift`, `iOS/FamilyControlsAuth.swift`,
`iOS/ManagedSettingsApplier.swift` — these already existed and were already
excluded from the `UnscrollIOS` build per `CLAUDE.md`; `ManagedSettingsApplier`
is what `BroadcastIOS`/`ShieldActionIOS` both linked against for their build
(`iOS/ManagedSettingsApplier.swift` re-added as a source under each of those
two targets in `project.yml` — see patch below).

## Removed from shared files (reverted, not deleted from history)

These fragments existed inline inside files that also carry unrelated,
**kept** work (the tip-jar feature) — so they were hand-reverted rather than
restored via git. Re-apply by hand if resuming.

### `project.yml`

- `UnscrollIOS` target: source entry `- path: BroadcastIOS` (with excludes
  for Info.plist/entitlements/SampleHandler.swift/ShortsHeuristics.swift —
  those two Swift files belong to the extension, not the host app).
- `UnscrollIOS` target: the `iOS` source entry's excludes list had
  `FamilyActivityPickerHost.swift`, `FamilyControlsAuth.swift`,
  `ManagedSettingsApplier.swift` **removed** (i.e. `ManagedSettingsApplier.swift`
  started compiling into the host app again, since `AppState.clearBroadcastShield()`
  called it directly).
- `UnscrollIOS.dependencies`: three more `embed: true` entries —
  `UnscrollBroadcastIOS`, `UnscrollShieldConfigIOS`, `UnscrollShieldActionIOS`.
- Three whole new target blocks: `UnscrollBroadcastIOS`, `UnscrollShieldConfigIOS`,
  `UnscrollShieldActionIOS` (app-extension, iOS 16+, bundle IDs
  `$(BUNDLE_ID_PREFIX).ios.Broadcast` / `.ios.ShieldConfig` / `.ios.ShieldAction`,
  `SKIP_INSTALL: YES`). Both `UnscrollBroadcastIOS` and `UnscrollShieldActionIOS`
  additionally source `iOS/ManagedSettingsApplier.swift` directly (buildPhase:
  sources) since they need it and aren't the host app.

Full removed target YAML is still visible in shell history / can be
reconstructed from this note; re-derive it from the pattern of the other two
extension targets (`UnscrollExtensionIOS`) if not.

### `Shared/SharedStore.swift`

Added then removed:
- `SharedState` fields: `broadcastBlockingEnabled: Bool`, `broadcastActive: Bool`,
  `lastShortsDetectionAt: Date?`, `lastShieldActionInvokedAt: Date?`
  (+ matching `defaultState` defaults, all false/nil).
- `SharedStoreKey` constants: `broadcastBlockingEnabled`, `broadcastActive`,
  `lastShortsDetectionAt`, `youtubeActivitySelectionData`, `lastShieldActionInvokedAt`.
- `snapshot()` reads for all of the above.
- Setters: `setBroadcastBlockingEnabled(_:)`, `setBroadcastActive(_:)`,
  `setLastShortsDetectionAt(_:)`, `setLastShieldActionInvokedAt(_:)`,
  `youtubeActivitySelectionData()` / `setYouTubeActivitySelectionData(_:)`.

(`supportCardDismissed` was added in the same diff hunk but belongs to the
tip-jar feature — kept, not reverted.)

### `Shared/AppState.swift`

Added then removed: `import FamilyControls` (nested under `#if os(iOS)`),
and a whole `#if os(iOS) && canImport(FamilyControls)` block:
`requestFamilyControlsAuthorization()`, `hasYouTubeSelection`,
`saveYouTubeSelection(_:)`, `setBroadcastBlockingEnabled(_:)`,
`clearBroadcastShield()`, `broadcastExtensionBundleID`.

### `Shared/ContentView_iOS.swift`

Added then removed: `import ReplayKit`, `import FamilyControls` (guarded),
the `@ObservedObject private var familyControlsAuthCenter = AuthorizationCenter.shared`
property (with its staleness comment), the `broadcastBlockingSection` call
in `body`, and the whole `broadcastBlockingSection` computed property +
`presentYouTubePicker()` helper (both under `#if canImport(FamilyControls)`).
`import StoreKit` and `import UIKit` stayed — both still used by the
kept tip-jar code (StoreKit types, `UIDevice` in `deviceInfo`).

### `iOS/Unscroll.entitlements`

Removed the added `com.apple.developer.family-controls` key (main app no
longer requests Family Controls authorization directly — only the three
WIP extensions did, and they're unbuilt now).

## Known bugs found while this was being debugged

1. **Reported symptom (unresolved): the shield's "Remove block" button did
   nothing.** Not root-caused before rollback. `ShieldActionExtension`'s
   logic read correctly on inspection (clears the named `ManagedSettingsStore`,
   flips `broadcastBlockingEnabled` off, responds `.close`), and a diagnostic
   was already wired for exactly this: `SharedStore.setLastShieldActionInvokedAt(Date())`
   fires at the top of `respond(to:)`, surfaced in the host app as the
   "Shield button last tapped" row (`ContentView_iOS.swift`). That row was
   never checked before the rollback decision — **first thing to check on
   resume**: if it never updates after tapping the button, the OS isn't
   invoking the extension at all (provisioning/registration/embedding
   problem, or — plausible given testing happened on an iPad Simulator per
   the screenshot files at repo root — `ShieldActionExtension` invocation is
   known to be unreliable specifically in the iOS Simulator; re-test on a
   physical device before debugging the Swift logic further). If it *does*
   update, the bug is in what happens after (state not actually clearing,
   or clearing but the system not dismissing the shield).

2. **Confirmed bug**: `AppState.clearBroadcastShield()` (the in-app "Clear
   shield now" button) only called `ManagedSettingsApplier.clear()` — it
   never set `broadcastBlockingEnabled = false`. If a broadcast session was
   still active, `SampleHandler` would just re-detect Shorts within a few
   seconds (still sampling frames) and re-apply the shield right back. Fix
   on resume: mirror `ShieldActionExtension`'s secondary-button handler —
   clear the store *and* disable `broadcastBlockingEnabled`.

## Resuming this work

1. `mv wip-broadcast-blocking/BroadcastIOS wip-broadcast-blocking/ShieldActionIOS wip-broadcast-blocking/ShieldConfigIOS .` back to repo root.
2. Re-apply the `project.yml` changes described above (three new targets,
   dependencies, `UnscrollIOS` source list changes), then `xcodegen generate`.
3. Re-apply the `SharedStore.swift` / `AppState.swift` / `ContentView_iOS.swift`
   fragments described above.
4. Re-add `com.apple.developer.family-controls` to `iOS/Unscroll.entitlements`.
5. Fix the two known bugs above before doing anything else — the in-app
   race is a quick fix; the shield-button-does-nothing report needs
   physical-device testing first.
