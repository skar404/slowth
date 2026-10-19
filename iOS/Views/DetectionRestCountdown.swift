import SwiftUI

/// Presentation only. The coordinator owns the clock and release permission.
struct DetectionRestCountdown: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let target: String
    let remaining: TimeInterval
    var compact = false
    private var appName: String {
        target == "youtube" ? "YouTube" : target == "x" ? "X" : target.capitalized
    }

    private var serviceIcon: some View {
        Image("Service-" + target)
            .resizable().scaledToFit().frame(width: compact ? 28 : 40, height: compact ? 28 : 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }

    private var lockIcon: some View {
        Image(systemName: "lock.fill").foregroundStyle(SlowthAppearance.sage)
            .accessibilityHidden(true)
    }

    private var appTitle: some View {
        Text(appName).font(compact ? .headline : .title2.weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.5)
    }

    var body: some View {
        VStack(spacing: compact ? 8 : 20) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        serviceIcon
                        Spacer(minLength: 0)
                        lockIcon
                    }
                    appTitle
                }
            } else {
                HStack(spacing: 12) {
                    serviceIcon
                    appTitle
                    Spacer(minLength: 0)
                    if compact { countdown } else { lockIcon }
                }
            }
            if !compact || dynamicTypeSize.isAccessibilitySize { countdown }
            Text(String(localized: "You can close Slowth — the countdown continues.", table: "Interface"))
                .font(compact ? .footnote : .subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, compact ? 0 : 12)
    }

    private var countdown: some View {
        Text(Duration.seconds(Int(ceil(remaining))).formatted(.time(pattern: .minuteSecond)))
            .font(.system(compact ? .title2 : .largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
            .foregroundStyle(SlowthAppearance.sage)
            .padding(.vertical, compact ? 0 : 12)
            .accessibilityIdentifier("rest.remaining")
    }
}

#if DEBUG
#Preview("Rest · 60 seconds") {
    Form { DetectionRestCountdown(target: "youtube", remaining: 60) }
}
#Preview("Rest · finishing · large text") {
    Form { DetectionRestCountdown(target: "instagram", remaining: 5) }
        .environment(\.dynamicTypeSize, .accessibility3)
        .preferredColorScheme(.dark)
}
#endif
