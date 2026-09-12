#if os(iOS)
import SwiftUI

struct RealtimeBlockingBetaSheet: View {
    let feedbackURL: URL

    @Environment(\.dismiss) private var dismiss

    private let sourceCodeURL = URL(string: "https://github.com/skar404/slowth")!

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header

                    Text("Block YouTube Shorts, Instagram Reels, and Instagram Stories while keeping regular app screens available during an active screen recording.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 16) {
                        RealtimeBetaInfoRow(
                            icon: "gearshape.2.fill",
                            tint: .indigo,
                            title: "How it works",
                            detail: "Choose YouTube or Instagram in Screen Time, then enable each content type you want to block. Enabled apps stay blocked until you start screen recording in Slowth."
                        )
                        RealtimeBetaInfoRow(
                            icon: "hand.raised.fill",
                            tint: .blue,
                            title: "Private by design",
                            detail: "Screen frames are analyzed entirely on your device and never uploaded. By default nothing is saved; confirmed frames are saved only after explicitly enabling hidden debug capture."
                        )
                        RealtimeBetaInfoRow(
                            icon: "record.circle",
                            tint: .red,
                            title: "Recording indicator",
                            detail: "iOS shows a red recording indicator while monitoring is active. This is required by the system."
                        )
                    }

                    betaNote
                    feedbackCard
                    openSourceCard
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Real-time blocking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "record.circle.fill")
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.24, blue: 0.34),
                                 Color(red: 0.79, green: 0.12, blue: 0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 7) {
                Text("Real-time blocking")
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("BETA")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.pink, in: Capsule())
                    .accessibilityLabel("Beta")
            }
        }
    }

    private var betaNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("This feature is experimental and may occasionally block the wrong screen or miss Shorts, Reels, or Stories.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var openSourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Open source", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.headline)

            Text("Slowth is open source. You can inspect the app and its on-device detection pipeline on GitHub.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: sourceCodeURL) {
                Label("View source code", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        }
        .realtimeBetaCardStyle()
    }

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Help improve the Beta", systemImage: "bubble.left.and.bubble.right.fill")
                .font(.headline)

            Text("If Slowth blocked the wrong screen, missed blocked content, or setup didn’t work, tell me what happened.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: feedbackURL) {
                Label("Send Beta feedback", systemImage: "envelope.fill")
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .controlSize(.large)
        }
        .realtimeBetaCardStyle()
    }
}

private struct RealtimeBetaInfoRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension View {
    func realtimeBetaCardStyle() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
#endif
