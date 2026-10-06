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

# Publish a NEW app version: update marketing version + shared build number first,
# regenerate, sign the source commit and push main, then:
python3 scripts/release.py tag --gpg-key YOUR_GPG_FINGERPRINT
# Or push an annotated tag signed with that key: git tag -s ...; git push origin ...
# CI builds both platforms, uploads to TestFlight and publishes the verified assets.

# Local unsigned builds (both by default; --platform iOS or macOS selects one).
python3 scripts/release.py build --model-bundle /path/to/Slowth-models.tar.gz \
  --output /tmp/slowth-validation
```

A push of a **new signed `v<MARKETING_VERSION>` tag** starts automatic publication.
The tag must point to the current signed main commit and match the app version.
`release-tag.yml` verifies it and dispatches `release-ci.yml` on main. The protected
workflow rechecks the same commit/tag before accessing Apple credentials, builds
both apps, waits for both TestFlight uploads to process, verifies provenance and
publishes a GitHub Release only after downloading and checking its draft assets.
If main moves before dispatch, the run stops; it never substitutes another commit.

Ordinary main pushes and `ci` commands do not create releases. Do not run
`ci --testflight` first for a version you intend to release by tag: the tag run
builds and uploads, so it needs a fresh build number. Existing tags/releases are
never overwritten. The former `version --publish` flow is disabled to prevent
creating a tag that uploads the same build twice; `version` without `--publish`
remains a legacy local evidence-inspection command.

Automatic releases contain eleven assets: the exact `Unscroll.ipa` and
`Slowth-macOS-TestFlight.pkg` sent to Apple, the notarized universal
`Slowth-macOS.zip`, `Slowth-models.tar.gz`, `build-manifest.json`, four build
attestation bundles, `SHA256SUMS`, and `checksums-attestation.jsonl`.
The tag/commit use your local GPG key. CI uses GitHub keyless attestations for
artifacts/checksums; it never receives your private GPG key. Older releases and
model releases keep their existing `SHA256SUMS.asc` signatures.

The IPA and TestFlight PKG are for verification; install through TestFlight/App Store.
Extract the Mac ZIP and move Slowth.app to Applications for direct installation.
Automatic model input is pinned by release name and archive SHA-256 in
`scripts/release_tools/automatic.py`; individual model pins are checked too.
Update those reviewed pins together when switching models.

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
