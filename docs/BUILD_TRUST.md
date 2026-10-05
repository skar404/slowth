# Build provenance and TestFlight

Slowth's CI links a public source commit, pinned production model inputs, a build
run, and (for TestFlight runs) the exact IPA sent to Apple. It does **not** prove
that an App Store download is byte-for-byte identical to that IPA: Apple processes
and thins downloads. A commit label displayed by the app is an identifier, not an
independent cryptographic verification.

## Workflows

- **Source checks** runs on pull requests and main. It validates the public
  snapshot, synchronized versions, generated runtime metadata, release automation
  tests and WebExtension tests. It needs no models or Apple credentials.
- **Release evidence and TestFlight** is manually dispatched on main. With
  `testflight=false`, it validates unsigned Release archives for iOS and macOS.
  With `testflight=true`, it signs, exports, checks and uploads one iOS IPA, then
  waits up to 20 minutes for Apple processing to become `VALID`. It does not
  distribute to tester groups, submit for review, or publish to the App Store.

The workflows pin their actions by commit, Python 3.12.9, Node 22.14.0, XcodeGen
2.46.0 (including its downloaded SHA-256), and Xcode 26.2 / 17C52. They use the
`macos-26` hosted runner, whose image changes over time; its version is recorded
in the manifest. If the pinned Xcode disappears, update and review the pin rather
than falling back to the runner's default. These controls provide traceability,
not a fully hermetic or byte-for-byte reproducible build.

Release archive checks include all host/extension version numbers and embedded
build identities, expected model weights and runtime metadata, absence of Debug
capture code and Photos permissions, and compiled native/WebExtension catalogs.
The signed path also checks the exported IPA's identities, resources and code
signature before uploading that exact file with `altool`. Existing native language
switching and WebKit UI checks in `scripts/release.sh build` remain separate local
release checks; the CI manifest does not claim to run them.

## Initial setup

1. Review and publish the source changes, including the two explicitly allowlisted
   `.github/workflows/` files. The existing signed-public-release workflow remains
   responsible for publishing public source snapshots and model assets. Do not
   stage the private worktree wholesale.
2. Supply a public production-model release asset. The current V10 code will reject
   old V6 assets. Prepare just the approved model files locally:

   ```sh
   python3 scripts/ci_release.py models --output release-output/ci-models-v10
   ```

   This creates `Slowth-models.tar.gz` and `SHA256SUMS`, validates all pinned package
   hashes, and round-trips the safe importer. Review and attach these files to an
   appropriate GitHub Release through the normal publication process. Do not
   upload the private export directory. CI takes the release tag and exact asset
   name as inputs; regardless of the chosen release, every model file must match
   the identities pinned in the checked-out source.
3. Create the GitHub environment **app-store**, restricted to main. Configure
   required reviewers and prevent self-review where available. Keep Apple secrets
   in this environment, not at repository scope. Protect main with reviews and
   the **Source checks / check** required check; include workflow/script changes
   in code review. The environment **ci-validation** needs no secrets.
4. Add these environment variables and secrets through GitHub Settings →
   Environments → app-store. Do not paste their values into source, issues or CI
   inputs.

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

## Run a release

1. Resolve all source-check failures. Increment every `CURRENT_PROJECT_VERSION`
   for a new Apple upload, including replacement builds. Use one counter across
   iOS and macOS. Keep the `year.month.index` marketing version synchronized with
   the WebExtension and UI, and regenerate the Xcode project. CI does not bump
   versions and disables Xcode's automatic renumbering during export.
2. Publish the reviewed source on main. Run **Release evidence and TestFlight**
   with `testflight=false` first, specifying the model release tag and filename.
3. Run with `testflight=true` when the intended upload version/build is committed.
   Before building, the workflow checks the App Store app's bundle ID and walks
   **all pages** of uploaded builds for that app. The new integer build number
   must exceed the maximum returned, across both platforms. Builds not yet visible
   in this API remain the release operator's responsibility; avoid simultaneous
   manual uploads. Workflow runs themselves are serialized.
4. Test the processed build in TestFlight. In App Store Connect, select **that
   same uploaded build** for App Store review. Do not rebuild after testing.
5. Preserve the evidence files with the public release, and record which
   `app_store_connect.build_id` was selected for the published App Store version.
   The workflow records processing success, not an App Store publication claim.

The app footer displays `CI · <commit>` linking to the run when built by this
workflow. Local builds without CI identity keep the usual version label. Both the
app and its extensions contain the generated `BuildIdentity.json`; the build
verifies its contents before export and again inside the IPA.

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

If upload succeeds but Apple processing times out, inspect App Store Connect
before retrying. An accepted upload consumes the build number even if a later
attestation/upload-artifact step fails. Do not rerun the build with the same
number or claim that a failed run published verified evidence. No manifest is
published unless all required build/upload checks pass.

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 scripts/ci_release.py check
python3 scripts/ci_release.py build \
  --model-bundle release-output/ci-models-v10/Slowth-models.tar.gz \
  --output /tmp/slowth-ci-validation
```

Output directories must be new. Local builds can use a modified public snapshot;
their manifest uses `commit: null` when it differs from HEAD and never claims a
GitHub run. Official CI requires the source tree to match the exact workflow
commit. Local signing settings are not copied into this CI build path.

References: [GitHub artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations),
[Apple signing on GitHub runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
[choosing the App Store build](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit/).
