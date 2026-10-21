import SwiftUI

struct IOSFeatureCard: View {
    @ScaledMetric(relativeTo: .title3) private var cardWidth = 180.0
    let title: String
    let subtitle: String
    let icon: String
    let gradient: [Color]
    let action: (() -> Void)?
    var compact = false
    var flexible = false
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action = action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .padding(8)
                        .frame(minWidth: 44, minHeight: 44, alignment: .topTrailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Hide card"))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if compact {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            standardContent
        }
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.18), in: Circle())
            Spacer(minLength: 8)
            Text(title)
                .font(flexible ? .headline : .title3.bold())
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(width: flexible ? nil : cardWidth, alignment: .leading)
        .frame(maxWidth: flexible ? .infinity : nil, alignment: .leading)
        .frame(minHeight: flexible ? 130 : 145, alignment: .leading)
        .background(
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: gradient.last?.opacity(0.25) ?? .clear, radius: 6, y: 3)
    }
}

#if DEBUG
#Preview("Feature card") {
    IOSFeatureCard(title: "Safari", subtitle: "Choose the content to hide", icon: "safari",
        gradient: [.green, .teal], action: {})
        .padding()
}
#Preview("Feature card · large text") {
    IOSFeatureCard(title: "Support Slowth", subtitle: "Help improve the app", icon: "heart.fill",
        gradient: [.pink, .purple], action: {}, onDismiss: {})
        .environment(\.dynamicTypeSize, .accessibility2)
        .padding()
}
#endif
