# Realtime Shield dataset

Private captures live under `sandbox/dataset/` and are ignored by Git. The
tracked code assumes a session-aware layout:

```text
sandbox/dataset/
  manifest.csv
  frames/
    youtube/
      shorts/<session-id>/*
      normal/<session-id>/*
    instagram/
      reels/<session-id>/*
      stories/<session-id>/*
      normal/<session-id>/*
    other/
      normal/<session-id>/*
```

Folders describe what is visible; safety policy does not become a class name.
The manifest's `is_critical` field marks zero-tolerance negative frames such as
ordinary YouTube/Instagram screens, Home Screen, App Library, and transitions.

## Manifest schema

- `path`: path relative to `sandbox/dataset/`.
- `app`: `youtube`, `instagram`, or `other`.
- `content`: `normal`, `shorts`, `reels`, or `stories` where valid for the app.
- `is_critical`: whether a false blocking decision is zero-tolerance.
- `session_id`: one recording/import session; it must belong to one split.
- `split`: `train`, `validation`, `test`, or `unassigned`.
- `captured_at`: capture time used to order temporal decisions.
- `device_model`, `os_version`, `app_version`, `orientation`: capture context.
- `source_batch`: provenance for correcting imports later.

New captures start as `unassigned`. Assign complete sessions—not individual
frames—to train, validation, or test. A test session must remain untouched by
model selection and threshold calibration.

Validate the inventory before training. Validation rejects unregistered or
missing files, duplicate SHA-256 content, invalid metadata, and sessions that
cross surfaces or splits:

```sh
uv run python scripts/realtime_dataset.py validate sandbox/dataset/manifest.csv
```

Register every new recording as its own session. Imports default to
`unassigned`; `--move` is optional and copying is safer:

```sh
uv run python scripts/realtime_dataset.py add-session \
  sandbox/dataset/manifest.csv path/to/extracted-frames \
  --app instagram --content reels --session instagram-reels-002
```

Orientation defaults to automatic detection from pixel dimensions. Pass an
explicit `--orientation` only when source metadata requires an override.

For ordinary app screens, pass `--content normal --critical`. Never reuse a
session ID for frames from a different recording or split.

After reviewing a session boundary, assign the complete session atomically:

```sh
uv run python scripts/realtime_dataset.py assign-split \
  sandbox/dataset/manifest.csv instagram-reels-001 train
```

By default this only accepts an `unassigned` source session, preventing an
accidental rewrite of validation or test data.

When one import contains several confirmed recording sessions, split it by
inclusive image-name ranges. Every source frame must be covered exactly once;
overlaps, gaps, existing destination sessions, and unexpected source splits
are rejected before files move:

```sh
uv run python scripts/realtime_dataset.py split-session \
  sandbox/dataset/manifest.csv imported-reels --from-split train \
  --partition instagram-reels-001:validation:IMG_2683.PNG:IMG_2690.PNG \
  --partition instagram-reels-002:test:IMG_2691.PNG:IMG_2706.PNG \
  --partition instagram-reels-003:train:IMG_2707.PNG:IMG_2821.PNG
```

## Hierarchical model training

`scripts/surface_ml.py` trains an app head plus app-specific content heads:

| Manifest value | SurfaceDetector class |
| --- | --- |
| `youtube/shorts` | `youtube_shorts` |
| `youtube/normal` | `youtube_normal` |
| `instagram/reels` | `instagram_reels` |
| `instagram/stories` | `instagram_stories` |
| `instagram/normal` | `instagram_normal` |
| `other/normal` | `other_app` |

The runtime derives these joint surface probabilities by multiplying the app
probability by the appropriate conditional content probability. This keeps app
identity and in-app content as separate learned outputs without allowing
unsupported labels such as YouTube Reels.

Instagram Reels and Stories are separate blocking targets with independently
calibrated thresholds. All six classes must have independent train and
validation sessions before training; all six must have test sessions before final evaluation. The
trainer ignores `unassigned` rows and fails with a list of missing classes
instead of silently producing an incomplete classifier.

Pass `--report` to `surface_ml.py train` to persist the selected epoch,
confusion matrix, session metrics, thresholds, and the exact quality-gate
failure reason. A failed gate does not write the requested checkpoint.

Safety-focused experiments can set `--critical-weight` and
`--instagram-content-loss-weight`. Record both values with each report; compare
experiments on validation only and never tune them against test. Probability
safety margin is applied as a fraction of the remaining headroom to 1.0, which
keeps it meaningful for highly confident calibrated scores.

When a new model must not weaken an already qualified production policy, run
`retune-policy --threshold-floor-checkpoint <incumbent.pt>`. Each target then
uses the maximum of its validation-calibrated threshold and the incumbent
threshold. The resulting thresholds are re-evaluated against validation and
the provenance is stored in the checkpoint and exported metadata.

Export uses FP32. Do not downgrade it without rerunning parity: the current
candidate's FP16 conversion exceeded the 0.01 probability tolerance and changed
a critical Reels decision, while FP32 preserved all validation decisions.
