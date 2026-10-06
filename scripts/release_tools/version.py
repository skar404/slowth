"""Promote a successful CI build to one immutable, signed app-version release."""
import json
from pathlib import Path
import re
import tempfile

from . import core, models

EVIDENCE = {'build-manifest.json', 'SHA256SUMS', 'manifest-attestation.jsonl',
            'ipa-attestation.jsonl', 'macos-attestation.jsonl', 'Unscroll.ipa', 'Slowth-macOS.zip',
            'Slowth-macOS-TestFlight.pkg', 'macos-store-attestation.jsonl'}
ASSETS = EVIDENCE | {models.ASSET, 'SHA256SUMS.asc'}


def release_tag(value):
    core.require(re.fullmatch(r'(?:models-[A-Za-z0-9][A-Za-z0-9._-]{0,100}|v[1-9]\d*\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))', value),
                 'Expected a model-input tag or an app version such as v2026.8.2')
    return value


def validate_run(run, head):
    core.require(run['status'] == 'completed' and run['conclusion'] == 'success', 'CI run must be successful')
    core.require(run['head_sha'] == head and run['head_branch'] == 'main'
                 and run['event'] == 'workflow_dispatch'
                 and run['path'] == '.github/workflows/release-ci.yml',
                 'CI must be the release workflow for the reviewed main commit')


def validate_evidence(output, repo, run_id, attempt, head, tree, version, build):
    core.require({p.name for p in output.iterdir()} == EVIDENCE, 'CI asset list differs; requires iOS and notarized macOS artifacts')
    core.require(all(p.is_file() and not p.is_symlink() for p in output.iterdir()), 'CI assets must be regular files')
    manifest = json.loads((output / 'build-manifest.json').read_text())
    expected = {'repository': repo, 'commit': head, 'source_tree': tree,
                'marketing_version': version, 'build_number': build, 'kind': 'testflight-upload',
                'run_url': f'https://github.com/{repo}/actions/runs/{run_id}/attempts/{attempt}',
                'model_packages': core.MODEL_HASHES, 'runtime_metadata_sha256': core.RUNTIME_HASH}
    core.require(all(manifest.get(k) == v for k, v in expected.items()), 'CI manifest identity or model pins differ')
    for platform, key in [('IOS', 'app_store_connect'), ('MAC_OS', 'macos_app_store_connect')]:
        apple = manifest[key]
        core.require(apple['processing_state'] == 'VALID' and apple['build_number'] == build
                     and apple['platform'] == platform and apple['marketing_version'] == version
                     and apple['app_store_published'] is False and apple['build_id'],
                     f'Apple {platform} build is not processed or its identity differs')
    core.require(manifest['platforms']['iOS']['code_signed'] is True
                 and manifest['platforms']['macOS']['code_signed'] is True
                 and manifest['macos']['notarization_status'] == 'Accepted', 'Both platforms must be distribution signed; macOS must be notarized')
    for name, record in [('Unscroll.ipa', manifest['ipa']), ('Slowth-macOS.zip', manifest['macos']),
                         ('Slowth-macOS-TestFlight.pkg', manifest['macos_testflight'])]:
        core.require(record['name'] == name and core.sha(output / name) == record['sha256'], f'Artifact differs: {name}')
    for name, attestation in [('build-manifest.json', 'manifest'), ('Unscroll.ipa', 'ipa'), ('Slowth-macOS.zip', 'macos'),
                              ('Slowth-macOS-TestFlight.pkg', 'macos-store')]:
        core.run('gh', 'attestation', 'verify', output / name, '--repo', repo,
                 '--signer-workflow', f'{repo}/.github/workflows/release-ci.yml',
                 '--source-digest', head, '--source-ref', 'refs/heads/main', '--deny-self-hosted-runners',
                 '--bundle', output / f'{attestation}-attestation.jsonl')
    return manifest


