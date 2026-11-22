#!/usr/bin/env python3
"""Prepare (never submit) the managed browser entitlement candidate after Apple approval.

Generated plists stay outside the source tree. Host-only Xcode settings opt in;
extension entitlements and ordinary Beta builds are unchanged.
"""
import argparse
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def prepare(destination):
    destination.mkdir(parents=True, exist_ok=True)
    info = plistlib.loads((ROOT / 'iOS/Info-Release.plist').read_bytes())
    forbidden = ('NSPhotoLibraryUsageDescription', 'NSLocationAlwaysUsageDescription',
                 'NSLocationAlwaysAndWhenInUseUsageDescription', 'NSHomeKitUsageDescription',
                 'NSBluetoothAlwaysUsageDescription', 'NSHealthShareUsageDescription', 'NSHealthUpdateUsageDescription')
    if any(key in info for key in forbidden):
        raise ValueError('Browser candidate includes a prohibited privacy description')
    info['CFBundleURLTypes'].append({
        'CFBundleURLName': 'Slowth web apps', 'CFBundleTypeRole': 'Viewer',
        'CFBundleURLSchemes': ['http', 'https'],
    })
    info['SlowthBrowserEntitlementCandidate'] = True
    entitlements = plistlib.loads((ROOT / 'iOS/Unscroll.entitlements').read_bytes())
    entitlements['com.apple.developer.web-browser'] = True
    for name, content in [('Info.plist', info), ('Browser.entitlements', entitlements)]:
        (destination / name).write_bytes(plistlib.dumps(content, sort_keys=False))
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/browser-candidate')
    args = parser.parse_args()
    folder = prepare(args.output.resolve())
    print('Prepared only; no Apple request or upload was sent.')
    print('Host build settings after entitlement approval:')
    print(f'SLOWTH_IOS_RELEASE_INFO={folder / "Info.plist"}')
    print(f'SLOWTH_IOS_HOST_ENTITLEMENTS={folder / "Browser.entitlements"}')
