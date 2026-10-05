import SwiftUI

/// Both iOS interface styles share this guide. Mac shows the Safari features.
struct HowItWorksSheet: View {
    let feedbackURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AppLocalization.string("How Slowth works"))
                            .font(.title2.weight(.bold))
                        Text(AppLocalization.string("Choose what you want to block."))
                            .foregroundStyle(.secondary)
                    }

                    safariCard
                    #if os(iOS)
                    inAppCard
                    screenAccessCard
                    #endif
                    HowItWorksCard(title: AppLocalization.string("Strict mode (24 h)"),
                                   icon: "lock.fill", tint: .orange) {
                        Text(AppLocalization.string("For 24 hours, enabled restrictions cannot be turned off. You can add restrictions, but cannot enable whole-site blocking. The timer survives restarts and force-quits."))
                    }
                    #if os(iOS)
                    HowItWorksCard(title: AppLocalization.string("Detection can make mistakes"),
                                   icon: "exclamationmark.circle", tint: .orange) {
                        Text(AppLocalization.string("Slowth may miss content or block a regular app screen by mistake. If this happens, you can report it using Send feedback below."))
                    }
                    #endif
                    Link(destination: feedbackURL) {
                        Label(AppLocalization.string("Send feedback"), systemImage: "envelope")
                    }
                }
                .padding(20)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(AppLocalization.string("How it works"))
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
        .frame(width: 560, height: 640)
        #endif
    }

    private var safariCard: some View {
        HowItWorksCard(title: "Safari", icon: "safari", tint: .blue) {
            Text(AppLocalization.string("Enable Slowth in Safari, then choose what to hide or block for each website."))
            Text(AppLocalization.string("Slowth blocks YouTube Shorts, Instagram and Facebook Reels, plus Explore and trends on X while leaving the rest of each site available."))
            DisclosureGroup(AppLocalization.string("Per-site control")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppLocalization.string("Infinite Feed limits scrolling. On Instagram it also includes Explore and Stories."))
                    Text(AppLocalization.string("TikTok is replaced with a friendly blocked page. You can opt any site into full block too."))
                }
                .padding(.top, 8)
            }
        }
    }

    #if os(iOS)
    private var inAppCard: some View {
        HowItWorksCard(title: AppLocalization.string("In-app blocking"),
                       icon: "iphone", tint: .indigo) {
            Text(InAppBlockingCopy.supportedContent)
            Text(InAppBlockingCopy.setup)
            Text(AppLocalization.string("Apps with blocking enabled stay blocked when screen recording is off. Soft YouTube mode can delay blocking."))
        }
    }

    private var screenAccessCard: some View {
        HowItWorksCard(title: AppLocalization.string("What happens to screen images"),
                       icon: "hand.raised.fill", tint: .green) {
            Text(AppLocalization.string("Slowth uses iOS screen recording to recognize Shorts, Reels, and Stories. While active, it receives images of your current screen, including other apps."))
            Text(ScreenRecordingCopy.privacyExplanation)
        }
    }
    #endif
}

private struct HowItWorksCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: icon).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
    }
}
