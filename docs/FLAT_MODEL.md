# Flat model defaults

## Flat 15 default (2026-10-28)

Flat 15 (`flat-15-seed7-20261028`) is the shared default by explicit user choice.
Release includes only FlatDetector15 and its runtime metadata; previous models
remain selectable in local Debug builds. Explicit saved Debug selections still
win when Debug is enabled. Selection remains frozen at broadcast start.
macOS model resources, the 11-class contract, 3-of-5 temporal policy and fail-closed
identity checks are unchanged.

The 60-epoch run used 17,682 train frames per epoch (`shuffle-all`), 2,682 validation
and 2,293 test frames. Best checkpoint: epoch 39, validation BA 94.522892%.
On the same current test, Flat 14 to Flat 15 BA is 95.783173% to 94.532147%;
false blocks remain zero. New-batch BA improves 95.068299% to 99.425121%.
The no-regression gate failed on BA and Facebook Reels simulated p95 (0.50 to
0.75 seconds). This is regression evidence, not an independent holdout.
Three old Reels test frames were removed before this run; comparisons use the
same surviving frames for both models, not the historical aggregate scores.

CPU Core ML parity passed on all 4,975 validation/test frames: zero argmax and
threshold differences, identical simulated temporal metrics, maximum probability
error 0.0000064969. Physical iPhone/ANE/ReplayKit behavior remains unverified.

Checkpoint SHA-256: `6b82cab92010a3f4814c6957ce60126460504a2926b2c22dd70ead358d998828`.
Package SHA-256: `86e41923fb8349e0878128db6603fd8609930d32cacd4bf5c11481ad9373ef26`.
Runtime metadata SHA-256: `6c99991c66cc6deee7d31794a0b1846198f44170dc8c14dce7ebaaa0e142540d`.

This is a local default change prepared for version/build 2026.10.7 / 28. A future
upload requires publication of the newly pinned Flat 15 model asset.
Existing GitHub releases and Apple uploads are unchanged.

Local verification passed: Debug/Release iOS and macOS Release builds, 8 Swift
selection/inference tests, 83 release tests and 5 configuration tests. The final
iOS Release bundles contain only Flat 15 in the broadcast extension, no models
in the host, and version/build 2026.10.7 / 28 across all seven bundles.
The 34 App Store release texts are copied unchanged from 2026.10.6.

## Flat 14 historical default (2026-10-28)

Flat 14 (`flat-14-seed7-20261028`) is the shared default by explicit user choice,
prioritizing the observed reduction in false blocks despite the temporal regressions
below. Release includes its package and metadata. Existing explicit Debug selections
and the backend frozen at broadcast start are preserved. macOS model resources are
unchanged. Release assets contain only Flat 14; previous models remain local Debug options.

The 60-epoch MPS run used 17,213 train frames once per epoch (`shuffle-all`),
2,325 validation and 1,942 test frames. Best checkpoint: epoch 27, validation BA
94.9272%. Snapchat remains canonical but is excluded from the 11-class snapshot.

Promotion gates failed: common-test BA 96.022193% → 96.021195%, old-test BA
96.070110% → 95.881960%; Shorts session recall 77.78% → 66.67% on common test
and 71.43% → 57.14% on old test; Shorts simulated p95 delay 1.25 → 2.50 seconds
on both. False blocks improved 1 → 0. New-test Shorts recall improved
97.41% → 99.14%, but these 116 frames contain only Shorts; new ordinary screens
were assigned to train. This is regression evaluation, not an independent holdout.

Core ML CPU parity passed on all 4,267 validation/test frames with zero argmax
or threshold differences and identical simulated temporal metrics (max error
0.0000047684). It does not qualify physical iPhone/ANE/ReplayKit behavior.

Resources: `data-model/exports/flat-14-seed7-20261028/ios-resources/FlatDetector14.mlpackage`
and `RealtimeShield/FlatDetector14Metadata.json`. Checkpoint SHA-256:
`fa0f681960bb02a60d008df8735c3d48433416e0915ddfc55fe7226c2b87cdeb`;
package: `a75bb25d4187800e88f1da8fd5a7a2b943fb33e6dbe4a79c5b2a81123aef30c1`;
metadata: `59d058f4ce0c63fb3395065902f100a13a4ae7010d507fcc54d0e0dbd436aacf`.

The original Debug-candidate builds and CPU parity checks passed. They do not
prove physical iPhone/ANE/ReplayKit behavior. Promotion uses version 2026.10.6,
build 27; current release evidence is recorded by the signed GitHub workflow.
Full local report: [Flat 14 experiment](../data-model/docs/flat-14-experiment.md).

## Flat 13 (historical default)

Before Flat 14 promotion, `ModelSettings.defaultBackend` was `.flat13`. Release loaded Flat 13;
Debug uses it unless an explicit saved model selection is active. Flat 11 and
Flat 12 remained selectable alternatives at that time. The selected backend is frozen at broadcast start.
The class contract, temporal policy and fail-closed identity checks are unchanged.

