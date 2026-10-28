#if DEBUG && os(iOS)
import SwiftUI
import FamilyControls

struct DebugIOSSection: View {
    @ObservedObject var state: AppState
    @Binding var debugModeEnabled: Bool
    let isReadyForReview: Bool
    @ObservedObject var debugCaptureLibrary: DebugCapturePhotoLibrary
    @Binding var debugCaptureEnabled: Bool
    @AppStorage(DebugModelSettings.storageKey, store: AppGroup.defaults) private var debugModelBackend = DebugModelSettings.defaultBackend.rawValue
    @AppStorage(FeatureFlags.tipsOverrideStorageKey, store: AppGroup.defaults) private var tipsFeatureEnabled = false

    var body: some View {
        Section {
            Toggle("Debug mode", isOn: $debugModeEnabled)
                .disabled(state.snapshot.broadcastActive || (state.snapshot.isStrictModeActive && (state.snapshot.realtimeFacebookBlockingEnabled || state.snapshot.realtimeXBlockingEnabled)))
                .onChange(of: debugModeEnabled) { _ in
                    #if os(iOS) && canImport(FamilyControls)
                    state.refreshFacebookModelSelection()
                    #endif
                }
            DebugSessionCaptureControls()
            if DebugModelSettings.cascadeAvailable {
                Picker("Model (next recording)", selection: Binding(
                    get: { DebugModelSettings.selection(stored: debugModelBackend).rawValue },
                    set: { debugModelBackend = $0; state.refreshFacebookModelSelection() }
                )) {
                    ForEach(ModelBackend.allCases, id: \.rawValue) { backend in
                        Text(backend.title).tag(backend.rawValue)
                    }
                }
                .disabled(state.snapshot.broadcastActive || (state.snapshot.isStrictModeActive && (state.snapshot.realtimeFacebookBlockingEnabled || state.snapshot.realtimeXBlockingEnabled)))
            }
            Toggle("Save detection frames", isOn: $debugCaptureEnabled)
            if debugCaptureEnabled {
                if debugCaptureLibrary.authorizationStatus == .authorized
                    || debugCaptureLibrary.authorizationStatus == .limited {
                    Button {
                        debugCaptureLibrary.importPending()
                    } label: {
                        HStack {
                            Text("Save frames to Photos")
                            Spacer()
                            if debugCaptureLibrary.isImporting { ProgressView() }
                        }
                    }
                    .disabled(
                        debugCaptureLibrary.isImporting
                            || debugCaptureLibrary.pendingEvents == 0
                    )
                } else {
                    Button("Allow Photos access") {
                        debugCaptureLibrary.requestAccessAndImport()
                    }
                }
                Button("Clear pending frames", role: .destructive) {
                    debugCaptureLibrary.clearPending()
                }
                .disabled(debugCaptureLibrary.pendingEvents == 0)
            }
            DebugAppReviewControls(hasEnabledBlocking: state.hasEnabledBlockingForReview,
                                   isReady: isReadyForReview)
            Toggle("Tips", isOn: $tipsFeatureEnabled)
            DebugSavedLeavesControl()
            Button(String(localized: "Reset rest progression", table: "Interface")) {
                do { try IOSPauseCoordinator.resetRestProgressForDebug() }
                catch { state.lastError = AppLocalization.string("Could not save") }
            }
            .accessibilityIdentifier("debug.rest.reset")
            Button(String(localized: "Reset pauses", table: "Interface")) {
                do { try IOSPauseCoordinator.resetPausesForDebug() }
                catch { state.lastError = String(localized: "Could not reset pauses. Try again.", table: "Interface") }
            }
            Button("Reset Strict mode") {
                state.resetStrictModeForDebug()
            }
            .disabled(!state.snapshot.isStrictModeActive)

        } header: {
            Text("Debug")
        }
    }

}

#Preview("Debug · iOS") {
    NavigationStack {
        Form {
            DebugIOSSection(state: AppState(previewSnapshot: .defaultState),
                debugModeEnabled: .constant(true), isReadyForReview: true,
                debugCaptureLibrary: DebugCapturePhotoLibrary(previewAuthorization: .notDetermined),
                debugCaptureEnabled: .constant(false))
        }.navigationTitle("Settings")
    }
    .allowsHitTesting(false)
}
#Preview("Debug · frames ready") {
    NavigationStack {
        Form {
            DebugIOSSection(state: AppState(previewSnapshot: .defaultState),
                debugModeEnabled: .constant(true), isReadyForReview: true,
                debugCaptureLibrary: DebugCapturePhotoLibrary(previewAuthorization: .authorized, pending: 8),
                debugCaptureEnabled: .constant(true))
        }.navigationTitle("Settings")
    }
    .preferredColorScheme(.dark)
    .allowsHitTesting(false)
}

#endif
