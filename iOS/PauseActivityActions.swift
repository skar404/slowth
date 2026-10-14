import ActivityKit
import AppIntents
import SwiftUI

@available(iOS 17.0, *)
struct PauseActivityActionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause controls"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Pause ID") var pauseID: String
    @Parameter(title: "Current app") var source: String
    @Parameter(title: "Action") var action: String
    @Parameter(title: "Destination app") var target: String

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
            throw error
        }
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct PauseActivityActions: View {
    let id: String
    let state: PauseActivityAttributes.ContentState
    private let sage = Color(red: 0.66, green: 0.81, blue: 0.62)
    private let labels = ["youtube": "YouTube", "instagram": "Instagram", "facebook": "Facebook", "x": "X"]

    var body: some View {
        VStack(spacing: 8) {
            if state.choosingApp == true {
                // At most three eligible alternatives; explicit target selection
                // keeps this deterministic even if eligibility changes after rendering.
                HStack(spacing: 6) {
                    ForEach(state.switchTargets ?? [], id: \.self) { target in
                        Button(intent: intent("switch", target: target)) {
                            Text(labels[target] ?? target)
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .tint(sage)
                    }
                }
            }
            HStack(spacing: 8) {
                if !(state.switchTargets ?? []).isEmpty {
                    Button(intent: intent(state.choosingApp == true ? "cancel" : "choose")) {
                        Label {
                            Text(state.choosingApp == true ? "Cancel" : "Switch app", tableName: "PauseActivity")
                        } icon: {
                            Image(systemName: state.choosingApp == true ? "xmark" : "arrow.triangle.2.circlepath")
                        }
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .tint(sage)
                }
                Button(intent: intent("end")) {
                    Label { Text("End pause", tableName: "PauseActivity") } icon: { Image(systemName: "stop.fill") }
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .tint(.gray)
            }
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
    }

    private func intent(_ action: String, target: String = "") -> PauseActivityActionIntent {
        .init(id: id, source: state.target ?? "", action: action, target: target)
    }
}
