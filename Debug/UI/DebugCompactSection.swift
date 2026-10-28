#if DEBUG
import SwiftUI
#if os(iOS)
import FamilyControls
#endif

struct DebugCompactSection: View {
    @ObservedObject var state: AppState
    @Binding var debugModeEnabled: Bool
    let isReadyForReview: Bool
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
            #if os(iOS)
            DebugSessionCaptureControls()
            DebugSavedLeavesControl()
            Button(String(localized: "Reset rest progression", table: "Interface")) {
                do { try IOSPauseCoordinator.resetRestProgressForDebug() }
                catch { state.lastError = AppLocalization.string("Could not save") }
            }
            .accessibilityIdentifier("debug.rest.reset")
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
            #endif
            DebugAppReviewControls(hasEnabledBlocking: state.hasEnabledBlockingForReview,
                                   isReady: isReadyForReview)
            Toggle("Tips", isOn: $tipsFeatureEnabled)
            Button("Reset Strict mode") {
                state.resetStrictModeForDebug()
            }
            .disabled(!state.snapshot.isStrictModeActive)
            Button("Show Tips card again") {
                state.resetTipsDisplayForDebug()
            }
            .disabled(!state.snapshot.supportCardDismissed)
        } header: {
            Text("Debug")
        }
    }

}

#Preview("Debug · compact / macOS") {
    Form {
        DebugCompactSection(state: AppState(previewSnapshot: .defaultState),
            debugModeEnabled: .constant(true), isReadyForReview: true)
    }
    .frame(minWidth: 360, minHeight: 440)
    .allowsHitTesting(false)
}

#endif