def publish(output, repo, tag, head, tree, fingerprint):
    with tempfile.TemporaryDirectory(prefix='slowth-version-check-') as temp:
        _, current_head, current_tree = core.snapshot(core.ROOT, Path(temp))
        core.require((current_head, current_tree) == (head, tree), 'Source changed during preparation')
    core.require(core.origin_repo(core.ROOT) == repo, 'origin changed during preparation')
    core.remote_preflight(core.ROOT, head, tag)
    core.git('-c', 'gpg.format=openpgp', '-c', 'gpg.program=gpg', 'tag', '-s', '-u', fingerprint,
             tag, head, '-m', f'Slowth {tag}\n\nSHA256SUMS SHA-256: {core.sha(output / "SHA256SUMS")}')
    core.verify_signature(core.ROOT, 'tag', tag, fingerprint)
    core.require(core.git('rev-parse', f'{tag}^{{commit}}', capture=True).decode().strip() == head, 'Tag source differs')
    core.git('-c', 'push.followTags=false', 'push', 'origin', f'refs/tags/{tag}:refs/tags/{tag}')
    try:
        core.run('gh', 'release', 'create', tag, *(output / name for name in sorted(ASSETS)),
                 '--repo', repo, '--verify-tag', '--draft', '--title', f'Slowth {tag}',
                 '--notes-file', output / 'release-notes.md')
        with tempfile.TemporaryDirectory(prefix='slowth-version-download-') as temp:
            downloaded = Path(temp)
            core.run('gh', 'release', 'download', tag, '--repo', repo, '--dir', downloaded)
            core.require({p.name for p in downloaded.iterdir()} == ASSETS, 'Uploaded asset list differs')
            for name in ASSETS:
                core.require((downloaded / name).is_file() and not (downloaded / name).is_symlink()
                             and core.sha(downloaded / name) == core.sha(output / name), f'Uploaded checksum mismatch: {name}')
        core.run('gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest')
        result = json.loads(core.run('gh', 'release', 'view', tag, '--repo', repo,
                                     '--json', 'url,isDraft,tagName,assets', capture=True))
        core.require(not result['isDraft'] and result['tagName'] == tag
                     and {a['name'] for a in result['assets']} == ASSETS, 'Published release verification failed')
        print(f'Published {result["url"]}')
    except Exception:
        print(f'Tag {tag} has been pushed. Inspect the tag/draft before recovery; do not overwrite or rerun blindly.')
        raise


def prepare(args):
    core.require(re.fullmatch(r'[1-9]\d*', args.run), '--run must be a numeric workflow run ID')
    release_tag(args.model_release)
    core.require(not args.publish or args.gpg_key, '--publish requires --gpg-key or RELEASE_GPG_KEY')
    with tempfile.TemporaryDirectory(prefix='slowth-version-') as temp:
        source, head, tree = core.snapshot(core.ROOT, Path(temp))
        repo = models.published_source(head, tree)
        app_version, build, _ = core.versions(source)
        tag = release_tag(f'v{app_version}')
        output = (args.output or core.ROOT / 'release-output' / tag).resolve()
        core.require(not output.exists(), 'Output already exists; choose a new directory')
        core.remote_preflight(core.ROOT, head, tag)
        fingerprint = None
        if args.publish:
            fingerprint = core.signing_key(args.gpg_key)
            core.verify_signature(core.ROOT, 'commit', head, fingerprint)
        run = json.loads(core.run('gh', 'api', f'repos/{repo}/actions/runs/{args.run}', capture=True))
        validate_run(run, head)
        attempt = str(run['run_attempt'])
        core.require(attempt.isdigit(), 'Invalid run attempt')
        output.mkdir(parents=True)
        core.run('gh', 'run', 'download', args.run, '--repo', repo,
                 '--name', f'build-evidence-{args.run}-{attempt}', '--dir', output)
        manifest = validate_evidence(output, repo, args.run, attempt, head, tree, app_version, build)
        core.run('gh', 'release', 'download', args.model_release, '--repo', repo,
                 '--pattern', models.ASSET, '--output', output / models.ASSET)
        core.require(core.sha(output / models.ASSET) == manifest['model_bundle_sha256'], 'Model archive differs from CI input')
        core.install_models(source, core.ROOT, output / models.ASSET)
        notes = (args.notes.read_text() if args.notes else
                 f'Slowth {app_version} (build {build})\n\n'
                 f'Built from `{head}` in [GitHub Actions]({manifest["run_url"]}).\n\n'
                 '- macOS: download `Slowth-macOS.zip`, extract and move Slowth.app to Applications. '
                 'Signed with Developer ID and notarized by Apple. Requires macOS 13 or later.\n'
                 '- iOS: `Unscroll.ipa` is the exact signed file uploaded to TestFlight, included for verification. '
                 'Install through TestFlight or the App Store; this App Store-signed IPA is not a direct installation package. '
                 'Requires iOS/iPadOS 16 or later. App Store publication is a separate step.\n'
                 '- macOS TestFlight: `Slowth-macOS-TestFlight.pkg` is the separate App Store-signed package uploaded to Apple, retained for verification. Use the ZIP for direct installation.\n'
                 '- Pinned Core ML model inputs, build manifest, GitHub attestations and GPG-signed SHA-256 checksums.\n\n'
                 'Verify the checksum signature with the trusted release key, then run `shasum -a 256 -c SHA256SUMS`. '
                 'See docs/BUILD_TRUST.md at this tag for attestation verification. '
                 'Provenance links these artifacts to this CI run; it does not prove byte-for-byte equality with an App Store download.\n')
        core.require(notes.strip(), 'Release notes must not be empty')
        core.check_contents('release-notes.md', notes.encode())
        (output / 'release-notes.md').write_text(notes)
        core.checksums(output, [output / name for name in sorted(ASSETS - {'SHA256SUMS', 'SHA256SUMS.asc'})])
        if args.publish:
            models.sign_checksums(output, fingerprint)
            publish(output, repo, tag, head, tree, fingerprint)
        else:
            print('Prepared locally. No tag or GitHub Release created; no rebuild or Apple upload.')
        print(f'Version assets and notes: {output}')
