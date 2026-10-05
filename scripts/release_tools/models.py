"""Publish only pinned model assets, without rebuilding or uploading the app."""
import json
from pathlib import Path
import re
import tempfile

from . import core
from .build import check_source

ASSET = 'Slowth-models.tar.gz'
ASSETS = {ASSET, 'model-manifest.json', 'SHA256SUMS', 'SHA256SUMS.asc'}


def model_tag(tag):
    core.require(re.fullmatch(r'models-[A-Za-z0-9][A-Za-z0-9._-]{0,100}', tag),
                 'Use a new model tag such as models-v10-1')
    return tag


def published_source(head, tree):
    core.require(tree == core.git('rev-parse', f'{head}^{{tree}}', capture=True).decode().strip(),
                 'Commit and push the reviewed public changes before publishing or running CI')
    core.require(core.git('branch', '--show-current', capture=True).decode().strip() == 'main',
                 'Release requires main')
    repo = core.origin_repo(core.ROOT)
    refs = core.git('ls-remote', '--refs', 'origin', 'refs/heads/main', capture=True).decode().splitlines()
    core.require(refs == [f'{head}\trefs/heads/main'], 'Push the reviewed commit to origin/main first')
    return repo


def sign_checksums(output, fingerprint):
    signature = output / 'SHA256SUMS.asc'
    core.run('gpg', '--batch', '--armor', '--local-user', fingerprint, '--detach-sign',
             '--output', signature, output / 'SHA256SUMS')
    status = core.run('gpg', '--batch', '--status-fd', '1', '--verify', signature,
                      output / 'SHA256SUMS', capture=True).decode().splitlines()
    valid = [line.split() for line in status if line.startswith('[GNUPG:] VALIDSIG ')]
    core.require(any(fingerprint in (row[2], row[-1]) for row in valid), 'Checksum signer differs')


def verify_download(output, download):
    core.require({p.name for p in download.iterdir()} == ASSETS, 'Uploaded asset list differs')
    for name in sorted(ASSETS):
        path = download / name
        core.require(path.is_file() and not path.is_symlink() and core.sha(path) == core.sha(output / name),
                     f'Uploaded checksum mismatch: {name}')


def publish(output, repo, tag, head, tree, fingerprint):
    # Recheck the reviewed source and remote before the first remote mutation.
    with tempfile.TemporaryDirectory(prefix='slowth-publish-check-') as temp:
        _, latest_head, latest_tree = core.snapshot(core.ROOT, Path(temp))
        core.require((latest_head, latest_tree) == (head, tree), 'Source changed during release preparation')
    core.require(core.origin_repo(core.ROOT) == repo, 'origin changed during preparation')
    core.remote_preflight(core.ROOT, head, tag)
    core.git('-c', 'gpg.format=openpgp', '-c', 'gpg.program=gpg', 'tag', '-s', '-u', fingerprint,
             tag, head, '-m', f'Models {tag}\n\nSHA256SUMS SHA-256: {core.sha(output / "SHA256SUMS")}')
    core.verify_signature(core.ROOT, 'tag', tag, fingerprint)
    core.require(core.git('rev-parse', f'{tag}^{{commit}}', capture=True).decode().strip() == head,
                 'Tag source differs')
    core.git('-c', 'push.followTags=false', 'push', 'origin', f'refs/tags/{tag}:refs/tags/{tag}')
    # If any later operation fails, keep the tag/draft for inspection; never overwrite or retry it automatically.
    try:
        core.run('gh', 'release', 'create', tag, *(output / name for name in sorted(ASSETS)),
                 '--repo', repo, '--verify-tag', '--draft', '--latest=false',
                 '--title', f'Slowth models {tag}', '--notes-file', output / 'release-notes.md')
        with tempfile.TemporaryDirectory(prefix='slowth-release-download-') as temp:
            download = Path(temp)
            core.run('gh', 'release', 'download', tag, '--repo', repo, '--dir', download)
            verify_download(output, download)
        core.run('gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest=false')
        result = json.loads(core.run('gh', 'release', 'view', tag, '--repo', repo,
                                     '--json', 'url,isDraft,tagName,assets', capture=True))
        core.require(not result['isDraft'] and result['tagName'] == tag
                     and {a['name'] for a in result['assets']} == ASSETS, 'Published release verification failed')
        print(f'Published {result["url"]}')
    except Exception:
        print(f'Tag {tag} has been pushed. Inspect that tag and any GitHub draft before recovery; do not rerun blindly.')
        raise