Resources: `data-model/exports/flat-13-seed7-20261027/ios-resources/FlatDetector13.mlpackage`
and `RealtimeShield/FlatDetector13Metadata.json`. Release includes all three Flat
packages in the broadcast extension and no models in the host. macOS model resources
are unchanged; the shared default and Debug picker also identify Flat 13 there.

Checkpoint SHA-256: `19e8b98bd570dbf99f19da7f3a5bce9a47c42fcff5f654f895e2724a75542bcb`.
Package SHA-256: `8a1bcb509ca73902fa1056bc5743acc210baa3c09ce1b07bf04d81b0ab2d58e3`.
Metadata SHA-256: `35211614cd836f8ef6c074edf0df80256bf41fed469bb89a51cb3d5fc020fc1e`.

Trained for 60 epochs, 16,582 train frames once per epoch, best epoch 47.
Validation BA: 93.1204%. Common regression test (1,826 frames): Flat 12 BA 92.7772%,
Flat 13 BA 96.0701%. This is not an independent holdout. Temporal regressions remain:
Instagram Stories session recall 90.91% → 63.64%, Instagram Reels 93.33% → 86.67%,
and old-test false blocks 0 → 1. Promotion was explicitly requested after these results.
Core ML CPU parity passed on 2,215 validation + 1,826 test frames: max error
0.000004828, zero argmax/threshold differences, identical simulated temporal metrics.
Physical iPhone/ANE/ReplayKit behavior is not verified by these checks.

Local model archive: `build/models-flat11-flat12-flat13-20261028/Slowth-models.tar.gz`.
The matching automatic-release pin is `models-flat11-flat12-flat13-20261028`;
this asset has not been published. Local pack/install/hash verification passed.
No app version/build bump, device installation, or App Store upload is part of this change.

Verification: Debug and Release iOS Simulator builds passed. Actual bundles contain
Flat 13 with matching weights/metadata; Release host has no models and the broadcast
extension has the three Flat models. 17 Swift selection/inference tests and 42 Python
tests (plus 48 subtests) passed. Model pack/install verification and changed-file
whitespace checks passed. Generated version/build remain 2026.10.6 / 26.
The existing unrelated `iOS/Info-Release.plist` derivation remains stale; model resource
hash checks pass. Reconcile that separate plist change before release publication.

## Flat 12 (2026-10-27, historical default)

Flat 12 (`flat-12-seed7-20261027`) was the shared application default on all
devices. `ModelSettings.defaultBackend` selects it for both the host and broadcast
extension; the extension freezes its choice at broadcast start. This supersedes
the earlier notched-iPhone-only selection.

Explicit saved Debug selections still override the default while Debug is enabled.
Release ignores Debug choices. Flat 11 remains available for Debug comparison.
Both models support the same 11 classes and retain the existing 3-of-5 policy
and fail-closed load guards.

Flat 12 identity: `flat-12-seed7-20261027`, checkpoint SHA-256
`83179b7136df664691eb391a11b18a3f682365d87c4aa488265743a0329a53ed`;
package SHA-256 `93e04140935d04ed69b16c416c0c273f3a8037ece821391f795b52f3c6b6259a`;
runtime metadata SHA-256 `d117451e29c1cf4c3f004e049f1c040abc44ec6ec6a0b5dfcc8b2275b91cbeab`.
Resources: `data-model/exports/flat-12-seed7-20261027/ios-resources/FlatDetector12.mlpackage`
and `RealtimeShield/FlatDetector12Metadata.json`. The existing Flat 11 resources
and hashes remain unchanged. Release bundles both in the broadcast extension and
neither in the host; Debug includes both plus its historical alternatives.

Core ML CPU parity passed on 2,084 validation and 1,716 test frames with zero
argmax/threshold mismatches and identical simulated temporal metrics (maximum
probability error 0.000004352). The common regression test yielded BA 96.13%,
zero false blocks, and iPhone 13 Pro Max Reels detection in 2/2 recordings with
simulated p95 delay 0.5 seconds. Two recordings do not qualify all notched devices;
there is no normal-use screen test on that device or independent holdout.
Physical iPhone/ANE/ReplayKit checks remain outstanding.

Debug/Release Simulator builds, model bundle checks, 15 Swift checks (including
compiled inference for both defaults), and five Python configuration checks passed.
The local two-model asset is `build/models-flat11-flat12-notch-20261027/Slowth-models.tar.gz`;
its pack/install/identity round trip passed. Release tooling now requires the new
`models-flat11-flat12-notch-20261027` asset, which has not been published. No phone
installation or App Store upload was performed.

