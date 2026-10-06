# iPhone Duo layout

The iOS settings screen uses the current window size and size class. It does
not identify a device by name or cache a screen size at launch.

- On iPhone with iOS 27.1, regular-width windows at least 720 points wide and wider than
  tall use SwiftUI's `ArrangementView`: app controls on the leading side and
  Safari controls on the trailing side, with quiet headings on the shared background.
  Only individual settings sections have cards; columns have no outer card,
  border, or rounded clipping. Each Safari site has its own section/card.
  The system can split along either axis to accommodate the fold.
- Narrow/tall windows and accessibility Dynamic Type sizes use the full,
  scrollable settings form. Each section belongs to exactly one pane in wide
  mode. Do not use `splitArrangementAxis` to decide whether to duplicate a
  section: that environment value describes an axis, not pane visibility.
- `AppState`, purchase state, selections, and presentation flags remain above
  the layout branches. Resizing does not recreate these objects. Scroll
  positions can reset when switching between one and two forms.
- On iOS 27.1, sheets use the system presentation instead of forcing compact
  detents. The recording prompt scrolls and has a readable maximum width.
- Hero card widths scale with Dynamic Type.
- On a hinge-equipped iPhone (Duo), the system toolbar contains Strict,
  and the native ReplayKit start/stop button. Send feedback is omitted on Duo
  at the user's request. SwiftUI places
  these actions in Duo's vertical bar and handles overflow and safe areas.
  `onHingeChange` detects the capability, including the closed device; window
  width alone never enables the Duo-only actions on an iPad or ordinary iPhone.
  The Strict hero card, Strict form toggle, and feedback form row are omitted
  only when these toolbar actions are available. Strict still requires the
  existing confirmation and remains disabled for an active 24-hour lock.
  Recording still requires the system ReplayKit confirmation. The toolbar
  does not enable restrictions or start a broadcast automatically.

## Build requirements

Build with **Xcode 27.1 / iOS 27.1 SDK or later** to include the arrangement.
The SDK guard is `canImport(SwiftUI, _version: 8.0.85)`, paired with an iOS
27.1 runtime availability check. Xcode 27.0 has the same Swift compiler version
as Xcode 27.1 but lacks `ArrangementView`; a compiler-version guard is not
sufficient. Older SDKs retain the single-form fallback and the iOS 16 minimum.

The release workflow selects Xcode 27.1 on the `xcode-27` runner to include
the Duo APIs. Older SDK builds still use the fallback layout.

## Validation, 2026-10-06

- Duo action bar: Debug 27.1 and SDK-fallback Release 27.0 builds passed.
  Inspected the system vertical bar on the inner display. An isolated Duo UI
  test passed for Strict and ReplayKit button accessibility, absence of the
  feedback toolbar button, and opening/cancelling Strict confirmation without
  activating the lock. Actual recording was not started by this test.
- Debug simulator build with Xcode 27.1: passed.
- Release simulator build with Xcode 27.0: passed, including the SDK fallback.
- On a dedicated iPhone Duo / iOS 27.1 simulator, an XCTest UI run verified
  changing/restoring a Safari switch and opening/dismissing the help sheet.
  Screenshots of the outer display were inspected. Orientation commands were
  sent, but the captured app window remained 466 × 678 points, so this does
  **not** establish successful rotation or cross-display continuity.
- An existing Duo simulator also showed Slowth in a narrow window alongside
  Settings on the inner display.
- A second UI test passed with accessibility-large Dynamic Type, checking
  that Safari controls remain reachable by scrolling. The test simulator was
  restored to the normal large text setting afterward.
- User inspection of the first wide layout found duplicated Safari controls.
  Removed the environment-based visibility inference, assigned each section
  to exactly one pane, and added pane headings/borders. Both Debug (27.1) and
  Release (27.0) builds passed after this correction. The follow-up wide UI
  test was blocked by an app-launch timeout after the simulator restarted
  (`Failed to launch ... Timed out attempting to launch app`); its inner
  display capture was black. A subsequent successful launch allowed visual
  inspection of the inner display: the outer pane cards were removed on
  user feedback, Safari sites now have separate cards, and both columns sit
  on the shared background with a gap between them. The latest Debug build
  passed and was installed in the original Duo simulator.

Still verify in Device Hub: fullscreen inner display, book and tabletop folds,
portrait/landscape transitions, and opening/closing the device with a sheet
or Family Activity Picker already open. Check that Safari controls appear
exactly once, stay reachable, and keep their values. Device Hub UI automation
was unavailable because macOS Accessibility access was denied.

ReplayKit capture, recognition quality on new display aspect ratios, Screen
Time enforcement, and live Safari behavior need separate physical-device
validation. These UI changes do not qualify the detection models for Duo.

References: [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
and [Apple's adaptive layouts session](https://developer.apple.com/videos/play/tech-talks/111463/).
