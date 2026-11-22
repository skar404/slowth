
"""Guard current iOS model resources and recording selection."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def target_block(name):
    text = (ROOT / 'project.yml').read_text()
    block = text.split(f'  {name}:\n', 1)[1]
    return re.split(r'\n  [A-Za-z][A-Za-z0-9_]*:\n|\nschemes:', block, maxsplit=1)[0]


def test_both_ios_targets_ship_only_retained_models():
    expected = {
        'FlatDetector.mlpackage', 'FlatDetector12.mlpackage', 'FlatDetector13.mlpackage', 'FlatDetector14.mlpackage', 'FlatDetector15.mlpackage',
        'FlatDetectorIPhone13ProMax.mlpackage', 'FlatDetectorIPhone13ProMaxMetadata.json',
        'SurfaceDetectorV14.mlpackage', 'SurfaceDetectorV14Metadata.json',
        'SurfaceDetectorV15.mlpackage', 'SurfaceDetectorV15Metadata.json',
        'AppRouterV6.mlpackage', 'YouTubeDetectorV6.mlpackage',
        'InstagramDetectorV6.mlpackage', 'CascadeV6Metadata.json',
        'AppRouterV7.mlpackage', 'YouTubeDetectorV7.mlpackage', 'InstagramDetectorV7.mlpackage',
        'FacebookDetectorV7.mlpackage', 'CascadeV7Metadata.json',
        'AppRouterV8.mlpackage', 'YouTubeDetectorV8.mlpackage', 'InstagramDetectorV8.mlpackage',
        'FacebookDetectorV8.mlpackage', 'XDetectorV8.mlpackage', 'CascadeV8Metadata.json',
        'AppRouterV10.mlpackage', 'YouTubeDetectorV10.mlpackage', 'InstagramDetectorV10.mlpackage',
        'FacebookDetectorV10.mlpackage', 'XDetectorV10.mlpackage', 'CascadeV10Metadata.json',
    }
    for target in ('UnscrollIOS', 'UnscrollBroadcastIOS'):
        block = target_block(target)
        resources = {Path(p).name for p in re.findall(r'- path: (.+)', block)
                     if p.endswith('.mlpackage') or p.endswith('Metadata.json')}
        assert resources == expected | ({'FlatDetectorMetadata.json', 'FlatDetector12Metadata.json', 'FlatDetector13Metadata.json', 'FlatDetector14Metadata.json', 'FlatDetector15Metadata.json'} if target == 'UnscrollIOS' else set())
        assert 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CASCADE_MODEL"' in block
    broadcast = target_block('UnscrollBroadcastIOS')
    assert '          - "SurfaceDetector.mlpackage"' in broadcast
    assert '          - "SurfaceDetectorMetadata.json"' in broadcast
    assert '.mlpackage' not in target_block('Unscroll')


def test_factory_uses_shared_default_and_has_no_retired_routes():
    factory = (ROOT / 'RealtimeShield/SurfaceClassifierFactory.swift').read_text().split('enum SurfaceClassifierFactory')[1]
    assert 'backend: ModelBackend = ModelSettings.defaultBackend' in factory
    # The outer Release branch ignores historical backend selections and uses Flat.
    assert factory.rsplit('#else', 1)[1].split('#endif', 1)[0].strip() == 'return try FlatClassifier(candidate: .flat15)'
    assert set(re.findall(r'case \.(\w+):', factory)) == {'v14', 'v15', 'cascadeV6', 'cascadeV7', 'cascadeV8', 'cascadeV10', 'flat11', 'flat11IPhone13ProMax', 'flat12', 'flat13', 'flat14', 'flat15'}
    for loader in ('SurfaceClassifier(resourceName: "SurfaceDetectorV14")',
                   'SurfaceClassifier(resourceName: "SurfaceDetectorV15")',
                   'CascadeClassifier(candidate: .v6)'):
        assert loader in factory


def test_both_pickers_normalize_retired_selections_and_describe_flat_default():
    for view in ('Debug/iOS/DebugIOSSection.swift', 'Debug/UI/DebugCompactSection.swift'):
        text = (ROOT / view).read_text()
        assert 'DebugModelSettings.selection(stored: debugModelBackend).rawValue' in text
        assert 'private var debugModelBackend = DebugModelSettings.defaultBackend.rawValue' in text
        assert 'ForEach(ModelBackend.allCases' in text
        assert 'Text(backend.title)' in text


def test_backend_is_frozen_at_start_even_if_first_load_is_delayed_or_fails():
    handler = (ROOT / 'RealtimeShield/SampleHandler.swift').read_text()
    started = handler.split('override func broadcastStarted', 1)[1].split('override func broadcastPaused', 1)[0]
    loader = handler.split('private func loadClassifier()', 1)[1].split('private func failInference', 1)[0]
    assert 'recordingBackend = DebugModelSettings.resolve(' in started
    assert started.index('recordingBackend =') < started.index('if sharedState.realtimeShieldEnabled')
    assert 'SurfaceClassifierFactory.make(backend: recordingBackend)' in loader
    assert 'AppGroup.defaults' not in loader
    assert 'DebugMode.isEnabled' not in loader


def test_new_recording_releases_previous_classifier_even_when_disabled():
    handler = (ROOT / 'RealtimeShield/SampleHandler.swift').read_text()
    reset = handler.split('private func resetSessionState()', 1)[1].split('private func resetStreaks', 1)[0]
    assert 'classifier = nil' in reset
    assert 'metadata = nil' in reset
