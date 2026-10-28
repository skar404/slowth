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
SOURCE = ROOT / 'data-model/exports/cascade-v10-study-20260929-1356/diverse/ios-resources/CascadeV10Metadata.json'
SOURCE_SHA256 = 'f7fd1ae118afadc139c3e95b4e5bc9eb86eb801da770e5bf2194190320a66760'
RUNTIME_SHA256 = '41ee86e2d0410dd455297c31c8a839aa2d72fb2b39a9698060e0a412ae63896a'


def resources(runtime_only=False):
    if runtime_only:
        compact = (ROOT / 'RealtimeShield/CascadeV10RuntimeMetadata.json').read_bytes()
    else:
        source = SOURCE.read_bytes()
        if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
            raise ValueError('Frozen Cascade V10 metadata identity changed')
        metadata = json.loads(source)
        # Keep policy, model identities and qualification; never publish training
        # inventory or developer filesystem paths in the app or model asset.
        keys = ['schema_version', 'contract', 'model_version', 'architecture', 'input',
                'policy', 'validation_status', 'compute_precision', 'status']
        runtime = {key: metadata[key] for key in keys}
        runtime['components'] = {
            stage: {key: component[key] for key in ['resource', 'labels', 'checkpoint_sha256']}
            for stage, component in metadata['components'].items()
        }
        compact = (json.dumps(runtime, sort_keys=True, indent=2) + '\n').encode()
    if hashlib.sha256(compact).hexdigest() != RUNTIME_SHA256:
        raise ValueError('Runtime metadata identity changed')
    flat = (ROOT / 'RealtimeShield/FlatDetectorMetadata.json').read_bytes()
    if hashlib.sha256(flat).hexdigest() != '5759a56cccb193afc60faaf6ae8ecbda2838059eb7318afe04df0e87f4b923c9':
        raise ValueError('Flat runtime metadata identity changed')
    flat12 = (ROOT / 'RealtimeShield/FlatDetector12Metadata.json').read_bytes()
    if hashlib.sha256(flat12).hexdigest() != 'd117451e29c1cf4c3f004e049f1c040abc44ec6ec6a0b5dfcc8b2275b91cbeab':
        raise ValueError('Flat 12 runtime metadata identity changed')
    flat13 = (ROOT / 'RealtimeShield/FlatDetector13Metadata.json').read_bytes()
    if hashlib.sha256(flat13).hexdigest() != '35211614cd836f8ef6c074edf0df80256bf41fed469bb89a51cb3d5fc020fc1e':
        raise ValueError('Flat 13 runtime metadata identity changed')
    flat14 = (ROOT / 'RealtimeShield/FlatDetector14Metadata.json').read_bytes()
    if hashlib.sha256(flat14).hexdigest() != '59d058f4ce0c63fb3395065902f100a13a4ae7010d507fcc54d0e0dbd436aacf':
        raise ValueError('Flat 14 runtime metadata identity changed')
    flat15 = (ROOT / 'RealtimeShield/FlatDetector15Metadata.json').read_bytes()
    if hashlib.sha256(flat15).hexdigest() != '6c99991c66cc6deee7d31794a0b1846198f44170dc8c14dce7ebaaa0e142540d':
        raise ValueError('Flat 15 runtime metadata identity changed')
    info = plistlib.loads((ROOT / 'iOS/Info.plist').read_bytes())
    del info['NSPhotoLibraryAddUsageDescription']
    del info['NSPhotoLibraryUsageDescription']
    return {
        ROOT / 'RealtimeShield/CascadeV10RuntimeMetadata.json': compact,
        ROOT / 'RealtimeShield/FlatDetectorMetadata.json': flat,
        ROOT / 'RealtimeShield/FlatDetector12Metadata.json': flat12,
        ROOT / 'RealtimeShield/FlatDetector13Metadata.json': flat13,
        ROOT / 'RealtimeShield/FlatDetector14Metadata.json': flat14,
        ROOT / 'RealtimeShield/FlatDetector15Metadata.json': flat15,
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
