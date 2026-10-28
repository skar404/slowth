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
    current = EXPORTS / 'cascade-v10-study-20260929-1356/diverse/ios-resources'
    cascade = {name + 'V10': current / (name + 'V10.mlpackage')
               for name in ('AppRouter', 'YouTubeDetector', 'InstagramDetector', 'FacebookDetector', 'XDetector')}
    flat = {'FlatDetector': EXPORTS / 'flat-11-seed7-20261015/FlatDetector.mlpackage'}
    flat['FlatDetector12'] = EXPORTS / 'flat-12-seed7-20261027/ios-resources/FlatDetector12.mlpackage'
    flat['FlatDetector13'] = EXPORTS / 'flat-13-seed7-20261027/ios-resources/FlatDetector13.mlpackage'
    flat['FlatDetector14'] = EXPORTS / 'flat-14-seed7-20261028/ios-resources/FlatDetector14.mlpackage'
    flat['FlatDetector15'] = EXPORTS / 'flat-15-seed7-20261028/ios-resources/FlatDetector15.mlpackage'
    alternatives = {
        'SurfaceDetectorV14': EXPORTS / 'v14-cascade-v5-20260920-1018/v14/SurfaceDetectorV14.mlpackage',
        'SurfaceDetectorV15': EXPORTS / 'v15-cascade-v6-20260920-124303/v15/SurfaceDetectorV15.mlpackage',
    }
    metadata = ({'CascadeV10RuntimeMetadata': ROOT / 'RealtimeShield/CascadeV10RuntimeMetadata.json'}
                if release else {'CascadeV10Metadata': current / 'CascadeV10Metadata.json',
                    **{name + 'Metadata': p.with_name(name + 'Metadata.json')
                       for name, p in alternatives.items()}})
    if not release:
        candidate = EXPORTS / "flat-11-seed7-iphone13promax-20261026/ios-resources"
        alternatives["FlatDetectorIPhone13ProMax"] = candidate / "FlatDetectorIPhone13ProMax.mlpackage"
        metadata["FlatDetectorIPhone13ProMaxMetadata"] = candidate / "FlatDetectorIPhone13ProMaxMetadata.json"
        for version, directory, names in (
            ('V6', aliases, ('AppRouter', 'YouTubeDetector', 'InstagramDetector')),
            ('V7', EXPORTS / 'cascade-v7-facebook-20260928-114500/ios-resources',
             ('AppRouter', 'YouTubeDetector', 'InstagramDetector', 'FacebookDetector')),
            ('V8', EXPORTS / 'cascade-v8-x-20260928/ios-resources',
             ('AppRouter', 'YouTubeDetector', 'InstagramDetector', 'FacebookDetector', 'XDetector')),
        ):
            alternatives.update({name + version: directory / (name + version + '.mlpackage') for name in names})
            metadata['Cascade' + version + 'Metadata'] = directory / ('Cascade' + version + 'Metadata.json')
    metadata['FlatDetectorMetadata'] = ROOT / 'RealtimeShield/FlatDetectorMetadata.json'
    metadata['FlatDetector12Metadata'] = ROOT / 'RealtimeShield/FlatDetector12Metadata.json'
    metadata['FlatDetector13Metadata'] = ROOT / 'RealtimeShield/FlatDetector13Metadata.json'
    metadata['FlatDetector14Metadata'] = ROOT / 'RealtimeShield/FlatDetector14Metadata.json'
    metadata['FlatDetector15Metadata'] = ROOT / 'RealtimeShield/FlatDetector15Metadata.json'
    if release:
        flat = {'FlatDetector15': flat['FlatDetector15']}
        metadata = {'FlatDetector15Metadata': metadata['FlatDetector15Metadata']}
    for bundle in [app, app / 'PlugIns/UnscrollBroadcastIOS.appex']:
        models = {} if release and bundle == app else flat | ({} if release else cascade | alternatives)
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
        assert (key in info) == (not release), key
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
