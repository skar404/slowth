"""Signed tag -> protected main build -> verified GitHub Release. No private GPG key in CI."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

from . import core, models, version

FINGERPRINT = '68BEAF78936945EC66B7C5273E8FD639DD4791CC'
MODEL_RELEASE = 'models-v10-1'
MODEL_SHA256 = '511ce9f961635a662f2a4e223ad07c6ea9e4e52c6567fec21472a0d24ce00485'
ASSETS = version.EVIDENCE | {models.ASSET, 'checksums-attestation.jsonl'}


def app_tag(tag):
    core.require(re.fullmatch(r'v[1-9]\d*\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)', tag),
                 'Expected an app tag such as v2026.8.3, without leading zeros')
    return tag


def source_version():
    """Early portable gate; the build also validates every expanded XcodeGen target."""
    marketing = json.loads((core.ROOT / 'WebExt/manifest.json').read_text())['version']
    spec = (core.ROOT / 'project.yml').read_text()
    versions = re.findall(r'^\s+MARKETING_VERSION:\s*[\"\']?([\d.]+)[\"\']?\s*$', spec, re.M)
    builds = re.findall(r'^\s+CURRENT_PROJECT_VERSION:\s*[\"\']?(\d+)[\"\']?\s*$', spec, re.M)
    core.require(versions and set(versions) == {marketing} and builds and len(set(builds)) == 1,
                 'Source version/build settings differ')
    core.require(f'Slowth v{marketing}</div>' in (core.ROOT / 'WebExt/app.html').read_text(),
                 'Visible version label differs')
    app_tag('v' + marketing)
    return marketing, builds[0]


@contextmanager
def public_keyring():
    with tempfile.TemporaryDirectory(prefix='slowth-public-key-') as temp:
        previous = os.environ.get('GNUPGHOME')
        os.environ['GNUPGHOME'] = temp
        try:
            core.run('gpg', '--batch', '--no-autostart', '--import',
                     core.ROOT / 'scripts/release_tools/release-signing-key.asc', capture=True)
            yield
        finally:
            if previous is None:
                os.environ.pop('GNUPGHOME', None)
            else:
                os.environ['GNUPGHOME'] = previous


def verify_tag(tag, *, tip=True):
    app_tag(tag)
    head = core.git('rev-parse', 'HEAD', capture=True).decode().strip()
    repo = core.origin_repo(core.ROOT)
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        core.require(os.environ.get('GITHUB_REPOSITORY') == repo and os.environ.get('GITHUB_SHA') == head,
                     'Actions repository/source differs')
    core.git('fetch', '--no-tags', 'origin', 'refs/heads/main:refs/remotes/origin/main',
             f'refs/tags/{tag}:refs/tags/{tag}')
    ref = f'refs/tags/{tag}'
    core.require(core.git('cat-file', '-t', ref, capture=True).strip() == b'tag',
                 'An annotated, GPG-signed tag is required')
    core.require(core.git('rev-parse', f'{ref}^{{commit}}', capture=True).decode().strip() == head,
                 'Tag must point to this exact commit; main moved before dispatch')
    obj = core.git('rev-parse', ref, capture=True).decode().strip()
    remote = core.git('ls-remote', '--refs', 'origin', ref, capture=True).decode().splitlines()
    core.require(remote == [f'{obj}\t{ref}'], 'Remote tag changed')
    if tip:
        core.require(core.git('rev-parse', 'origin/main', capture=True).decode().strip() == head,
                     'Release tag must point to the current main commit')
    else:
        core.git('merge-base', '--is-ancestor', head, 'origin/main')
    core.git('diff', '--exit-code', 'HEAD', '--')
    with public_keyring():
        core.verify_signature(core.ROOT, 'tag', ref, FINGERPRINT)
        core.verify_signature(core.ROOT, 'commit', head, FINGERPRINT)
    marketing, build = source_version()
    core.require(tag == f'v{marketing}', 'Tag does not match MARKETING_VERSION')
    return repo, head, marketing, build


def absent_release(repo, tag):
    pages = json.loads(core.run('gh', 'api', '--paginate', '--slurp',
                               f'repos/{repo}/releases?per_page=100', capture=True))
    core.require(not any(r['tag_name'] == tag for page in pages for r in page),
                 'Release or draft already exists; inspect it instead of overwriting')


def tag(args):
    """Explicit local signing; versions and the committed source are never changed."""
    with tempfile.TemporaryDirectory(prefix='slowth-tag-') as temp:
        source, head, tree = core.snapshot(core.ROOT, Path(temp))
        models.published_source(head, tree)
        marketing, _, _ = core.versions(source)
        name = app_tag(f'v{marketing}')
        core.remote_preflight(core.ROOT, head, name)
        fingerprint = core.signing_key(args.gpg_key)
        core.require(fingerprint == FINGERPRINT, 'Key differs from the configured release signer')
        core.verify_signature(core.ROOT, 'commit', head, fingerprint)
        core.git('-c', 'gpg.format=openpgp', '-c', 'gpg.program=gpg', 'tag', '-s', '-u', fingerprint,
                 name, head, '-m', f'Slowth {name}')
        core.verify_signature(core.ROOT, 'tag', name, fingerprint)
        core.git('-c', 'push.followTags=false', 'push', 'origin', f'refs/tags/{name}:refs/tags/{name}')
        print(f'Pushed {name}. Follow release-tag, then release-ci in GitHub Actions; publication waits for verification.')


def dispatch(tag):
    repo, _, _, _ = verify_tag(tag)
    absent_release(repo, tag)
    core.run('gh', 'workflow', 'run', 'release-ci.yml', '--repo', repo, '--ref', 'main',
             '-f', f'release_tag={tag}', '-f', f'model_release={MODEL_RELEASE}',
             '-f', f'model_asset={models.ASSET}', '-f', 'testflight=true')
    print(f'Dispatched protected main build for {tag}')


def check(tag):
    core.require(os.environ.get('GITHUB_REF') == 'refs/heads/main', 'Protected build requires main')
    repo, _, _, _ = verify_tag(tag)
    absent_release(repo, tag)
    core.require(os.environ.get('TESTFLIGHT') == 'true' and os.environ.get('MODEL_RELEASE') == MODEL_RELEASE
                 and os.environ.get('MODEL_ASSET') == models.ASSET, 'Tag build inputs differ from pinned configuration')


def run_context():
    core.require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REF') == 'refs/heads/main',
                 'Automatic publication is reserved for the protected main workflow')
    run_id = os.environ.get('GITHUB_RUN_ID', '')
    core.require(re.fullmatch(r'[1-9]\d*', run_id), 'Missing Actions run ID')
    return run_id


def successful_build(repo, run_id, head):
    run = json.loads(core.run('gh', 'api', f'repos/{repo}/actions/runs/{run_id}', capture=True))
    core.require(run['head_sha'] == head and run['head_branch'] == 'main'
                 and run['event'] == 'workflow_dispatch' and run['path'] == '.github/workflows/release-ci.yml',
                 'Unexpected publication workflow/source')
    # A failed-job retry may publish artifacts from the successful build in an earlier attempt.
    pages = json.loads(core.run('gh', 'api', '--paginate', '--slurp',
                               f'repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100', capture=True))
    candidates = []
    for page in pages:
        for artifact in page['artifacts']:
            match = re.fullmatch(rf'build-evidence-{run_id}-([1-9]\d*)', artifact['name'])
            if match and not artifact['expired']:
                candidates.append(int(match[1]))
    core.require(candidates, 'No retained build evidence')
    attempt = str(max(candidates))
    pages = json.loads(core.run('gh', 'api', '--paginate', '--slurp',
                               f'repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100', capture=True))
    jobs = [j for page in pages for j in page['jobs'] if j['name'] == 'build']
    core.require(len(jobs) == 1 and jobs[0]['conclusion'] == 'success', 'Build job did not succeed')
    return attempt


def prepare(tag, output):
    run_id = run_context()
    repo, head, marketing, build = verify_tag(tag, tip=False)
    absent_release(repo, tag)
    attempt = successful_build(repo, run_id, head)
    core.require(not output.exists(), 'Publication directory already exists')
    output.mkdir(parents=True)
    core.run('gh', 'run', 'download', run_id, '--repo', repo,
             '--name', f'build-evidence-{run_id}-{attempt}', '--dir', output)
    tree = core.git('rev-parse', 'HEAD^{tree}', capture=True).decode().strip()
    manifest = version.validate_evidence(output, repo, run_id, attempt, head, tree, marketing, build)
    core.run('gh', 'release', 'download', MODEL_RELEASE, '--repo', repo, '--pattern', models.ASSET,
             '--output', output / models.ASSET)
    core.require(core.sha(output / models.ASSET) == manifest['model_bundle_sha256'] == MODEL_SHA256,
                 'Model archive differs from pinned CI input')
    # Strict importer checks archive paths and individual model identities without changing the checkout.
    with tempfile.TemporaryDirectory(prefix='slowth-model-verification-') as temp:
        source = Path(temp)
        for name in (core.RUNTIME, 'RealtimeShield/CascadePolicy.swift'):
            dest = source / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(core.ROOT / name, dest)
        core.install_models(source, core.ROOT, output / models.ASSET)
    notes = (f'Slowth {marketing} (build {build})\n\n'
             f'Signed source tag: `{tag}`. Commit: `{head}`. [Build and verification]({manifest["run_url"]}).\n\n'
             '- macOS: download `Slowth-macOS.zip`, extract and move Slowth.app to Applications. '
             'Universal app, Developer ID signed and notarized. Requires macOS 13 or later.\n'
             '- iOS/iPadOS 16+: use TestFlight or the App Store. `Unscroll.ipa` is the exact uploaded IPA for verification.\n'
             '- `Slowth-macOS-TestFlight.pkg` is the exact Mac App Store package uploaded to TestFlight, for verification. '
             'Use the ZIP for direct installation. Both uploads processed successfully; App Store publication is separate.\n'
             '- Includes pinned model inputs, build manifest, SHA-256 checksums and five GitHub provenance bundles. '
             'Model qualification is unchanged.\n\n'
             'Verify the signed Git tag and the GitHub attestation for SHA256SUMS, then check all file hashes. '
             'See docs/BUILD_TRUST.md at this tag. CI uses keyless GitHub signatures; there is no personal GPG checksum '
             'signature. Provenance is not proof of byte-for-byte equality with the App Store download.\n')
    core.check_contents('release-notes.md', notes.encode())
    (output / 'release-notes.md').write_text(notes)
    core.checksums(output, [output / name for name in sorted(ASSETS - {'SHA256SUMS', 'checksums-attestation.jsonl'})])


def publish_assets(output, repo, tag):
    """Never overwrite; public visibility comes only after downloading and verifying every asset."""
    core.require({p.name for p in output.iterdir()} == ASSETS | {'release-notes.md'}, 'Unexpected publication files')
    core.require(all(p.is_file() and not p.is_symlink() for p in output.iterdir()), 'Assets must be regular files')
    core.run('gh', 'release', 'create', tag, *(output / name for name in sorted(ASSETS)),
             '--repo', repo, '--verify-tag', '--draft', '--title', f'Slowth {tag}',
             '--notes-file', output / 'release-notes.md')
    with tempfile.TemporaryDirectory(prefix='slowth-published-download-') as temp:
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


def publish(tag, output):
    run_context()
    repo, head, _, _ = verify_tag(tag, tip=False)
    absent_release(repo, tag)
    core.run('gh', 'attestation', 'verify', output / 'SHA256SUMS', '--repo', repo,
             '--signer-workflow', f'{repo}/.github/workflows/release-ci.yml',
             '--source-digest', head, '--source-ref', 'refs/heads/main', '--deny-self-hosted-runners',
             '--bundle', output / 'checksums-attestation.jsonl')
    core.run('shasum', '-a', '256', '-c', 'SHA256SUMS', cwd=output)
    publish_assets(output, repo, tag)
