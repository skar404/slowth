import SwiftUI

struct RealtimeBlockingBetaSheet: View {
    let feedbackURL: URL

    @Environment(\.dismiss) private var dismiss

    private let sourceCodeURL = URL(string: "https://github.com/skar404/slowth")!
    private let iOSAppStoreURL = URL(string: "https://apps.apple.com/app/id6764140763")!

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header

                    Text(introduction)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 16) {
                        RealtimeBetaInfoRow(
                            icon: "gearshape.2.fill",
                            tint: .indigo,
                            title: AppLocalization.string("How it works"),
                            detail: AppLocalization.string("On iPhone or iPad, choose YouTube or Instagram in Screen Time, then enable each content type you want to block. Enabled apps stay blocked until you start screen recording in Slowth.")
                        )
                        RealtimeBetaInfoRow(
                            icon: "hand.raised.fill",
                            tint: .blue,
                            title: AppLocalization.string("Private by design"),
                            detail: AppLocalization.string("Screen frames are analyzed entirely on your device and never uploaded. By default nothing is saved; confirmed frames are saved only after explicitly enabling hidden debug capture.")
                        )
                        RealtimeBetaInfoRow(
                            icon: "record.circle",
                            tint: .red,
                            title: AppLocalization.string("Recording indicator"),
                            detail: AppLocalization.string("iOS shows a red recording indicator while monitoring is active. This is required by the system.")
                        )
                    }

                    #if os(macOS)
                    iOSAppStoreCard
                    #endif
                    feedbackCard
                    openSourceCard
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(AppLocalization.string("Real-time blocking"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 620)
        #endif
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
                Text(headerTitle)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var introduction: String {
        #if os(macOS)
        return AppLocalization.string("Slowth for iOS now includes real-time blocking for YouTube Shorts, Instagram Reels, and Instagram Stories. Regular app screens remain available while monitoring is active.")
        #else
        return AppLocalization.string("Block YouTube Shorts, Instagram Reels, and Instagram Stories while keeping regular app screens available during an active screen recording. Soft YouTube mode works well for audio podcasts, but Picture in Picture may still be blocked when screen recording is off.")
        #endif
    }

    private var headerTitle: String {
        #if os(macOS)
        return AppLocalization.string("New on iOS")
        #else
        return AppLocalization.string("Real-time blocking")
        #endif
    }

    private var openSourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(AppLocalization.string("Open source"), systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.headline)

            Text(AppLocalization.string("Slowth is open source. You can inspect the app and its on-device detection pipeline on GitHub."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: sourceCodeURL) {
                Label(AppLocalization.string("View source code"), systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        }
        .realtimeBetaCardStyle()
    }

    #if os(macOS)
    private var iOSAppStoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppLocalization.string("Try it on iOS"), systemImage: "iphone")
                .font(.headline)

            Text(AppLocalization.string("Real-time blocking is available in Slowth for iPhone and iPad."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Link(destination: iOSAppStoreURL) {
                Label(AppLocalization.string("View on the App Store"), systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .realtimeBetaCardStyle()
    }
    #endif

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(AppLocalization.string("Help improve real-time blocking"), systemImage: "bubble.left.and.bubble.right.fill")
                .font(.headline)

            Text(AppLocalization.string("If Slowth blocked the wrong screen, missed blocked content, or setup didn’t work, tell me what happened."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Link(destination: feedbackURL) {
                Label(AppLocalization.string("Send feedback"), systemImage: "envelope.fill")
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
