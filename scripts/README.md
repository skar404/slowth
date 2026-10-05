# App utilities

GitHub Actions checks, build attestations and the optional TestFlight upload are
documented in [Build provenance and TestFlight](../docs/BUILD_TRUST.md).

Run these macOS utilities from the **repository root**. ML tooling has moved to
[`data-model/tools`](../data-model/tools/README.md); Python modules use `tools.*`
from `data-model`, not `scripts.*`.

## Generate icons

```sh
swift scripts/make-icons.swift build/generated-icons
```

Requires macOS/AppKit and Swift. The optional first argument is the output
folder (default: current directory); the script creates it and writes
`icon-<size>.png` for 16, 32, 48, 64, 96, 128, 256, 512 and 1024 pixels.
Existing same-named files may be overwritten. It does not update asset catalogs
or the Xcode project; inspect generated images before copying them into the app.

## Collect Realtime Shield device logs

Connect and trust the iPhone, reproduce the issue, then run:

```sh
scripts/collect_realtime_shield_logs.sh 30m
# Optional device UDID and output root:
scripts/collect_realtime_shield_logs.sh 2h DEVICE_UDID logs/realtime-shield
```

Arguments: `[duration] [device-udid] [output-root]`. Duration is a positive integer
followed by `m`, `h` or `d` (default `30m`). With multiple devices, pass the UDID.
The default output root is `logs/realtime-shield`, relative to the current
working directory; each collection creates a UTC-timestamped subdirectory.
macOS may prompt for administrator authorization through `sudo` to collect logs
from a physical device.

Outputs: `realtime-shield.logarchive`, `events.ndjson`, `errors.ndjson`,
`errors.log`, `metrics.ndjson`, `metrics.log`, and `summary.txt`, filtered to
`com.slowth.realtimeshield`. Open the archive in Console.app. Treat device logs
as private diagnostics, not training labels or model qualification evidence.

Production resources remain in root `RealtimeShield/`. Run `xcodegen generate`
from the repository root, never from `data-model`.

## Release resources

`python3 scripts/prepare_release_resources.py` derives the compact Cascade V10
metadata and `iOS/Info-Release.plist`. It verifies the frozen export hash, drops
the training-frame calibration inventory and local checkpoint paths, and removes Debug Photos permissions.
Use `--check` to verify the generated files without writing. When selecting a new
model, update the pinned source and runtime metadata identities together.

`python3 scripts/verify_app_configuration.py --configuration Release --app PATH`
checks a built iOS app and Broadcast extension for the intended models, exact
metadata/weights and Photos permissions. Use `--configuration Debug` for the full
test resource set.

## Releases

Use **one entry point**: `python3 scripts/release.py`.

```sh
# Source checks (no models or Apple credentials).
python3 scripts/release.py check

# Prepare model assets locally; does not sign or publish.
python3 scripts/release.py models --tag models-v10-1

# Publish to GitHub from a signed, committed source already on main.
# Use a new output directory if you prepared this tag locally before.
python3 scripts/release.py models --tag models-v10-1 \
  --output release-output/models-v10-1-publish \
  --gpg-key YOUR_GPG_FINGERPRINT --publish

# Run the iOS workflow with the published model asset.
python3 scripts/release.py ci --model-release models-v10-1
python3 scripts/release.py ci --model-release models-v10-1 --testflight

# Local unsigned iOS archive and manifest, using a downloaded asset.
python3 scripts/release.py build --model-bundle /path/to/Slowth-models.tar.gz \
  --output /tmp/slowth-ios-validation
```

`models --publish` checks the public snapshot and pinned model inputs, verifies
the existing source commit's signature, signs checksums and a new model tag,
pushes only that tag, uploads a draft, downloads and verifies every asset, then
publishes. It generates release notes automatically; `--notes FILE` replaces them.
It does not create commits, increase build numbers, or build/upload apps.
An existing tag or output directory is never overwritten. The source commit must
be signed by the explicitly selected key (`--gpg-key` or `RELEASE_GPG_KEY`).

The only release assets are `Slowth-models.tar.gz`, `model-manifest.json`,
`SHA256SUMS`, and `SHA256SUMS.asc`. Private exports, datasets, checkpoints, logs,
Apple credentials and Xcode archives remain local. The model importer validates
exact file names and pinned hashes before use. `--model-bundle FILE` on the
`models` command lets a maintainer prepare a package without private exports.

The internal modules in `scripts/release_tools/` are shared by the CLI and CI;
they are not separate entry points. The old shell wrapper and standalone CI
scripts have been removed. Native language-switching and WebKit UI diagnostics
remain separate utilities; the iOS pipeline does not claim to execute them.

See [Build provenance and TestFlight](../docs/BUILD_TRUST.md) for setup, recovery,
Apple secrets, and evidence verification.
