# Debug tools

Developer tools live here. Every implementation is guarded by `#if DEBUG`;
Release still compiles the source lists but contains none of these types.
Settings keys, archive formats, upload behavior and UI actions are unchanged.

- `Shared/`: capture settings, frame/session records, archives, deletion,
  upload identity/index/client and experimental model selection. These files
  have the same shared-target membership as before the move.
- `UI/`: review controls, compact settings panel (macOS and iOS compact UI),
  and host AppState debug actions. Only host apps compile these files.
- `iOS/`: native iOS settings panel, saved-leaf editor, Photos import,
  capture lifecycle and session upload UI/connection. Only the iOS host compiles
  these files. The capture modifier stays on the host root so background-tab
  selection does not change import or error handling.
- `Broadcast/`: pixel/frame and JPEG writers for the ReplayKit extension.

Production model identity, capabilities and the default Flat backend live in
`Shared/ModelSettings.swift`. Debug overrides use the existing
`debugRealtimeModelBackend` key. Release always uses `ModelSettings.defaultBackend`
and does not reference `DebugModelSettings`.

Small integration points remain with their owners: the hidden version-tap entry,
DebugMode's always-false Release gate, recorder capture calls, and transactional
reset/diagnostic hooks in settings and the blocking module. Keep these guarded;
do not copy production state or bypass its transaction APIs in a debug panel.

`project.yml` declares source membership. `scripts/release_tools/core.py` includes
this directory in public source snapshots so clean CI builds receive the tools.
After moving or adding files, run `xcodegen generate` and build both Debug and
Release. `scripts/verify_app_configuration.py` rejects debug UI, capture, upload,
model-override and reset symbols in the Release host/broadcast binaries.

Useful checks from the repository root:

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
bash scripts/test_ios_blocking.sh
python3 scripts/release.py check
python3 scripts/verify_app_configuration.py --app PATH_TO_APP --configuration Release
```

Also build macOS: its compact Debug panel shares code with iOS. Build success
checks compilation and resource boundaries; it does not verify Photos, StoreKit,
uploads or recording on a physical device.

## Xcode Canvas

Select the iOS Debug scheme (or macOS Debug for the compact panel), open a view
file and enable Editor > Canvas. Named `#Preview` entries are next to each view:

- `iOS/DebugIOSSection.swift`: ordinary settings and pending Photos frames.
- `UI/DebugCompactSection.swift`: compact/macOS settings.
- `iOS/DebugSessionCaptureControls.swift`, `DebugSavedLeavesControl.swift`,
  `UI/DebugAppReviewControls.swift`: individual control groups.
- `iOS/SessionUploadConnection.swift`: connection form and upload preparation,
  transfer, pending receipt and partial-error states. The progress content is a
  render-only view; it never constructs an uploader.

Production components also have previews: `iOS/IOSWelcomeView.swift`,
`iOS/PauseActivityCard.swift`, and `iOS/Views/` (feature cards, Safari help and
rest countdown). Welcome includes iPad, dark, large-text and RTL fixtures.

Debug action panels are read-only Canvas fixtures (`allowsHitTesting(false)`):
no Photos permission, Keychain mutation, uploads, quota resets or StoreKit calls.
Their AppState initializer installs no timer/observers and does not reconcile
protection. Welcome/help use no-op actions; rest takes an explicit remaining
value. Full ContentView, PausePanel, session browsing and purchase sheets still
have runtime services and are not instantiated by these previews. Preview the
extracted presentation components instead; runtime lifecycle stays in the host.

## Rest QA on the simulator

Debug simulator launch arguments: `--preview-rest --preview-rest-remaining 20`.
The optional remaining value is finite and clamped to 1...60 seconds. This only
sets the presentation clock; it does not seed the ledger, grant authorization,
change recording or unlock applications. Preview completion does not test the
production auto-dismiss path. Use the coordinator suite for lifecycle assertions.

Use a simulator build with signing enabled (ad-hoc `CODE_SIGN_IDENTITY=-` is
sufficient). `CODE_SIGNING_ALLOWED=NO` can leave App Group storage unavailable,
causing the pause panel to report a storage error instead of real quota state.
Language arguments (`-AppleLanguages '(ru)'`, `'(ar)'`) and simctl `ui` appearance
and content_size settings cover RTL, dark mode and accessibility text sizes.
