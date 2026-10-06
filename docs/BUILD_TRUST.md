# Build provenance and TestFlight

Use `python3 scripts/release.py` for every release operation. A new signed app-version
tag starts the build, TestFlight uploads and GitHub Release automatically. Ordinary
main pushes and manual build-only CI runs do not create GitHub Releases.

Slowth links a public source commit, pinned model inputs, a CI run, and the exact
IPA uploaded to Apple. This is traceability, not a byte-for-byte comparison with
an installed App Store app. Apple processes downloads; a displayed commit label
is an identifier, not independent verification. Builds are not claimed to be
hermetic or byte-for-byte reproducible.

## Commands

| Command | Result | Remote changes |
| --- | --- | --- |
| `check` | Validates public source, versions, runtime metadata and WebExtension tests | None |
| `models --tag TAG` | Prepares model bundle, manifest, checksums and generated notes | None |
| `models --tag TAG --gpg-key KEY --publish` | Signs and publishes a verified model release | Signed tag and GitHub Release |
| `build --model-bundle FILE --output DIR` | Validates unsigned iOS and macOS Release archives and creates a local manifest | None |
| `ci --model-release TAG` | Dispatches unsigned iOS/macOS validation on main | GitHub Actions run |
| `ci --model-release TAG --testflight` | Builds both platforms, notarizes macOS and uploads both platforms to Apple | Actions run and TestFlight build |
| `tag --gpg-key KEY` | Signs and pushes the current app-version tag; CI builds, verifies and publishes | Signed tag, TestFlight uploads and GitHub Release |

`build --testflight` is reserved for the GitHub workflow, not local use.
All output directories must be new. Local preparation can use modified public
sources; its manifest has `commit: null` and records `source_tree` instead.
Publishing and dispatching require the exact reviewed public snapshot already
committed and pushed to main. The tool does not stage or commit source for you.

## Publish an app version

The release flow is **update version/build → sign and push main → push a signed
version tag → automatic build/upload/verification/publication**.

Before tagging, choose a new marketing version (`year.month.index`) and a shared
build number greater than every previously uploaded build. Synchronize the version
in project.yml, WebExt/manifest.json and WebExt/app.html; regenerate with
`xcodegen generate`. Sign the reviewed source commit with the configured release
key and push it to main. The CLI never changes versions automatically.

```sh
python3 scripts/release.py check
python3 scripts/release.py tag --gpg-key 68BEAF78936945EC66B7C5273E8FD639DD4791CC
```

Or create an annotated, GPG-signed `v<MARKETING_VERSION>` tag using that same key
and push it explicitly. Lightweight/unsigned tags and tags for a different version,
source commit or signer are rejected. `models-*` tags do not trigger app builds.
There is one immutable GitHub Release per marketing version. Existing tags and
releases, including older manually published releases, are never overwritten.

`release-tag.yml` verifies the tag and commit against the checked-in public key,
then dispatches `release-ci.yml` on main with the version tag as input.
[GitHub permits workflow_dispatch using GITHUB_TOKEN](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).
The protected main workflow verifies the tag again before the Apple environment
is accessible. The tag must match its exact GITHUB_SHA, so moving main between tag
push and dispatch stops the run instead of building the wrong source. Attestations
still identify `refs/heads/main` and the tag's exact commit. The `app-store`
environment remains restricted to main; Apple credentials are never exposed to
the tag dispatcher or publication job.

Automatic inputs are `MODEL_RELEASE` and `MODEL_SHA256` in
`scripts/release_tools/automatic.py`, plus the individual model pins in core.py.
The build job signs/notarizes both apps, waits for both Apple platforms to be VALID
and retains evidence. A separate publication job checks that successful build job,
exact source/version/build/attempt, model archive hash and all four attestations.
It attests checksums, uploads a draft, downloads every asset and compares the bytes
before making the release public. A failed build creates no GitHub Release.

