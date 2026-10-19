import ActivityKit
import AppIntents
import SwiftUI

@available(iOS 17.0, *)
struct PauseActivityActionIntent: LiveActivityIntent {
    static var title = LocalizedStringResource("Pause controls", table: "PauseActivity")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: LocalizedStringResource("Pause ID", table: "PauseActivity")) var pauseID: String
    @Parameter(title: LocalizedStringResource("Current app", table: "PauseActivity")) var source: String
    @Parameter(title: LocalizedStringResource("Action", table: "PauseActivity")) var action: String
    @Parameter(title: LocalizedStringResource("Destination app", table: "PauseActivity")) var target: String

    init() {}
    init(id: String, source: String, action: String, target: String = "") {
        self.pauseID = id
        self.source = source
        self.action = action
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        // LiveActivityIntent runs in the host process. The widget only needs
        // the matching intent declaration and serialized parameters.
        #if !PAUSE_ACTIVITY_WIDGET
        do {
            switch action {
            case "end":
                try IOSPauseCoordinator.finish(id: pauseID)
            case "choose", "cancel":
                try await IOSPauseLiveActivity.shared.setChoosing(action == "choose", id: pauseID, source: source)
            case "switch":
                try IOSPauseCoordinator.switchApplication(id: pauseID, from: source, to: target)
            default:
                throw IOSPauseError.invalidTarget
            }
            await IOSPauseLiveActivity.shared.synchronize()
        } catch {
            await IOSPauseLiveActivity.shared.synchronize()
            throw PauseActivityActionError()
        }
        #endif
        return .result()
    }
}

private struct PauseActivityActionError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Could not change pause. Open Slowth and try again.", table: "PauseActivity")
    }
}

@available(iOS 17.0, *)
struct PauseActivityActions: View {
    let id: String
    let state: PauseActivityAttributes.ContentState
    private let sage = Color(red: 0.66, green: 0.81, blue: 0.62)

    var body: some View {
        VStack(spacing: 6) {
            if state.choosingApp == true {
                HStack(spacing: 6) {
                    ForEach(state.switchTargets ?? [], id: \.self) { target in
                        Button(intent: intent("switch", target: target)) {
                            Image("Service-" + target)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .accessibilityHidden(true)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PauseTargetDisplay.name(for: target))
                    }
                }
            }
            HStack(spacing: 8) {
                if !(state.switchTargets ?? []).isEmpty {
                    Button(intent: intent(state.choosingApp == true ? "cancel" : "choose")) {
                        Label {
                            Text(state.choosingApp == true ? "Cancel" : "Switch app", tableName: "PauseActivity")
                                .lineLimit(2).multilineTextAlignment(.center)
                        } icon: {
                            Image(systemName: state.choosingApp == true ? "xmark" : "arrow.triangle.2.circlepath")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: state.choosingApp == true ? 30 : 36)
                    }
                    .buttonStyle(PauseControlStyle(color: sage))
                }
                Button(intent: intent("end")) {
                    Label {
                        Text("End pause", tableName: "PauseActivity")
                            .lineLimit(2).multilineTextAlignment(.center)
                    } icon: { Image(systemName: "stop.fill") }
                        .frame(maxWidth: .infinity)
                        .frame(height: state.choosingApp == true ? 30 : 36)
                }
                .buttonStyle(PauseControlStyle(color: .gray))
            }
            .font(.subheadline.weight(.semibold))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    private func intent(_ action: String, target: String = "") -> PauseActivityActionIntent {
        .init(id: id, source: state.target ?? "", action: action, target: target)
    }
}

/// Explicit geometry avoids the extra vertical padding of system bordered buttons.
/// The target icons, controls and header must fit the 160pt Live Activity.
private struct PauseControlStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .foregroundStyle(.white)
            .background(color.opacity(configuration.isPressed ? 0.4 : 0.22), in: Capsule())
            .contentShape(Capsule())
    }
}