An existing unrelated release-resource check is stale: `iOS/Info.plist` has local
labeler connection entries not present in `iOS/Info-Release.plist`. This task did
not propagate those Debug-related networking entries into Release; reconcile that
separate change before release preparation. Model metadata checks passed.

## Debug candidate added 2026-10-27

The Debug model picker also offers **Flat 11 · iPhone 13 Pro Max · 2026-10-26**
(`flat11IPhone13ProMax`). It remains a manual candidate; automatic defaults are
described above.
Choose the candidate before starting a new broadcast; selection is frozen for that
broadcast. Turning Debug off restores the default. This is a model trained on the
full expanded dataset, including the new iPhone 13 Pro Max recordings, not a
device-restricted model.

Candidate: `flat-11-seed7-iphone13promax-20261026`, 60 epochs, seed 7, selected epoch
35, validation balanced accuracy 0.9172467944. Snapshot counts are 15,868 train,
2,084 validation, 1,716 test. The checkpoint SHA-256 is
`938264c7f06e1fa0f3991a74f059eaa239e269edf128f68e5979b0082b7d5f78`.
Core ML package SHA-256 is
`9275048e2e85303e8cdc6174028d9b01e2e3f79b68368bfdaaff01dc9c22b4d3`.
Metadata SHA-256 is pinned independently in `FlatClassifier.Candidate`.

Local assets live in
`data-model/exports/flat-11-seed7-iphone13promax-20261026/ios-resources/` as
`FlatDetectorIPhone13ProMax.mlpackage` and `FlatDetectorIPhone13ProMaxMetadata.json`.
They are excluded from Release and are not part of the published default model
asset. Missing local candidate resources fail loading; they do not silently load
the default as if it were the candidate. No app version/build increment is needed
for this local Debug addition.

PyTorch/Core ML CPU parity passed on all 2,084 validation and 1,716 test frames:
zero argmax mismatches, zero threshold crossings, identical temporal metrics;
maximum error 0.000004888. The private export contains `parity.json`.
This verifies conversion, not improvement over the default. A quality comparison
against the default and physical iPhone/ANE/ReplayKit checks remain outstanding.
The new device's test data has no normal-use screens, so it cannot establish the
false-block rate on that device. There is no independent holdout.

## Original default

On 2026-10-15 the user explicitly selected `flat-11-seed7-20261015` as the application default. `DebugModelSettings.defaultBackend` selected it at that time; Release ignores saved Debug choices. Cascade V10 remains available in Debug. Existing explicitly saved Debug selections are preserved.

The frozen checkpoint is `data-model/epochs/experiments/flat-11-seed7-20261015/flat-calibrated.pt`, SHA-256 `ec5e7d29cd7ed29966d87cac3dfd08aec022a8878e5b595b0e5753ed2873f785`. Core ML package SHA-256: `4d672879ea1f33e8ddbad369b67d26e048e09836522e2eaad561dbf55b1f7a1e`. The runtime metadata is pinned in `FlatClassifier.swift`; it includes the exact class order, six validation thresholds and qualification status. The model creator metadata is checked at load time.

The model receives RGB 192 × 384 and returns 11 softmax probabilities directly. There is no routing gate or route-change evidence reset. Disabled apps have zero detection scores. The existing 3-of-5 window runs every 0.25 seconds and resets after gaps over 1.25 seconds. Release contains only FlatDetector and its compact metadata in the broadcast extension; the host has no model copies.

## Verification

- PyTorch/Core ML CPU parity: all 1,941 validation and 1,567 test images. Zero argmax differences, zero threshold crossings, identical session metrics. Maximum probability error 0.000004411. Report: `data-model/exports/flat-11-seed7-20261015/parity.json`.
- Debug and Release iOS Simulator builds succeeded, with actual bundle model/metadata checks.
- Swift Debug/Release tests cover selection, direct class scores, disabled apps, malformed outputs, compiled model loading and CPU inference.
- Python tests cover the flat training contract, app resource configuration and release asset verification; web tests cover current-model highlighting.

This remains experimental: no independent holdout, one training seed, no physical iPhone/ANE/ReplayKit qualification. Compared with V10 on the reused regression set, balanced accuracy improved (97.13% vs 95.58%) but Instagram Stories and Facebook Stories session recall regressed (50% vs 62.5%, and 80% vs 100%). Promotion does not remove these limitations.

## Original Flat 11 release asset (historical)

The local pinned model asset is `build/models-flat-11-seed7-20261015/Slowth-models.tar.gz`. `automatic.py` references `models-flat-11-seed7-20261015`; this GitHub model release has **not** been published. Before an app release, publish and verify the signed model asset using the existing model release process. Archive creation is deterministic so its digest survives regeneration. No App Store upload, version/build increment or phone installation was performed as part of this change.

The private `data-model` export and tools remain ignored by Git, consistent with existing model storage. Public source and runtime metadata alone do not contain the model weights; clean builds need the matching asset.
