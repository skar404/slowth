#!/usr/bin/env python3
"""Derive small Release resources without modifying frozen training exports.

Run after intentionally changing the selected model or the shared iOS Info.plist.
Use --check in validation to detect stale generated resources.
"""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'data-model/exports/v15-v6-app-20260920-154340/ios-resources/CascadeV6Metadata.json'
SOURCE_SHA256 = 'ac60c10e4bc7f0091b51bd86195b5597ccb78e6c7af3a5b15911f70981cdf404'
RUNTIME_SHA256 = 'b56dfc94cecd8f6165c3a94bc3781fb76cff98df87516a40bc09577887e4fcbd'


def resources(runtime_only=False):
    if runtime_only:
        compact = (ROOT / 'RealtimeShield/CascadeV6RuntimeMetadata.json').read_bytes()
    else:
        source = SOURCE.read_bytes()
        if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
            raise ValueError('Frozen Cascade V6 metadata identity changed')
        metadata = json.loads(source)
        # Keep policy, model identities and qualification; never publish training
        # inventory or developer filesystem paths in the app or model asset.
        del metadata['calibration_inventory']
        for component in metadata['components'].values():
            component.pop('source_checkpoint', None)
        compact = (json.dumps(metadata, sort_keys=True, separators=(',', ':')) + '\n').encode()
    if hashlib.sha256(compact).hexdigest() != RUNTIME_SHA256:
        raise ValueError('Runtime metadata identity changed')
    info = plistlib.loads((ROOT / 'iOS/Info.plist').read_bytes())
    del info['NSPhotoLibraryAddUsageDescription']
    del info['NSPhotoLibraryUsageDescription']
    return {
        ROOT / 'RealtimeShield/CascadeV6RuntimeMetadata.json': compact,
        ROOT / 'iOS/Info-Release.plist': plistlib.dumps(info, sort_keys=False),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--runtime-only', action='store_true',
                        help='Verify public runtime resources without private training exports')
    args = parser.parse_args()
    for path, data in resources(args.runtime_only).items():
        if args.check:
            if not path.exists() or path.read_bytes() != data:
                raise SystemExit(f'Stale resource: {path.relative_to(ROOT)}')
        else:
            path.write_bytes(data)
        print(f'{path.relative_to(ROOT)}: {len(data)} bytes, sha256={hashlib.sha256(data).hexdigest()}')


if __name__ == '__main__':
    main()
