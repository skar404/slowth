import SwiftUI

/// The same content is used by WidgetKit and the simulator-only visual preview.
@available(iOS 16.2, *)
struct PauseActivityCard: View {
    let service: String
    let safari: Bool
    let phase: String
    let startedAt: Date
    let expiresAt: Date
    let stale: Bool
    var pauseID: String? = nil
    var actionState: PauseActivityAttributes.ContentState? = nil
    private let sage = Color(red: 0.66, green: 0.81, blue: 0.62)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if actionState?.choosingApp != true || stale || phase != "active" {
                HStack {
                    Label("Slowth", systemImage: "leaf.fill").foregroundStyle(sage)
                    Spacer()
                    Text(service + (safari ? " · Safari" : "")).font(.headline)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
            if stale {
                Text("Open Slowth to check the pause", tableName: "PauseActivity").font(.subheadline)
            } else if phase == "preparing" {
                Text("Waiting for Safari extension", tableName: "PauseActivity").font(.subheadline)
            } else if phase == "active" && actionState?.choosingApp != true {
                HStack {
                    Text("Pause", tableName: "PauseActivity")
                    Spacer()
                    Text(timerInterval: startedAt...max(startedAt, expiresAt), countsDown: true)
                        .font(.title2.bold()).monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(Text("Time remaining", tableName: "PauseActivity"))
                }
            } else if phase != "active" {
                Text("Open Slowth to check the pause", tableName: "PauseActivity")
            }
            if #available(iOS 17.0, *), !stale, phase == "active",
               let pauseID, let actionState {
                PauseActivityActions(id: pauseID, state: actionState)
            }
        }
        .padding(actionState?.choosingApp == true ? 12 : 16)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .foregroundStyle(.white)
    }
}

#if DEBUG && targetEnvironment(simulator)
@available(iOS 16.2, *)
struct PauseActivityPreviewScreen: View {
    private let start = Date()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Live Activity").font(.largeTitle.bold())
                Text("Предпросмотр оформления. Это не системная плашка и не запущенная пауза.")
                    .font(.callout).foregroundStyle(.secondary)
                card("Таймер паузы", phase: "active", stale: false)
                card("Выбор приложения", phase: "active", stale: false, choosing: true)
                card("Ожидание Safari", phase: "preparing", stale: false)
                card("Нет свежего подтверждения", phase: "active", stale: true)
            }.padding(20)
        }.background(Color(white: 0.04)).preferredColorScheme(.dark)
    }
    private func card(_ title: String, phase: String, stale: Bool, choosing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            PauseActivityCard(service: "Instagram", safari: phase == "preparing", phase: phase,
                startedAt: start, expiresAt: start.addingTimeInterval(180), stale: stale,
                pauseID: "preview-only", actionState: .init(phase: phase, startedAt: start,
                    expiresAt: start.addingTimeInterval(180), service: "Instagram", target: "instagram",
                    switchTargets: ["youtube", "facebook", "x", "tiktok", "snapchat"], choosingApp: choosing ? true : nil))
                .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
#endif

#if DEBUG
#Preview("Pause · active") {
    if #available(iOS 16.2, *) {
        PauseActivityCard(service: "YouTube", safari: false, phase: "active",
            startedAt: .now, expiresAt: .now.addingTimeInterval(180), stale: false)
            .background(Color.black).padding()
    }
}
#Preview("Pause · Safari preparing") {
    if #available(iOS 16.2, *) {
        PauseActivityCard(service: "Instagram", safari: true, phase: "preparing",
            startedAt: .now, expiresAt: .now.addingTimeInterval(180), stale: false)
            .background(Color.black).padding()
    }
}
#Preview("Pause · stale") {
    if #available(iOS 16.2, *) {
        PauseActivityCard(service: "YouTube", safari: false, phase: "active",
            startedAt: .now, expiresAt: .now.addingTimeInterval(180), stale: true)
            .background(Color.black).padding()
    }
}
#endif
