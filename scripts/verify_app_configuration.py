#!/usr/bin/env python3
"""Verify actual Debug/Release iOS resources, not just project settings."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTS = ROOT / 'data-model/exports'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(app, configuration):
    release = configuration == 'Release'
    aliases = EXPORTS / 'v15-v6-app-20260920-154340/ios-resources'
    cascade = {name: aliases / (name + '.mlpackage')
               for name in ('AppRouterV6', 'YouTubeDetectorV6', 'InstagramDetectorV6')}
    alternatives = {
        'SurfaceDetectorV14': EXPORTS / 'v14-cascade-v5-20260920-1018/v14/SurfaceDetectorV14.mlpackage',
        'SurfaceDetectorV15': EXPORTS / 'v15-cascade-v6-20260920-124303/v15/SurfaceDetectorV15.mlpackage',
    }
    metadata = ({'CascadeV6RuntimeMetadata': ROOT / 'RealtimeShield/CascadeV6RuntimeMetadata.json'}
                if release else {'CascadeV6Metadata': aliases / 'CascadeV6Metadata.json',
                    **{name + 'Metadata': p.with_name(name + 'Metadata.json')
                       for name, p in alternatives.items()}})
    for bundle in [app, app / 'PlugIns/UnscrollBroadcastIOS.appex']:
        models = {} if release and bundle == app else cascade | ({} if release else alternatives)
        expected_metadata = {} if release and bundle == app else metadata
        assert {p.stem for p in bundle.glob('*.mlmodelc')} == set(models), bundle
        assert {p.stem for p in bundle.glob('*Metadata.json')} == set(expected_metadata), bundle
        for name, source in models.items():
            weights = list(source.rglob('weight.bin'))
            assert len(weights) == 1
            assert sha(bundle / (name + '.mlmodelc') / 'weights/weight.bin') == sha(weights[0]), name
        for name, source in expected_metadata.items():
            assert (bundle / (name + '.json')).read_bytes() == source.read_bytes(), name
        if release:
            executable = plistlib.loads((bundle / 'Info.plist').read_bytes())['CFBundleExecutable']
            binary = (bundle / executable).read_bytes()
            for marker in (b'DebugSessionCaptureControls', b'DebugCapturePhotoLibrary', b'SessionUploader',
                           b'SessionCaptureArchive', b'DebugCaptureWriter', b'resetStrictModeForDebug'):
                assert marker not in binary, (bundle, marker)
        print(f'{bundle.name}: {len(models)} compiled models, {len(expected_metadata)} metadata files')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    for key in ('NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription'):
        assert (key in info) == (not release), key
    assert not list(app.rglob('Info-Release.plist')), 'Info template copied as a resource'
    print(f'{configuration}: {sum(p.stat().st_size for p in app.rglob("*") if p.is_file()) / 1e6:.2f} MB')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], required=True)
    args = parser.parse_args()
    verify(args.app, args.configuration)
