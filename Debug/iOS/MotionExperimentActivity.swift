#if DEBUG && os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 16.2, *)
struct MotionExperimentAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var label: String
        var ended: Bool = false
    }
    let sessionID: String
    let startsAt: Date
    let endsAt: Date
}

@available(iOS 17.0, *)
struct MotionExperimentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark motion experiment"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false
    @Parameter(title: "Session") var sessionID: String
    @Parameter(title: "Action") var action: String
    init() {}
    init(sessionID: String, action: String) {
        self.sessionID = sessionID
        self.action = action
    }
    func perform() async throws -> some IntentResult {
        #if !PAUSE_ACTIVITY_WIDGET
        try await MotionExperimentStore.shared.mark(sessionID: sessionID, action: action)
        #endif
        return .result()
    }
}

@available(iOS 16.2, *)
struct MotionExperimentWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MotionExperimentAttributes.self) { context in
            content(context)
                .padding()
                .activityBackgroundTint(Color(white: 0.10))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) { content(context) }
            } compactLeading: {
                Image(systemName: "waveform.path")
            } compactTrailing: {
                if context.isStale || context.state.ended {
                    Image(systemName: "checkmark")
                } else {
                    Text(timerInterval: context.attributes.startsAt...context.attributes.endsAt, countsDown: true)
                        .monospacedDigit().frame(width: 44)
                }
            } minimal: {
                Image(systemName: "waveform.path")
            }
        }
    }

    private func content(_ context: ActivityViewContext<MotionExperimentAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Motion experiment").font(.headline)
            if context.isStale || context.state.ended {
                Text("Session ended. Open Slowth to load graphs.")
            } else {
                HStack {
                    Text(context.state.label)
                    Spacer()
                    Text(timerInterval: context.attributes.startsAt...context.attributes.endsAt, countsDown: true)
                        .monospacedDigit()
                }
                Text("Recording requested · samples checked in Slowth").font(.caption)
                if #available(iOS 17.0, *) {
                    HStack {
                        control("Scroll", action: "scroll", context: context)
                        control("Read", action: "read", context: context)
                        control("Type", action: "type", context: context)
                    }
                    HStack {
                        control("Walk", action: "walk", context: context)
                        control("Still", action: "still", context: context)
                        control("End", action: "end", context: context)
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }

    @available(iOS 17.0, *)
    private func control(_ title: String, action: String,
                         context: ActivityViewContext<MotionExperimentAttributes>) -> some View {
        Button(intent: MotionExperimentIntent(sessionID: context.attributes.sessionID, action: action)) {
            Text(verbatim: title).font(.caption).frame(maxWidth: .infinity)
        }.buttonStyle(.bordered)
    }
}
#endif
