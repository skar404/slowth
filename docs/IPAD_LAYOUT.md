# iPad settings layout

The iPad reuses the Duo settings panes without depending on iOS 27.1's
ArrangementView. It uses the current window width and size class, so the same
rules also apply to resized windows.

- Regular-width windows at least 900 points wide show two independently
  scrolling columns: in-app blocking on the left, Safari on the right.
- The columns share a 1160-point maximum width with outer margins. There is
  no enclosing card around either column. Safari retains one card per site.
- Smaller windows and accessibility Dynamic Type use one centered form with
  a maximum width of 680 points. Safari appears exactly once in either layout.
- Strict retains its normal settings row and hero card on iPad. Recording
  controls remain in the in-app blocking settings. The action toolbar is
  exclusive to iPhone Duo.
- AppState and presentation state remain above the layout branches. Switching
  layouts may reset scroll positions but does not recreate settings state.
- Ordinary iPhone and Duo layout rules are unchanged.

Validation on 2026-10-07:

- Debug simulator build passed with Xcode 27.1.
- iPad Pro 13-inch and 11-inch (iOS 27.0) UI checks passed in both orientations.
  Checked column counts and widths and Safari ownership. The initial toolbar
  checks preceded its removal at the user’s request. No strict lock or recording
  was started.
- Visually inspected the 13-inch landscape layout.
- With accessibility-extra-large text on the 13-inch iPad, verified the single
  column and that Safari controls remain reachable by scrolling. Restored the
  standard large text setting after the check.
- Stage Manager dragging and Split View resizing were not driven in the simulator.
  Physical-device ReplayKit behavior was not tested by this UI change.
