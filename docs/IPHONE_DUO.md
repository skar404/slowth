# iPhone Duo layout

`Shared/ContentView_iOS.swift` detects hinge capability using `onHingeChange`
above the layout branches. A temporary nil hinge update does not discard the
capability during a display transition. Device names and screen dimensions
are not used to identify Duo.

- On a hinge-equipped iPhone, regular windows at least **720 pt** wide with
  non-accessibility text show Apps and Safari together, regardless of aspect
  ratio. `ArrangementView` owns exactly one Apps pane and one Safari pane;
  the system can adapt the split to the fold. Each pane scrolls independently.
- The shared iPad components use Duo-specific **16 pt** outer margins and a
  **16 pt** horizontal pane gap. Feature cards sit above the headings: below
  900 pt they scroll horizontally as compact icon-and-text cards (88 pt minimum
  height at standard text); at 900 pt and
  above they share a single row.
- Outer-display, narrow, compact-size-class and accessibility-text windows
  use Apps / Safari / Settings tabs. Cards begin Apps. Recording and pauses
  stay inside Apps; Strict mode stays in Settings. There are no Duo-only
  recording or Strict toolbar actions.
- The Settings button uses a native `NavigationStack` toolbar with semantic
  `primaryAction` placement, so iOS positions it in the system side bar for
  supported Duo poses. The narrow layout retains the native Settings tab.
- Settings now uses the native **384 pt Inspector**, sliding in from the
  trailing edge at the user's request, replacing the floating dimmed overlay
  in the original plan. The system owns drawer sizing and presentation; it
  fills the available height. Close with the cross, Escape, or the toolbar
  toggle. Native inspector behavior determines whether it overlays or sits
  beside the content; there is no custom full-window dimmer on Duo.
  Narrowing converts open Settings to its tab; widening restores the inspector
  through the shared selected-section state. With the inspector open, the
  remaining content measures its own width: below 720 pt it shows a native
  Apps/Safari segmented control and one readable form, instead of squeezing
  two columns beside the inspector.
- Leading/trailing alignment mirrors the columns and panel for Arabic.
- AppState, purchases, selections, independent Apps/Safari disclosure state,
  authorization, and modal presentation handlers remain above branching.
  Layout changes may reset scroll offsets, but do not reset selections or
  disclosure state. System sheets retain their existing root presentation.

## Compatibility and scope

New symbols use `canImport(SwiftUI, _version: 8.0.85)` and iOS 27.1 runtime
checks. Older SDKs retain tabs; the deployment target remains iOS 16.
Ordinary iPhone and existing iPad layout parameters are preserved. No public
API, storage, macOS, marketing version, or build-number changes are part of
this adaptation.

## Validation, 2026-10-20

Debug iOS simulator build passed with Xcode 27.1 (27A9275). UI checks and raw
screenshots are recorded in `reports/duo-layout-20261020/`. These checks do not
qualify physical-device ReplayKit, Screen Time enforcement, Safari behavior,
or detection models on Duo. Formatted marketing-card export remains deferred.

Reference: [Apple: Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo),
particularly “Optimize bars for vertical presentation”.
