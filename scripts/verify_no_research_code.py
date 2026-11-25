#!/usr/bin/env python3
"""Reject research capture/upload code in every Slowth build, including Debug dylibs."""
import argparse
from pathlib import Path
import plistlib

MARKERS = (
    b'DebugCaptureWriter', b'DebugCapturePhotoLibrary', b'DebugCaptureSettings',
    b'SessionCapture', b'SessionUploader', b'SessionUploadConnection',
    b'DebugTransfer', b'DebugS3Signer', b'MotionVideoRecorder',
    b'MotionExperimentStore', b'MotionExperimentWidget', b'SessionPNG',
    b'RealtimeShieldCaptures', b'RealtimeShieldSessions',
    b'CMSensorRecorder', b'CMMotionManager', b'PHPhotoLibrary', b'AVAssetWriter',
)
SOURCE_DIRS = ('App', 'Shared', 'Debug', 'iOS', 'RealtimeShield', 'PauseActivityIOS',
               'Extension', 'ExtensionIOS', 'DeviceActivityIOS', 'ShieldActionIOS', 'ShieldConfigIOS')


def verify_sources(root):
    for directory in SOURCE_DIRS:
        for path in (root / directory).rglob('*.swift'):
            content = path.read_bytes()
            for marker in MARKERS:
                assert marker not in content, f'{path}: research code {marker.decode()}'
    for name in ('Info.plist', 'Info-Release.plist'):
        info = plistlib.loads((root / 'iOS' / name).read_bytes())
        for key in ('NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription', 'NSMotionUsageDescription'):
            assert key not in info, f'{name}: unexpected research permission {key}'


def verify_bundle(app):
    # Debug builds often put Swift code in *.debug.dylib, not the launcher.
    binaries = set(app.rglob('*.dylib'))
    for info_path in app.rglob('Info.plist'):
        info = plistlib.loads(info_path.read_bytes())
        executable = info.get('CFBundleExecutable')
        if executable:
            for directory in (info_path.parent, info_path.parent / 'MacOS'):
                binary = directory / executable
                if binary.is_file(): binaries.add(binary)
    assert binaries, f'No binaries found in {app}'
    for binary in sorted(binaries):
        content = binary.read_bytes()
        for marker in MARKERS:
            assert marker not in content, f'{binary}: research symbol {marker.decode()}'
    print(f'{app.name}: {len(binaries)} binaries contain no research capture/upload symbols')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    verify_sources(Path(__file__).resolve().parents[1])
    if args.app: verify_bundle(args.app)
    print('Research code boundary: passed')
