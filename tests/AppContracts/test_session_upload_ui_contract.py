
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_only_exact_accepted_rows_are_gray_without_disabling_actions():
    ui = (ROOT / 'Debug/iOS/DebugSessionCaptureControls.swift').read_text()
    connection = (ROOT / 'Debug/iOS/SessionUploadConnection.swift').read_text()
    index = (ROOT / 'Debug/Shared/SessionUploadIndex.swift').read_text()
    assert 'var isSentPresentation: Bool { self == .accepted }' in index
    assert 'SessionUploadRowStyle(uploader: uploader, id: row.id, fingerprint: row.fingerprint)' in ui
    style = connection.split('struct SessionUploadRowStyle: ViewModifier {')[1].split('struct SessionUploadPanel: View {')[0]
    assert '@ObservedObject var uploader: SessionUploader' in style
    assert 'fingerprint.map { uploader.index.status(id, fingerprint: $0) } ?? .notSent' in style
    assert 'uploader.uploadingID != id && state.isSentPresentation' in style
    assert '.foregroundStyle(sent ? Color(uiColor: .label) : Color.primary)' in style
    assert '.listRowBackground(sent ? Color(uiColor: .systemGray5) : Color(uiColor: .secondarySystemGroupedBackground))' in style
    assert '.disabled(' not in style
    assert '.opacity(' not in style
    assert '.allowsHitTesting(' not in style
    assert 'Sent — accepted by labeler (exact checked snapshot)' in connection
    for action in ['Rename', 'Share snapshot ZIP', 'Delete']:
        assert f'Button("{action}"' in ui


def test_identity_uses_one_manifest_read_for_decode_and_hash():
    source = (ROOT / 'Debug/Shared/SessionUploadIdentity.swift').read_text()
    assert 'let manifestData = try Data(contentsOf: manifestURL)' in source
    assert 'SHA256.hash(data: manifestData)' in source
    assert 'try hash(manifestURL)' not in source


def test_hidden_session_upload_has_permission_confirmation_and_keychain():
    ui = (ROOT / 'Debug/iOS/DebugSessionCaptureControls.swift').read_text()
    connection = (ROOT / 'Debug/iOS/SessionUploadConnection.swift').read_text()
    assert 'Send this snapshot to the private labeler?' in ui
    assert 'DebugMode.isEnabled' in ui
    assert 'Cancel upload' in ui
    assert 'SessionUploadPanel' in ui
    assert 'kSecAttrAccessibleWhenUnlockedThisDeviceOnly' in connection
    assert 'SecureField' in connection
    assert 'SecItemCopyMatching' in connection
    assert connection.startswith('#if DEBUG\n')