def prepare(args):
    tag = model_tag(args.tag)
    core.require(not args.publish or args.gpg_key, '--publish requires --gpg-key or RELEASE_GPG_KEY')
    output = (args.output or core.ROOT / 'release-output' / tag).resolve()
    core.require(not output.exists(), 'Output already exists; choose a new directory')
    with tempfile.TemporaryDirectory(prefix='slowth-model-release-') as temp:
        source, head, tree = core.snapshot(core.ROOT, Path(temp))
        repo = fingerprint = None
        if args.publish:
            repo = published_source(head, tree)
            core.remote_preflight(core.ROOT, head, tag)
            fingerprint = core.signing_key(args.gpg_key)
            core.verify_signature(core.ROOT, 'commit', head, fingerprint)
            core.run('gh', 'auth', 'status')
        check_source(source)
        core.install_models(source, core.ROOT, args.model_bundle.resolve() if args.model_bundle else None)
        output.mkdir(parents=True)
        bundle = output / ASSET
        core.model_bundle(source, bundle)
        core.install_models(source, core.ROOT, bundle)
        committed = tree == core.git('rev-parse', f'{head}^{{tree}}', capture=True).decode().strip()
        manifest = {'schema_version': 1, 'kind': 'production-model-inputs', 'tag': tag,
                    'commit': head if committed else None, 'source_tree': tree,
                    'model_bundle_sha256': core.sha(bundle), 'model_packages': core.MODEL_HASHES,
                    'runtime_metadata_sha256': core.RUNTIME_HASH,
                    'package_hash_algorithm': 'SHA256 of sorted relative UTF-8 file paths, NUL, file bytes',
                    'note': 'Pinned inference inputs only. No app build or Apple upload. Model qualification is unchanged.'}
        manifest_path = output / 'model-manifest.json'
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        notes = (args.notes.read_text() if args.notes else
                 f'# Slowth model inputs: {tag}\n\n'
                 f'Source commit: `{head}`' + (' (local changes; see source_tree in manifest).' if not committed else '.') +
                 '\n\nFive pinned Cascade V10 Core ML packages and compact runtime metadata. '
                 'Training sources, datasets, checkpoints, calibration inventories and credentials are excluded. '
                 'Model qualification is unchanged. No app was uploaded to Apple.\n\n'
                 'Verify SHA256SUMS.asc with the trusted release signing key, then run '
                 '`shasum -a 256 -c SHA256SUMS`. See docs/BUILD_TRUST.md at the source commit for rebuilding.\n')
        core.require(notes.strip(), 'Release notes must not be empty')
        core.check_contents('model-manifest.json', manifest_path.read_bytes())
        core.check_contents('release notes', notes.encode())
        (output / 'release-notes.md').write_text(notes)
        core.checksums(output, [bundle, manifest_path])
        if args.publish:
            sign_checksums(output, fingerprint)
            publish(output, repo, tag, head, tree, fingerprint)
        else:
            print('Prepared locally; no tag, signature, push or GitHub Release was created.')
        print(f'Model assets and notes: {output}')


def dispatch(tag, testflight):
    model_tag(tag)
    with tempfile.TemporaryDirectory(prefix='slowth-ci-dispatch-') as temp:
        root = Path(temp)
        source, head, tree = core.snapshot(core.ROOT, root)
        repo = published_source(head, tree)
        info = json.loads(core.run('gh', 'release', 'view', tag, '--repo', repo,
                                   '--json', 'isDraft,tagName,assets', capture=True))
        core.require(not info['isDraft'] and info['tagName'] == tag
                     and ASSET in {a['name'] for a in info['assets']}, 'Published model asset is required')
        bundle = root / ASSET
        core.run('gh', 'release', 'download', tag, '--repo', repo, '--pattern', ASSET, '--output', bundle)
        core.install_models(source, core.ROOT, bundle)
        # main is resolved by GitHub at dispatch time. The run records its exact SHA;
        # callers must check it before selecting an uploaded build for release.
        published_source(head, tree)
        core.run('gh', 'workflow', 'run', 'release-ci.yml', '--repo', repo, '--ref', 'main',
                 '-f', f'model_release={tag}', '-f', f'model_asset={ASSET}',
                 '-f', f'testflight={str(testflight).lower()}')
        print(f'Workflow dispatched (requested source {head}): https://github.com/{repo}/actions/workflows/release-ci.yml')
        print('Check the run commit and result. Dispatch alone does not mean the build or upload succeeded.')
