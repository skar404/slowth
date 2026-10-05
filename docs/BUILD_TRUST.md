# Build provenance and TestFlight

Use `python3 scripts/release.py` for every release operation. Model publication
and app uploads are separate commands; neither happens by default.

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
| `build --model-bundle FILE --output DIR` | Validates an unsigned iOS Release archive and creates a local manifest | None |
| `ci --model-release TAG` | Dispatches unsigned iOS validation on main | GitHub Actions run |
| `ci --model-release TAG --testflight` | Dispatches signed iOS build and Apple upload | Actions run and TestFlight build |

`build --testflight` is reserved for the GitHub workflow, not local use.
All output directories must be new. Local preparation can use modified public
sources; its manifest has `commit: null` and records `source_tree` instead.
Publishing and dispatching require the exact reviewed public snapshot already
committed and pushed to main. The tool does not stage or commit source for you.

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
or models. **Release evidence and TestFlight** runs manually on main or via the
`ci` command. Validation and TestFlight paths both build iOS only.

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

## Run an iOS build

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
that exact file, and waits up to 20 minutes for Apple processing to become VALID.
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
contains only the manifest, checksums and attestation bundles. No app archive,
IPA, debug symbols, provisioning profile, raw build log or training input is an
uploaded artifact. Public Actions console logs still show ordinary build output.

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
means no Apple upload; `kind=testflight-upload` includes the IPA's SHA-256 and
Apple's processed build ID. The IPA also receives its own provenance attestation;
the release operator can verify a retained copy with:

```sh
gh attestation verify /path/to/Slowth.ipa --repo skar404/slowth \
  --signer-workflow skar404/slowth/.github/workflows/release-ci.yml \
  --source-digest EXPECTED_COMMIT_SHA --source-ref refs/heads/main \
  --deny-self-hosted-runners \
  --bundle ipa-attestation.jsonl
```

The CI runner's IPA is intentionally not retained publicly. A user without that
IPA can verify the manifest's provenance, but cannot independently hash the
uploaded binary. Attestations establish what the workflow produced, not the
absence of malicious source or a match to the post-processing App Store binary.
Review of the workflow and source remains necessary. Runtime rule updates are a
separate input and are not covered by an app binary's provenance.

Actions artifacts expire after 90 days. For permanent public verification, copy
the four allowlisted evidence files to the corresponding GitHub Release after
review. Attestation APIs and public workflow logs provide additional context but
are not a substitute for retaining the evidence bundle.

## Failures and local validation

If model publication fails after the tag was pushed, inspect that tag and any
GitHub draft. Do not delete/rewrite tags or rerun blindly: existing tags and
output directories are intentionally rejected. Verify the draft against the
retained local signed assets before completing recovery; do not use `--clobber`
to replace published files. Failures before tag push never publish a release.

If Apple accepts an upload but processing or evidence publication fails, inspect
App Store Connect before trying again. An accepted upload consumes its build
number. Never retry that upload number or claim evidence from a failed run.

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
