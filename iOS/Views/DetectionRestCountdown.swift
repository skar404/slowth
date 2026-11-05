import SwiftUI

/// Presentation only. The coordinator owns the clock and release permission.
struct DetectionRestCountdown: View {
    let target: String
    let remaining: TimeInterval
    let duration: TimeInterval
    private var finished: Bool { remaining <= 0 }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text(finished ? String(localized: "Pause finished", table: "Interface")
                     : String(localized: "Take a short pause", table: "Interface"))
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier(finished ? "rest.completed" : "rest.active")
                Text(PauseTargetDisplay.name(for: target))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                Circle().stroke(SlowthAppearance.sage.opacity(0.14), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: finished ? 1 : min(1, max(0, remaining / max(1, duration))))
                    .stroke(SlowthAppearance.sage, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if finished {
                    Image(systemName: "checkmark")
                        .font(.system(size: 36, weight: .medium))
                } else {
                    Text(Duration.seconds(Int(ceil(max(0, remaining)))).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                        .accessibilityLabel(String(localized: "Time remaining", table: "Interface"))
                        .accessibilityValue(Duration.seconds(Int(ceil(max(0, remaining)))).formatted(.time(pattern: .minuteSecond)))
                        .accessibilityIdentifier("rest.remaining")
                }
            }
            .foregroundStyle(SlowthAppearance.sage)
            .frame(width: 120, height: 120)
            .accessibilityHidden(finished)
            .padding(.vertical, 4)

            Text(finished
                 ? String(localized: "Leave the blocked content when you return, or another pause may begin.", table: "Interface")
                 : String(localized: "Slowth detected content you chose to block. Take a short break before returning to the app.", table: "Interface"))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(finished ? String(localized: "Return using the app switcher.", table: "Interface")
                 : String(localized: "You can close Slowth — the countdown continues.", table: "Interface"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("Pause · countdown") {
    DetectionRestCountdown(target: "apps", remaining: 12, duration: 15).padding(24)
}
#Preview("Pause · finished · large text") {
    DetectionRestCountdown(target: "apps", remaining: 0, duration: 15).padding(24)
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}
#endif
