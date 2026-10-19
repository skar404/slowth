# Flat 11 seed 7 application default

On 2026-10-15 the user explicitly selected `flat-11-seed7-20261015` as the application default. `DebugModelSettings.defaultBackend` selects it; Release ignores saved Debug choices. Cascade V10 remains available in Debug. Existing explicitly saved Debug selections are preserved.

The frozen checkpoint is `data-model/epochs/experiments/flat-11-seed7-20261015/flat-calibrated.pt`, SHA-256 `ec5e7d29cd7ed29966d87cac3dfd08aec022a8878e5b595b0e5753ed2873f785`. Core ML package SHA-256: `4d672879ea1f33e8ddbad369b67d26e048e09836522e2eaad561dbf55b1f7a1e`. The runtime metadata is pinned in `FlatClassifier.swift`; it includes the exact class order, six validation thresholds and qualification status. The model creator metadata is checked at load time.

The model receives RGB 192 × 384 and returns 11 softmax probabilities directly. There is no routing gate or route-change evidence reset. Disabled apps have zero detection scores. The existing 3-of-5 window runs every 0.25 seconds and resets after gaps over 1.25 seconds. Release contains only FlatDetector and its compact metadata in the broadcast extension; the host has no model copies.

## Verification

- PyTorch/Core ML CPU parity: all 1,941 validation and 1,567 test images. Zero argmax differences, zero threshold crossings, identical session metrics. Maximum probability error 0.000004411. Report: `data-model/exports/flat-11-seed7-20261015/parity.json`.
- Debug and Release iOS Simulator builds succeeded, with actual bundle model/metadata checks.
- Swift Debug/Release tests cover selection, direct class scores, disabled apps, malformed outputs, compiled model loading and CPU inference.
- Python tests cover the flat training contract, app resource configuration and release asset verification; web tests cover current-model highlighting.

This remains experimental: no independent holdout, one training seed, no physical iPhone/ANE/ReplayKit qualification. Compared with V10 on the reused regression set, balanced accuracy improved (97.13% vs 95.58%) but Instagram Stories and Facebook Stories session recall regressed (50% vs 62.5%, and 80% vs 100%). Promotion does not remove these limitations.

## Future release

The local pinned model asset is `build/models-flat-11-seed7-20261015/Slowth-models.tar.gz`. `automatic.py` references `models-flat-11-seed7-20261015`; this GitHub model release has **not** been published. Before an app release, publish and verify the signed model asset using the existing model release process. Archive creation is deterministic so its digest survives regeneration. No App Store upload, version/build increment or phone installation was performed as part of this change.

The private `data-model` export and tools remain ignored by Git, consistent with existing model storage. Public source and runtime metadata alone do not contain the model weights; clean builds need the matching asset.
