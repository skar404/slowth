#if DEBUG && os(iOS)
import SwiftUI
import FamilyControls

struct DebugIOSSection: View {
    @ObservedObject var state: AppState
    @Binding var debugModeEnabled: Bool
    let isReadyForReview: Bool
    @State private var showTools = false

    var body: some View {
        Section {
            Button { showTools = true } label: {
                HStack {
                    DebugToolLabel("Developer tools", detail: "Diagnostics and app testing", icon: "wrench.and.screwdriver", color: .secondary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("debug.tools")
            .sheet(isPresented: $showTools) {
                DebugToolsView(state: state, debugModeEnabled: $debugModeEnabled,
                    isReadyForReview: isReadyForReview)
            }
        } header: {
            Text("Debug")
        }
    }
}

struct DebugToolsView: View {
    @ObservedObject var state: AppState
    @Binding var debugModeEnabled: Bool
    let isReadyForReview: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DebugModelSettings.storageKey, store: AppGroup.defaults) private var debugModelBackend = DebugModelSettings.defaultBackend.rawValue
    @AppStorage(FeatureFlags.tipsOverrideStorageKey, store: AppGroup.defaults) private var tipsFeatureEnabled = false
    @AppStorage(DebugMode.shieldDiagnosticsStorageKey, store: AppGroup.defaults) private var shieldDiagnosticsEnabled = false
    @State private var showIconProbe = false
    @State private var showManagedSettings = false
    @State private var actionError: String?

    private var modelSettingsLocked: Bool {
        state.snapshot.broadcastActive || (state.snapshot.isStrictModeActive &&
            (state.snapshot.realtimeFacebookBlockingEnabled || state.snapshot.realtimeXBlockingEnabled))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Debug mode", isOn: $debugModeEnabled)
                        .disabled(modelSettingsLocked)
                        .onChange(of: debugModeEnabled) { enabled in
                            state.refreshFacebookModelSelection()
                            if !enabled { dismiss() }
                        }
                } footer: {
                    if modelSettingsLocked {
                        Text(state.snapshot.broadcastActive ? "Stop recording to change Debug mode or the model." : "End Strict mode to change Debug mode or the model.")
                    }
                }
                Section("Detection") {
                    NavigationLink {
                        detectionSettings
                    } label: {
                        DebugToolLabel("Models", detail: "Detection model", icon: "viewfinder", color: .purple)
                    }
                }
                Section("Testing") {
                    NavigationLink {
                        diagnostics
                    } label: {
                        DebugToolLabel("Blocking diagnostics", detail: "Shield and Screen Time settings", icon: "shield.lefthalf.filled", color: .orange)
                    }
                    NavigationLink {
                        appTesting
                    } label: {
                        DebugToolLabel("App behavior", detail: "Reviews, rewards and resets", icon: "slider.horizontal.3", color: SlowthAppearance.sage)
                    }

                }
            }
            .debugFormStyle()
            .navigationTitle("Developer tools")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }

        }
    }

    private var detectionSettings: some View {
        Form {
            if DebugModelSettings.cascadeAvailable {
                Section {
                    Picker("Model", selection: Binding(
                        get: { DebugModelSettings.selection(stored: debugModelBackend).rawValue },
                        set: { debugModelBackend = $0; state.refreshFacebookModelSelection() }
                    )) {
                        ForEach(ModelBackend.allCases, id: \.rawValue) { backend in
                            Text(backend.title).tag(backend.rawValue)
                        }
                    }
                    .disabled(modelSettingsLocked)
                } header: { Text("Detection") } footer: {
                    Text("Applies to the next recording.")
                }
            }

        }
        .debugFormStyle()
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var diagnostics: some View {
        Form {
            Section("Shield") {
                Toggle("Debug Shield", isOn: $shieldDiagnosticsEnabled)
                    .accessibilityIdentifier("debug.shieldDiagnostics")
                Button { showManagedSettings = true } label: {
                    Label("Inspect Managed Settings", systemImage: "list.bullet.rectangle")
                }
            }
            Section {
                Button { showIconProbe = true } label: {
                    Label("Get app icons", systemImage: "app.badge")
                }
                .disabled(GroupedApps.selection == nil)
            } header: { Text("Experiments") } footer: {
                if GroupedApps.selection == nil { Text("Select apps in blocking settings to inspect their icons.") }
            }
        }
        .debugFormStyle()
        .navigationTitle("Blocking diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showManagedSettings) { ManagedSettingsDiagnosticsView() }
        .sheet(isPresented: $showIconProbe) { FamilyIconProbeSheet() }
    }

    private var appTesting: some View {
        Form {
            Section("App review") {
                DebugAppReviewControls(hasEnabledBlocking: state.hasEnabledBlockingForReview, isReady: isReadyForReview)
            }
            Section("Tips and rewards") {
                Toggle("Tips", isOn: $tipsFeatureEnabled)
                DebugSavedLeavesControl()
            }
            Section("Resets") {
                Button(String(localized: "Reset rest progression", table: "Interface")) {
                    do { try IOSPauseCoordinator.resetRestProgressForDebug() }
                    catch { actionError = AppLocalization.string("Could not save") }
                }
                .accessibilityIdentifier("debug.rest.reset")
                Button(String(localized: "Reset pauses", table: "Interface")) {
                    do { try IOSPauseCoordinator.resetPausesForDebug() }
                    catch { actionError = String(localized: "Could not reset pauses. Try again.", table: "Interface") }
                }
                Button("Reset Strict mode") { state.resetStrictModeForDebug() }
                    .disabled(!state.snapshot.isStrictModeActive)
            }
        }
        .debugFormStyle()
        .navigationTitle("App behavior")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Could not complete action", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
    }
}

/// Shared labels keep the tools index readable at larger text sizes.
struct DebugToolLabel: View {
    let title: String
    let detail: String
    let icon: String
    let color: Color
    let showsChevron: Bool

    init(_ title: String, detail: String, icon: String, color: Color, showsChevron: Bool = false) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.color = color
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            if showsChevron {
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func debugFormStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .background(SlowthAppearance.background)
            .environment(\.defaultMinListRowHeight, 48)
    }
}

#if targetEnvironment(simulator)
struct DebugToolsPreview: View {
    var body: some View {
        DebugToolsView(state: AppState(previewSnapshot: .defaultState),
            debugModeEnabled: .constant(true), isReadyForReview: true)
            .allowsHitTesting(false)
    }
}
#endif

#Preview("Developer tools") {
    DebugToolsView(state: AppState(previewSnapshot: .defaultState),
        debugModeEnabled: .constant(true), isReadyForReview: true)
}
#endif
