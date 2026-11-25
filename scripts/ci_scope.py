#!/usr/bin/env python3
"""Classify changed paths conservatively before selecting required CI jobs."""
import argparse
import re
import subprocess

WEBSITE_FILES = {
    'scripts/render_slowth.py', 'scripts/check_slowth.py',
    'scripts/check_slowth_live.py', 'scripts/test_slowth_seo.py',
    'scripts/render_privacy.py', '.github/workflows/website.yml',
}


def classify(diff, event):
    """Read git --name-status -z --no-renames; unknown/empty input requires full CI."""
    result = {'readme_only': False, 'website_only': False}
    if event not in {'pull_request', 'push'} or not diff:
        return result
    fields = diff.split(b'\0')
    if fields[-1] != b'' or (len(fields) - 1) % 2:
        return result
    entries = list(zip(fields[:-1:2], fields[1:-1:2]))
    if any(status not in {b'A', b'M', b'D'} for status, _ in entries):
        return result
    if event == 'pull_request' and entries == [(b'M', b'README.md')]:
        result['readme_only'] = True
    paths = [path.decode('utf-8', errors='surrogateescape') for _, path in entries]
    result['website_only'] = all(path.startswith('website/') or path in WEBSITE_FILES for path in paths)
    return result


def detect(event, base, head):
    if event not in {'pull_request', 'push'} or not all(
        re.fullmatch(r'[0-9a-fA-F]{40}', ref or '') and set(ref) != {'0'} for ref in [base, head]
    ):
        return classify(b'', event)
    # PRs use their merge base; pushes inspect everything changed by that push.
    revision = base + ('...' if event == 'pull_request' else '..') + head
    result = subprocess.run(['git', 'diff', '--name-status', '-z', '--no-renames', revision, '--'],
                            capture_output=True, check=False)
    return classify(result.stdout if result.returncode == 0 else b'', event)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--event', required=True)
    parser.add_argument('--base', default='')
    parser.add_argument('--head', default='')
    args = parser.parse_args()
    for key, value in detect(args.event, args.base, args.head).items():
        print(f'{key}={str(value).lower()}')


if __name__ == '__main__':
    main()
