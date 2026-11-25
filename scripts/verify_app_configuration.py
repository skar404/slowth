#!/usr/bin/env python3
"""Verify actual Debug/Release iOS resources, not just project settings."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
from verify_no_research_code import verify_bundle, verify_sources
from model_assets import resource_maps, verify as verify_model_assets


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(app, configuration):
    verify_sources(ROOT)
    verify_bundle(app)
    release = configuration == 'Release'
    verify_model_assets(ROOT, configuration)
    models_for_profile, metadata = resource_maps(ROOT, configuration)
    for bundle in [app, app / 'PlugIns/UnscrollBroadcastIOS.appex']:
        models = {} if release and bundle == app else models_for_profile
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
                           b'SessionCaptureArchive', b'DebugCaptureWriter', b'resetStrictModeForDebug',
                           b'DebugAppReviewControls', b'prepareEligibleHistoryForDebug',
                           b'DebugSavedLeavesControl', b'DebugIOSSection', b'DebugCompactSection',
                           b'DebugCaptureLifecycle', b'DebugModelSettings', b'resetPausesForDebug', b'setSavedLeavesForDebug'):
                assert marker not in binary, (bundle, marker)
        print(f'{bundle.name}: {len(models)} compiled models, {len(expected_metadata)} metadata files')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    for key in ('NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription'):
        assert key not in info, key
    for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription'):
        assert info.get(key), 'Missing website media usage description: ' + key
    assert info.get('NSSupportsLiveActivities') is True, 'Missing Live Activity host support'
    widget = app / 'PlugIns/UnscrollPauseActivity.appex'
    widget_info = plistlib.loads((widget / 'Info.plist').read_bytes())
    assert widget_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
    safari = app / 'PlugIns/UnscrollExtension.appex'
    manifest = json.loads((safari / 'manifest.json').read_text())
    assert 'pause-background.js' in manifest['background']['scripts'], 'Missing Safari pause integration'
    for filename in ('pause-policy.js', 'pause-background.js'):
        assert (safari / filename).read_bytes() == (ROOT / 'iOS/WebPause' / filename).read_bytes(), filename
    assert not list(app.rglob('Info-Release.plist')), 'Info template copied as a resource'
    print(f'{configuration}: {sum(p.stat().st_size for p in app.rglob("*") if p.is_file()) / 1e6:.2f} MB')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], required=True)
    args = parser.parse_args()
    verify(args.app, args.configuration)
