import SwiftUI

// Keep the recording card and the detailed explanation consistent.
enum ScreenRecordingCopy {
    static var privacyExplanation: String {
        #if DEBUG
        return AppLocalization.string("Screen images are analyzed on your device to recognize the content you chose to block. Audio is ignored.")
        #else
        return AppLocalization.string("Slowth does not save a screen recording. Screen images are analyzed temporarily in your device’s memory and are not saved to your device or uploaded. Audio is ignored.")
        #endif
    }
}

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
                            icon: "iphone.gen3",
                            tint: .orange,
                            title: AppLocalization.string("Why screen recording?"),
                            detail: AppLocalization.string("Slowth needs screen images to recognize Shorts, Reels, and Stories inside other apps. To receive these images, it uses the iOS screen recording feature. You start this access yourself through the system broadcast prompt.")
                        )
                        RealtimeBetaInfoRow(
                            icon: "eye.fill",
                            tint: .orange,
                            title: AppLocalization.string("What Slowth can see"),
                            detail: AppLocalization.string("While screen recording is active, Slowth receives images of your current screen, which can include other apps and sensitive information shown on screen. Choosing YouTube or Instagram sets which apps to block; it does not limit screen access to those apps.")
                        )
                        RealtimeBetaInfoRow(
                            icon: "hand.raised.fill",
                            tint: .blue,
                            title: AppLocalization.string("What happens to screen images"),
                            detail: ScreenRecordingCopy.privacyExplanation
                        )
                        RealtimeBetaInfoRow(
                            icon: "gearshape.2.fill",
                            tint: .indigo,
                            title: AppLocalization.string("How blocking works"),
                            detail: AppLocalization.string("Choose YouTube or Instagram in Screen Time, then enable the content types you want to block. Start screen recording to use the apps while detection runs. When Slowth detects selected content, Screen Time blocks the entire app, not just that video or story.")
                        )
                        RealtimeBetaInfoRow(
                            icon: "record.circle",
                            tint: .red,
                            title: AppLocalization.string("Stopping screen access"),
                            detail: AppLocalization.string("iOS shows a recording indicator while screen access is active. To stop, return to Slowth and tap the active recording card, then confirm in the system prompt. Screen analysis stops, and apps with blocking enabled are blocked again. Soft YouTube mode can delay the YouTube block to let audio continue; Picture in Picture may still be blocked.")
                        )

                        RealtimeBetaInfoRow(
                            icon: "exclamationmark.circle",
                            tint: .orange,
                            title: AppLocalization.string("Detection can make mistakes"),
                            detail: AppLocalization.string("Slowth may miss content or block a regular app screen by mistake. If this happens, you can report it using Send feedback below.")
                        )
                        RealtimeBetaInfoRow(
                            icon: "safari",
                            tint: .blue,
                            title: AppLocalization.string("Prefer not to share your screen?"),
                            detail: AppLocalization.string("Use Slowth’s Safari extension to block content on supported websites without screen recording. It works in Safari, not inside the YouTube or Instagram apps.")
                        )

                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(AppLocalization.string("1. ReplayKit sends video frames to the broadcast extension. Audio is ignored."))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(AppLocalization.string("2. Slowth analyzes one frame about every 0.25 seconds (around 4 analyses per second). Each frame is resized in memory to 192 × 384 pixels in RGB format for the Core ML model."))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(AppLocalization.string("3. The cascade first identifies the app, then runs the relevant Shorts, Reels, or Stories detector. A block is confirmed after 3 positive results within a 5-analysis window, which helps avoid reacting to a single uncertain frame."))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(AppLocalization.string("Slowth Cascade V6 is an on-device Core ML model trained to recognize supported app screens and content types."))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(AppLocalization.string("4. Once detection is confirmed, Screen Time shows a blocking screen over the selected app. Slowth does not remove individual videos or stories from its feed."))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Link(destination: sourceCodeURL) {
                                    Label(AppLocalization.string("View source on GitHub"), systemImage: "arrow.up.right.square")
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            Label(AppLocalization.string("Technical details"), systemImage: "wrench.and.screwdriver.fill")
                                .font(.headline)
                        }
                        .tint(.primary)
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
            .navigationTitle(AppLocalization.string("In-app blocking"))
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
        AppLocalization.string("On iPhone and iPad, Slowth can detect YouTube Shorts, Instagram Reels, and Instagram Stories and block the app when your selected content appears. This uses screen access that you start and stop.")
    }

    private var headerTitle: String {
        #if os(macOS)
        return AppLocalization.string("New on iOS")
        #else
        return AppLocalization.string("In-app blocking")
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
