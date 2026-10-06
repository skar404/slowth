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
python3 scripts/release.py check

# Validate both platforms without signing or uploading.
python3 scripts/release.py ci --model-release models-v10-1

# Build both apps: notarized Mac ZIP + iOS IPA and macOS PKG uploaded to TestFlight.
# Increment every build number, regenerate, sign the commit and push main first.
python3 scripts/release.py ci --model-release models-v10-1 --testflight

# Create one GitHub Release for the app version from that successful run.
# RUN_ID is printed by GitHub Actions; this command never rebuilds or uploads to Apple.
python3 scripts/release.py version --run RUN_ID --model-release models-v10-1 \
  --gpg-key YOUR_GPG_FINGERPRINT --publish

# Local unsigned builds (both by default; --platform iOS or macOS selects one).
python3 scripts/release.py build --model-bundle /path/to/Slowth-models.tar.gz \
  --output /tmp/slowth-validation
```

Ordinary CI runs never create a GitHub Release. `version --publish` creates
`v<MARKETING_VERSION>` only when explicitly requested. It verifies the successful
run, source commit, build identity, four GitHub attestations and model inputs;
then signs checksums and the version tag, uploads a draft, downloads every asset
and checks its bytes before publishing. The existing source commit must be signed
with the explicitly selected GPG key. Existing tags are never overwritten.

Assets: the exact `Unscroll.ipa` sent to TestFlight, `Slowth-macOS.zip` containing
the Developer ID-signed and notarized universal Mac app, `Slowth-macOS-TestFlight.pkg`
(the separate App Store package), `Slowth-models.tar.gz`,
`build-manifest.json`, four attestation bundles, `SHA256SUMS`, and `SHA256SUMS.asc`.
The IPA and TestFlight PKG are for verification; install these through TestFlight/App Store. The Mac ZIP
is intended for installation: extract it and move Slowth.app to Applications.

Omit `--publish` to prepare and inspect the assets and generated notes locally.
Use a new `--output` directory for the subsequent publication attempt. `--notes`
can supply custom public notes. The source must still match published main and
the successful CI run; no source modifications are silently included.

Models stay out of Git. Reuse `--model-release v2026.8.2` after publishing that
version, or an existing `models-*` release while bootstrapping. When the pinned
models change, `models --tag models-NEW --gpg-key KEY --publish` remains an explicit
input-publication utility; it never runs automatically. `models --tag TAG` only
prepares local assets, and `--model-bundle FILE` imports an existing model package.

Private exports, datasets, checkpoints, credentials, debug symbols, raw logs and
Xcode archives are not release assets. Shared implementation lives in
`scripts/release_tools/`; these are not separate entry points. Native UI diagnostics
remain separate utilities.

See [Build provenance and TestFlight](../docs/BUILD_TRUST.md) for setup, recovery,
Apple secrets, and evidence verification.
