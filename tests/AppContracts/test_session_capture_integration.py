
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_periodic_capture_is_independent_and_preserves_fail_closed_callbacks():
    source = (ROOT / "RealtimeShield/SampleHandler.swift").read_text()
    process = source.split("override func processSampleBuffer(", 1)[1].split("private func resetSessionState", 1)[0]
    assert process.index("captureSessionFrame(sampleBuffer, predictions: framePredictions)") < process.index("guard sharedState.broadcastActive, sharedState.realtimeShieldEnabled")
    assert "captureSessionFrame(sampleBuffer, predictions: framePredictions)" in process
    assert "var framePredictions: [String: Double]?" in process
    assert "sessionCapture?.pause()" in source
    assert "sessionCapture?.resume()" in source
    assert 'sessionCapture?.finish(reason: "finished")' in source
    assert "reshieldEnabledSurfaces()" in source.split("override func broadcastFinished()", 1)[1].split("override func processSampleBuffer", 1)[0]
    assert "SessionCaptureSettings.isEnabled" in source
    assert "SessionPNG.encode" in source
    assert "sessionCapture?.drain()" not in source


def test_periodic_capture_has_separate_opt_in_in_both_ios_styles():
    for path in ["Debug/iOS/DebugIOSSection.swift", "Debug/UI/DebugCompactSection.swift"]:
        assert "DebugSessionCaptureControls()" in (ROOT / path).read_text()
    ui = ROOT / "Debug/iOS/DebugSessionCaptureControls.swift"
    assert ui.exists(), "session controls and local Share UI are missing"
    source = ui.read_text()
    assert "SessionCaptureSettings.storageKey" in source
    assert "SessionCaptureArchive.export" in source
    assert "UIActivityViewController" in source
    assert 'Button("Share snapshot ZIP")' in source
    assert 'busy || !row.isClosed' not in source
    assert "PhotoLibrary" not in source
    assert "1 second" in source and "0.5 seconds" in source


def test_capture_tools_are_debug_only_with_runtime_opt_in():
    settings = (ROOT / "Debug/Shared/SessionCaptureSettings.swift").read_text()
    ui = (ROOT / "Debug/iOS/DebugSessionCaptureControls.swift").read_text()
    assert settings.startswith('#if DEBUG\n')
    assert ui.startswith('#if DEBUG\n')
    assert 'guard debug, optedIn else { return nil }' in settings
    assert 'resolve(debug: DebugMode.isEnabled' in settings
    assert 'private var enabled = false' in ui
    for name in ('ContentView_iOS.swift', 'ContentView_macOS.swift'):
        view = (ROOT / 'Shared' / name).read_text()
        assert 'if debugModeEnabled' in view
        assert 'DebugMode.requiredVersionTapCount' in view


def test_session_rename_ui_saves_only_on_confirmation_and_reloads_names():
    source = (ROOT / "Debug/iOS/DebugSessionCaptureControls.swift").read_text()
    assert 'Button("Rename")' in source
    assert 'TextField("Session name", text: $nameDraft)' in source
    assert 'Button("Save")' in source
    assert 'Button("Cancel", role: .cancel) { renameRow = nil; nameDraft = "" }' in source
    assert 'SessionCaptureName.normalized(nameDraft)' in source
    assert 'SessionCaptureName.rename(in: row.directory, to: name)' in source
    assert 'SessionCaptureName.load(from: directory)' in source
    assert 'if let name = row.name { Text(name)' in source
    # User text must not become a path; archives keep UUID-based filenames.
    assert 'slowth-\\(row.id.uuidString)-\\(UUID().uuidString).zip' in source
