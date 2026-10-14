import ActivityKit
import SwiftUI
import WidgetKit

@main struct PauseActivityBundle: WidgetBundle {
    var body: some Widget { PauseActivityWidget() }
}

struct PauseActivityWidget: Widget {
    private let sage = Color(red: 0.66, green: 0.81, blue: 0.62)
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PauseActivityAttributes.self) { context in
            PauseActivityCard(service: context.state.service ?? context.attributes.service, safari: context.attributes.safari,
                phase: context.state.phase, startedAt: context.state.startedAt,
                expiresAt: context.state.expiresAt, stale: context.isStale,
                pauseID: context.attributes.pauseID, actionState: context.state)
            .activityBackgroundTint(Color(white: 0.10))
            .activitySystemActionForegroundColor(sage)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Slowth", systemImage: "leaf.fill").foregroundStyle(sage)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.service ?? context.attributes.service).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale || context.state.phase == "ending" {
                        Text("Open Slowth to check the pause", tableName: "PauseActivity")
                    } else if context.state.phase == "preparing" {
                        Text("Waiting for Safari extension", tableName: "PauseActivity")
                    } else {
                        VStack(spacing: 8) {
                            if context.state.choosingApp != true {
                                countdown(context).font(.title2.bold())
                            }
                            if #available(iOS 17.0, *) {
                                PauseActivityActions(id: context.attributes.pauseID, state: context.state)
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "leaf.fill").foregroundStyle(sage)
            } compactTrailing: {
                if context.isStale || context.state.phase != "active" {
                    Image(systemName: context.isStale ? "exclamationmark.circle" : "hourglass")
                } else {
                    countdown(context).frame(width: 48)
                }
            } minimal: {
                Image(systemName: context.isStale ? "exclamationmark.circle" : "leaf.fill")
                    .foregroundStyle(sage)
            }
            .keylineTint(sage)
        }
    }
    private func countdown(_ context: ActivityViewContext<PauseActivityAttributes>) -> some View {
        Text(timerInterval: context.state.startedAt...max(context.state.startedAt, context.state.expiresAt), countsDown: true)
            .monospacedDigit()
            .accessibilityLabel(Text("Time remaining", tableName: "PauseActivity"))
    }
}
