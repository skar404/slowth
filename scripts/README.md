# App utilities

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

`python3 scripts/prepare_release_resources.py` derives the compact Cascade V6
metadata and `iOS/Info-Release.plist`. It verifies the frozen export hash, drops
the training-frame calibration inventory and local checkpoint paths, and removes Debug Photos permissions.
Use `--check` to verify the generated files without writing. When selecting a new
model, update the pinned source and runtime metadata identities together.

`python3 scripts/verify_app_configuration.py --configuration Release --app PATH`
checks a built iOS app and Broadcast extension for the intended models, exact
metadata/weights and Photos permissions. Use `--configuration Debug` for the full
test resource set.

## Signed public releases

`scripts/release.sh` publishes the current public working tree. It requires macOS,
Xcode with signing/provisioning credentials, XcodeGen, Python 3.9+, Node.js, GnuPG,
GitHub CLI authentication, and `Configs/Local.xcconfig`. Run it with the full Xcode
selected (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if needed).
The normal invocation automatically publishes after all checks pass:

```sh
scripts/release.sh --gpg-key YOUR_GPG_FINGERPRINT --release-notes release-notes.txt
# RELEASE_GPG_KEY can supply the explicit key instead of --gpg-key.
```

The notes file must be nonempty. The key must be an explicit hexadecimal key ID
or fingerprint (at least 16 characters); there is no default-key fallback. The
script verifies both the commit and tag against that key's primary fingerprint.

Before publication, set the marketing version consistently in `project.yml`,
`WebExt/manifest.json`, and `WebExt/app.html`. Set **every** build override and the
base `CURRENT_PROJECT_VERSION` to the same number, greater than the previous
public build and any build already uploaded to App Store Connect. The script
checks the prior public build but cannot discover unpublished App Store builds.
It never changes version numbers automatically. Local checks/builds need no bump.

The branch must be `main`, with HEAD equal to live `origin/main`, one matching
GitHub fetch/push URL, and no existing release tag. This avoids accidentally
pushing unaudited local ancestors. Existing public history is not rewritten.
Keep the branch and staging area stable while a release runs.

### Public snapshot and model inputs

The script stages into a **temporary index**, leaving the real index unchanged
until the verified release commit is installed. It includes the app directories,
`Localization/`, `WebExt/`, `scripts/`, `tests/`, and the listed public root files.
Python utilities and tests are allowed. Exact exceptions preserve the two public
`Configs` templates and the four README images in `docs/`. Other top-level paths
are excluded; unknown tracked files and private staged additions fail the check.
Existing worktree deletions are included. The retired tracked
`RealtimeShield/SurfaceDetector.mlpackage` and `SurfaceDetectorMetadata.json` are
removed from the release tree but retained locally; they are no longer build
inputs. No production model is committed.

Both the staged changes and complete proposed tree are checked. Symlinks,
submodules, model packages, checkpoint files, private directories, private-key
blocks and absolute home-directory paths fail validation. JSON resources must
parse. These are explicit path/content checks; review public source changes and
release notes as usual. Arbitrary secrets disguised as application source cannot
be identified by an allowlist alone.

The three Cascade V6 packages are copied from the pinned local export, checked
against fixed package SHA-256 identities and packed with public runtime metadata.
The bundle contains only the exact expected files, with no training code,
checkpoint files or full calibration metadata. Runtime metadata retains the
candidate's existing qualification status; this workflow does not promote it.
Missing Debug-only exports are optional in XcodeGen, so public checkouts can build
Release with only this model asset. Debug model experiments still need local
private exports. Local signing settings are copied only into the temporary build
workspace.

### Check or build without publishing

```sh
scripts/release.sh check
scripts/release.sh build --output /tmp/slowth-release-build
python3 -m unittest discover -s tests -p test_release.py -v
```

`check` validates the public snapshot, versions, model hashes, generated resources,
Xcode project and all WebExtension Node tests. It creates temporary Git objects
but no commit, tag, archives or remote changes. `build` additionally archives both
platforms, checks signatures, actual bundle versions, iOS Release resources,
every native/WebExtension locale, native language switching and real WebKit locale
selection. It runs in the logged-in macOS GUI session for the WebKit tests.
Neither mode needs GPG or GitHub authentication.

Outputs default to `release-output/v<version>-build<build>/`; `--output` must name
a new directory. Outputs include both `.xcarchive.zip` files, the models tarball,
`release-manifest.json`, and `SHA256SUMS`. Publication also creates
`SHA256SUMS.asc`; the signed tag records the SHA-256 of `SHA256SUMS`. The manifest
records the exact source tree, commit, build environment and asset/input hashes.
An uncommitted local build has `commit: null` and records its base commit instead.
Archive signing and timestamps mean rebuilds are not byte-for-byte reproducible.

### Rebuild a downloaded release

Check out its signed tag, copy/edit `Configs/Local.xcconfig.example` as above,
then download the release assets into the repository root (or use absolute paths):

```sh
git verify-tag v0.9.3
gpg --verify SHA256SUMS.asc SHA256SUMS
shasum -a 256 -c SHA256SUMS
scripts/release.sh build --model-bundle Slowth-v0.9.3-build9-models.tar.gz
```

Use the release signer's verified GPG fingerprint. The bundle is unpacked only
inside the temporary workspace. The importer rejects unexpected paths, links,
duplicates, oversized entries, incomplete bundles and hash mismatches before any
build. The manifest also includes a manual unpack command for trusted bundles.

### Publication and failures

After both archives and all checks pass, the script creates and verifies the
GPG commit and tag, installs the commit on `main`, and pushes the exact commit and
tag atomically. It uploads all assets to a draft GitHub Release, downloads and
checks each uploaded byte sequence, then publishes and verifies the asset list.
Any failure stops subsequent operations. Local output and any already-created
commit, tag or draft are retained for inspection. There is no automatic rollback,
force-push, tag replacement or overwrite on retry. If upload fails after push,
inspect the existing tag and assets and repair the draft using `gh release upload`
and `gh release edit` after verifying checksums; rerunning publication with the
same tag intentionally fails.
