# iPad layout

`Shared/ContentView_iOS.swift` chooses layout from the current window, not the
physical screen or launch orientation.

- Regular windows at least 900 pt wide with non-accessibility text show the
  existing iPad layout: feature cards across the top, Apps and Safari headings,
  and independently scrolling forms. Content is capped at 1440 pt; outer
  margins and the column gap remain 24 pt.
- Smaller windows and accessibility text use Apps / Safari / Settings tabs.
  Cards begin Apps. Recording and pauses remain in Apps; Strict mode is in
  Settings.
- Settings opens over wide content in a 384 pt trailing panel, capped at
  600 pt high, with native grouped settings and a close button. The backdrop
  covers the header too. Close with the cross, Escape, the backdrop, or the
  original Settings button position. Narrowing with Settings selected shows
  the Settings tab; widening shows the panel again.
- AppState, selections, independent Apps/Safari expansion, and presentation
  handlers live above the layout branches. Scroll offsets can reset between
  layouts. Leading/trailing alignment follows the interface language.
- Duo reuses these components with separate parameters; iPad does not use
  ArrangementView or hinge detection to choose its layout.

## Validation

The 2026-10-20 Duo change preserves the existing iPad thresholds, spacing,
card style, panel size, and settings placement. Debug iOS simulator build
passed with Xcode 27.1. iPad interactive regression, Stage Manager, Split View,
VoiceOver, and real-device recording were not rerun for this change.