The local GPG key signs the source commit/tag. **CI never receives the private
GPG key**: new automatic releases use a GitHub keyless checksum attestation instead
of `SHA256SUMS.asc`. Older release and model checksum signatures are unchanged.
The expected primary fingerprint is
`68BEAF78936945EC66B7C5273E8FD639DD4791CC`; the public key is checked in at
`scripts/release_tools/release-signing-key.asc`. Verify its fingerprint through a
trusted channel before importing it.

Do not run `ci --testflight` before tagging that version: the automatic tag run
needs an unused upload build number. Build-only TestFlight runs remain useful for
replacement/testing builds without creating another GitHub Release. The old
`version --publish` command is disabled to prevent a second upload triggered by
its tag. `version` without `--publish` remains available for local inspection of
legacy main-run evidence.

Version releases contain exactly these eleven assets (plus GitHub's source archives):

- `Unscroll.ipa`: the exact App Store-signed file sent to TestFlight. For verification;
  install through TestFlight or the App Store, not by opening this IPA.
- `Slowth-macOS.zip`: universal Apple Silicon/Intel app, Developer ID-signed,
  notarized, with a stapled ticket. Extract and move Slowth.app to Applications.
- `Slowth-macOS-TestFlight.pkg`: the exact Mac App Store-signed package sent to Apple;
  retained for verification. Use TestFlight to install this build or the ZIP for direct distribution.
- `Slowth-models.tar.gz`: the exact input archive used by CI.
- `build-manifest.json`: source, version/build, binary hashes and Apple results.
- `manifest-attestation.jsonl`, `ipa-attestation.jsonl`, `macos-attestation.jsonl`,
  `macos-store-attestation.jsonl`.
- `SHA256SUMS` and `checksums-attestation.jsonl`: hashes of the nine preceding files
  and a GitHub provenance signature for the checksum file.

An app-version release can supply models to future runs, e.g.
`ci --model-release v2026.8.2 --testflight`. Existing model releases remain valid
inputs. Creating a standalone model release is an explicit bootstrap operation,
never a side effect of a normal app build.

## Publish model inputs

Commit and push the reviewed source first. Model publication verifies that the
commit is signed by the explicitly chosen GPG key. Select that same trusted key
with `--gpg-key` or `RELEASE_GPG_KEY`; there is no implicit default-key selection.

```sh
python3 scripts/release.py check
python3 scripts/release.py models --tag models-v10-1 \
  --gpg-key YOUR_GPG_FINGERPRINT --publish
```

This command:

1. Checks the public snapshot and versions; verifies the source signature and
   that main matches the live remote and the new model tag does not exist.
2. Packages only the five pinned V10 Core ML packages and compact runtime
   metadata. It round-trips the strict importer before signing anything.
3. Creates `model-manifest.json`, `SHA256SUMS`, and generated release notes.
   Optional `--notes FILE` supplies your own nonempty public notes.
4. Signs the checksums and creates a signed tag on the existing source commit.
   The tag records the hash of SHA256SUMS, binding it to the assets.
5. Pushes only that tag, creates a draft GitHub Release, downloads all four
   assets and verifies their bytes, then publishes it without marking it latest.

No marketing version or build number change is needed for model publication.
Reuse a model release across app releases until the pinned model content changes.
Models retain their existing qualification; publication does not promote them.

Output defaults to `release-output/<tag>`. To inspect a package before publishing:

```sh
python3 scripts/release.py models --tag models-v10-1
# After review, select a new directory for the publication attempt:
python3 scripts/release.py models --tag models-v10-1 \
  --output release-output/models-v10-1-publish \
  --gpg-key YOUR_GPG_FINGERPRINT --publish
```

`--model-bundle FILE` imports a previously downloaded model archive instead of
private exports. The exact package hashes pinned in the checked-out source are
always required. Old V6 assets cannot build the V10 source. Datasets, training
sources, checkpoints, calibration inventories and credentials are not assets.
Model releases contain exactly `Slowth-models.tar.gz`, `model-manifest.json`,
`SHA256SUMS`, and `SHA256SUMS.asc`. Verify with the trusted signing key:

```sh
gpg --verify SHA256SUMS.asc SHA256SUMS
shasum -a 256 -c SHA256SUMS
```

## GitHub Actions and Apple setup

**Source checks** runs on pull requests and main and needs no Apple credentials
or models. **iOS and macOS release builds** runs on main after a signed version-tag
dispatch, or manually via the `ci` command. Both paths build iOS and macOS. The
signed path also notarizes the Mac app. The same Mac archive receives a separate
App Store export for macOS TestFlight.

Actions are pinned by commit; tool versions are Python 3.12.9, Node 22.14.0,
XcodeGen 2.46.0 (download SHA-256 checked), and Xcode 26.6 / 17F113. The `macos-26`
runner image can change; its version is recorded. A missing pinned Xcode fails
the build instead of selecting another version.

Create the `app-store` GitHub environment, restricted to main, with required
reviewers where available. Put Apple secrets in that environment. Protect main
with review and the `Source checks / check` required check. `ci-validation` needs
no secrets. Configure these values in Settings → Environments → app-store:

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `APPLE_TEAM_ID` | Apple Developer team ID |
| Variable | `BUNDLE_ID_PREFIX` | Existing production prefix used by the app |
| Variable | `ASC_APP_ID` | Numeric App Store Connect app ID |
| Secret | `ASC_KEY_ID` | App Store Connect team API key ID |
| Secret | `ASC_ISSUER_ID` | Team API key issuer UUID |
| Secret | `ASC_KEY_P8_BASE64` | Base64 of the API key's `.p8` file |
| Secret | `APPLE_CERTIFICATE_P12_BASE64` | Base64 of an Apple Distribution certificate **with its private key** |
| Secret | `APPLE_CERTIFICATE_PASSWORD` | Nonempty password protecting that `.p12` |
| Secret | `MACOS_CERTIFICATE_P12_BASE64` | Base64 Developer ID Application certificate with its private key |
| Secret | `MACOS_CERTIFICATE_PASSWORD` | Nonempty password protecting that `.p12` |
| Secret | `MACOS_PROFILE_APP_BASE64` | Base64 Developer ID (`MAC_APP_DIRECT`) profile for the Mac host |
| Secret | `MACOS_PROFILE_SAFARI_BASE64` | Base64 Developer ID profile for the Mac Safari extension |
| Secret | `MACOS_INSTALLER_P12_BASE64` | Base64 Mac Installer Distribution certificate with its private key |
| Secret | `MACOS_INSTALLER_PASSWORD` | Nonempty password protecting the installer `.p12` |
| Secret | `MACOS_STORE_PROFILE_APP_BASE64` | Base64 Mac App Store (`MAC_APP_STORE`) profile for the Mac host |
| Secret | `MACOS_STORE_PROFILE_SAFARI_BASE64` | Base64 Mac App Store profile for the Safari extension |
| Secret | `IOS_PROFILE_APP_BASE64` | Base64 App Store profile for `<prefix>.ios` |
| Secret | `IOS_PROFILE_SAFARI_BASE64` | Base64 App Store profile for `<prefix>.ios.Extension` |
| Secret | `IOS_PROFILE_BROADCAST_BASE64` | Base64 App Store profile for `<prefix>.ios.Broadcast` |
| Secret | `IOS_PROFILE_DEVICE_ACTIVITY_BASE64` | Base64 App Store profile for `<prefix>.ios.DeviceActivity` |
| Secret | `IOS_PROFILE_SHIELD_CONFIG_BASE64` | Base64 App Store profile for `<prefix>.ios.ShieldConfig` |
| Secret | `IOS_PROFILE_SHIELD_ACTION_BASE64` | Base64 App Store profile for `<prefix>.ios.ShieldAction` |

Use a team API key permitted to read the app/builds and upload builds (Developer
or another suitable App Store Connect role). An individual key without an issuer
is not supported. Use App Store distribution profiles for the host and **all five
extensions**, including their approved Family Controls and App Group entitlements.
Debug/development, device-limited, expired and wrong-team profiles are rejected.
Profiles with a legacy App Identifier Prefix different from the team ID are not
supported by this initial workflow. Certificates/profiles are not created by CI.

Store each profile in its own secret: combining all six base64 profiles can
exceed GitHub's per-secret size limit. Generate single-line base64 values, without
line wrapping. CI verifies each decoded profile's bundle identifier against the
target in `project.yml`.

The signing keychain and profiles are installed temporarily and removed in a
`finally` block. GitHub destroys the hosted runner after the job, including on
cancellation. Do not switch this workflow to a persistent self-hosted runner
without reviewing cleanup and isolation.

The Mac profiles must authorize the same shared App Group as the existing app.
The CI builds a universal binary, exports with Developer ID, submits it using
`notarytool` and the same team API key, requires `Accepted`, staples and validates
the ticket, and checks Gatekeeper before packaging. Apple Distribution used for
iOS cannot substitute for Developer ID. Mac notarization completes before the
uploads. For macOS TestFlight, Xcode exports that same archive again with Apple
Distribution, the two Mac App Store profiles and Mac Installer Distribution.
The script expands the resulting PKG and verifies both bundle versions, embedded
identities/profiles, entitlements, universal architectures and signatures before
uploading. Developer ID ZIP and TestFlight PKG have different signatures and hashes.
Profiles and keychains are temporary for all distribution paths.

## Run a build

For a new Apple upload, increment every `CURRENT_PROJECT_VERSION` above all known
uploaded builds, including replacement builds. Keep one monotonic counter across
iOS/macOS and every extension. Keep marketing versions synchronized, regenerate
with `xcodegen generate`, then commit and push. The tool never bumps versions or
lets Xcode renumber an exported IPA automatically.

```sh
# First validate the published source and model inputs:
python3 scripts/release.py ci --model-release models-v10-1

# After configuring signing and selecting a fresh build number:
python3 scripts/release.py ci --model-release models-v10-1 --testflight
```

The CLI checks published main, confirms that the model release is public, and
validates its downloaded model bundle before dispatch. GitHub resolves main at
dispatch time: check the actual run's commit before using its result. A successful
dispatch only means the run was requested; inspect Actions for its final result.

CI checks app/extension versions, embedded identities, model weights, resource
metadata, absence of Debug capture code and Photos permissions, and all compiled
localizations. The signed path checks the exported IPA and signature, uploads
the exact IPA and Mac PKG, and waits up to 20 minutes per platform for Apple
processing to become VALID. Both global build-number preflights run before either
upload. Polls filter and independently check the platform, marketing version and
build number: an accepted iOS build cannot stand in for the Mac build with the
same number.
It checks all pages of prior builds and rejects reused/lower build numbers.
Workflow uploads are serialized; avoid simultaneous manual Apple uploads.

After testing in TestFlight, select that same uploaded build in App Store Connect
for review; do not rebuild it. CI does not distribute to tester groups, submit
for App Review, or publish the App Store version.

The app footer displays `CI · <commit>` linking to its run. All app/extension
bundles contain the generated BuildIdentity.json. Local builds do not claim a
GitHub identity. Native language switching and WebKit UI checks are separate
local diagnostic utilities and are not claimed by this pipeline.

## Verify the evidence

Download the `build-evidence-<run>-<attempt>` artifact from the public run. It
contains the manifest, checksums and attestation bundles; successful signed runs
also retain the exact IPA, Mac TestFlight PKG and final notarized Mac ZIP. No Xcode archive, debug
symbols, standalone provisioning profile, raw build log or training input is an
uploaded artifact. The distribution apps contain their required embedded profiles. Public Actions console logs still show ordinary build output.

```sh
shasum -a 256 -c SHA256SUMS
gh attestation verify build-manifest.json --repo skar404/slowth \
  --signer-workflow skar404/slowth/.github/workflows/release-ci.yml \
  --source-digest EXPECTED_COMMIT_SHA --source-ref refs/heads/main \
  --deny-self-hosted-runners \
  --bundle manifest-attestation.jsonl
```

Compare the manifest's `commit`, `source_tree`, `run_url`, version and build with
the expected reviewed release and the app's version. Require the attestation's
source revision to match that expected commit. A valid attestation for some other
revision is not evidence for your chosen release. `kind=unsigned-validation`
means no Apple upload; `kind=testflight-upload` includes the IPA/PKG hashes and separate
Apple processing results in `app_store_connect` (IOS) and `macos_app_store_connect`
(MAC_OS). `macos_testflight` describes the uploaded PKG; `macos` describes the ZIP. The IPA also receives its own provenance attestation;
the release operator can verify a retained copy with:

```sh
gh attestation verify /path/to/Slowth.ipa --repo skar404/slowth \
  --signer-workflow skar404/slowth/.github/workflows/release-ci.yml \
  --source-digest EXPECTED_COMMIT_SHA --source-ref refs/heads/main \
  --deny-self-hosted-runners \
  --bundle ipa-attestation.jsonl
```

The retained IPA lets users independently hash the file uploaded to Apple.
For the Mac ZIP, use the same verification command with `Slowth-macOS.zip` and
`macos-attestation.jsonl`; for the TestFlight PKG, use `Slowth-macOS-TestFlight.pkg`
and `macos-store-attestation.jsonl`. For automatic version releases, first verify
`SHA256SUMS` with the same command and `--bundle checksums-attestation.jsonl`, using
the expected signed tag's commit as `--source-digest`; then run the checksum check.
Verify that the tag and commit carry the trusted GPG signature:

```sh
gpg --import scripts/release_tools/release-signing-key.asc
git verify-tag vYOUR_VERSION
git verify-commit 'vYOUR_VERSION^{commit}'
# Check the reported fingerprint against the trusted release key above.
```

For older releases/model releases with `SHA256SUMS.asc`, verify that GPG signature
before trusting the checksum file.
Attestations establish what the workflow produced, not the
absence of malicious source or a match to the post-processing App Store binary.
Review of the workflow and source remains necessary. Runtime rule updates are a
separate input and are not covered by an app binary's provenance.

Actions artifacts expire after 90 days. Tag-driven publication preserves the
allowlisted artifacts in the app-version GitHub Release after verification. Attestation APIs and public workflow logs provide additional context but
are not a substitute for retaining the evidence bundle.

## Failures and local validation

If publication fails after a tag was pushed, inspect that tag and any draft.
Never delete/rewrite the tag or use `--clobber` to replace assets. If only the
publication job failed and no draft exists, use **Re-run failed jobs**: it validates
and reuses evidence from the successful build attempt, without re-uploading to
Apple. If a draft exists, inspect and verify its assets before manual recovery;
automation deliberately refuses to overwrite a draft. Do not use **Re-run all jobs**
after Apple accepted a build. A build-stage failure can require a new version tag
and an increased build number; inspect Apple before deciding how to recover.

If Apple accepts an upload but processing or evidence publication fails, inspect
App Store Connect before trying again. An accepted upload consumes its build
number. A second-platform failure can leave only one platform processed; inspect
both platform records and never present partial success as a complete release. Never retry that upload number or claim evidence from a failed run.

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 scripts/release.py check
python3 scripts/release.py build \
  --model-bundle /path/to/Slowth-models.tar.gz \
  --output /tmp/slowth-ios-validation
```

The old shell release wrapper and standalone CI scripts were replaced by this
single CLI. Shared implementation is in `scripts/release_tools/`; do not invoke
those modules directly. Local builds never copy personal signing settings into
the unsigned build path.
