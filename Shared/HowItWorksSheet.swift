import SwiftUI

/// Both iOS interface styles share this guide. Mac shows the Safari features.
struct HowItWorksSheet: View {
    let feedbackURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(AppLocalization.string("How Slowth works"))
                                .font(.title2.weight(.bold))
                            Text(AppLocalization.string("Choose what you want to block."))
                                .foregroundStyle(.secondary)
                        }

                        #if os(iOS)
                        inAppCard.id("apps")
                        appRulesCard.id("rules")
                        monitoringCard.id("monitoring")
                        detectionPauseCard.id("pause")
                        temporaryAccessCard.id("access")
                        leavesCard.id("leaves")
                        screenAccessCard.id("privacy")
                        #endif
                        safariCard.id("safari")
                        HowItWorksCard(title: AppLocalization.string("Strict mode (24 h)"),
                                       icon: "lock.fill", tint: .orange) {
                            Text(AppLocalization.string("For 24 hours, enabled restrictions cannot be turned off. You can add restrictions, but cannot enable whole-site blocking. The timer survives restarts and force-quits."))
                            #if os(iOS)
                            guideItem(title: String(localized: "Allow pauses in Strict mode", table: "Interface"),
                                      text: String(localized: "Enable this before Strict mode if you want temporary access during its 24-hour lock.", table: "Interface"))
                            #endif
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
                #if DEBUG && targetEnvironment(simulator)
                .onAppear {
                    let args = ProcessInfo.processInfo.arguments
                    if let index = args.firstIndex(of: "--preview-how-it-works-section"), args.indices.contains(index + 1) {
                        // Scroll the actual guide for localized layout checks only.
                        DispatchQueue.main.async { reader.scrollTo(args[index + 1], anchor: .top) }
                    }
                }
                #endif
            }
            .navigationTitle(AppLocalization.string("How it works"))
            .accessibilityIdentifier("help.how-it-works")
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
                    Text(AppLocalization.string("Off — the extension does nothing. YouTube blocks Shorts; Instagram and Facebook block Reels; X blocks Explore and trends. Instagram and Facebook also offer a feed mode; Instagram’s includes Explore, Stories, and additional Reels surfaces. Block site redirects the whole site."))
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
            Text(String(localized: "Screen Time is needed for app protection. You choose apps and settings after allowing access.", table: "Interface"))
            Text(String(format: String(localized: "Select up to %d apps to enable blocking.", table: "Interface"),
                        BlockingRules.maximumSelectedApplications))
            Text(String(localized: "Tap an app to choose its content rules.", table: "Interface"))
            Text(String(localized: "Choose apps or categories. Only apps are saved; websites are ignored. Reselect a category after installing new apps.", table: "Interface"))
        }
    }

    private var appRulesCard: some View {
        HowItWorksCard(title: String(localized: "Block", table: "Interface"), icon: "slider.horizontal.3", tint: .indigo) {
            guideItem(title: String(localized: "Short videos (Shorts / Reels)", table: "Interface")
                        + " · " + String(localized: "Stories", table: "Interface"),
                      text: String(localized: "New apps block both content types. Soft blocking is off by default.", table: "Interface"))
            Text(String(localized: "Example: block Reels, but allow Stories by turning Stories off for that app.", table: "Interface"))
            guideItem(title: String(localized: "Soft blocking", table: "Interface"),
                      text: String(localized: "Without recording, briefly allow this app after leaving Slowth, then block it again when used.", table: "Interface"))
            Text(AppLocalization.string("Soft mode works well for audio podcasts. Picture in Picture may still be blocked when screen recording is off."))
        }
    }

    private var monitoringCard: some View {
        HowItWorksCard(title: String(localized: "Monitoring", table: "Interface"), icon: "record.circle", tint: .green) {
            guideItem(title: String(localized: "Start monitoring", table: "Interface"),
                      text: String(localized: "To detect short videos inside apps, start screen recording separately from the Apps tab. Allowing Screen Time does not start a recording.", table: "Interface"))
            Text(String(localized: "During recording, content rules apply separately to each app. Without recording, apps are blocked unless soft blocking is enabled. Allow content temporarily opens the whole group.", table: "Interface"))
            guideItem(title: String(localized: "Stop monitoring", table: "Interface"),
                      text: String(localized: "iOS shows a recording indicator while screen access is active. To stop, return to Slowth, tap Stop monitoring, and confirm in the system prompt.", table: "Interface"))
        }
    }

    private var detectionPauseCard: some View {
        HowItWorksCard(title: String(localized: "Take a short pause", table: "Interface"), icon: "hourglass", tint: .green) {
            Text(String(localized: "Slowth detected content you chose to block. Take a short break before returning to the app.", table: "Interface"))
            Text(String(format: String(localized: "Automatic pauses last %d–%d seconds and do not use leaves.", table: "Interface"),
                        IOSPauseLedger.restSecondSteps.min() ?? 5, IOSPauseLedger.restSecondSteps.max() ?? 15))
            Text(String(localized: "You can close Slowth — the countdown continues.", table: "Interface"))
            Text(String(localized: "Leave the blocked content when you return, or another pause may begin.", table: "Interface"))
        }
    }

    private var temporaryAccessCard: some View {
        HowItWorksCard(title: String(localized: "Allow content", table: "Interface"), icon: "lock.open", tint: .orange) {
            Text(String(localized: "Use 1 leaf to temporarily allow blocked content.", table: "Interface"))
            Text(String(localized: "Example: allow content for 1 minute in all selected apps, then blocking returns.", table: "Interface"))
            guideItem(title: String(localized: "Block again", table: "Interface"),
                      text: String(localized: "Block again ends access early. It does not refund the leaf.", table: "Interface"))
        }
    }

    private var leavesCard: some View {
        HowItWorksCard(title: String(localized: "Pauses today", table: "Interface"), icon: "leaf", tint: .green) {
            Text(String(localized: "Experimental: apps and Safari share 3 pauses. Recording is not required. iOS may delay restoring restrictions.", table: "Interface"))
            guideItem(title: String(localized: "Settings", table: "Interface") + " → "
                        + String(localized: "Pause duration", table: "Interface"),
                      text: String(localized: "30 sec", table: "Interface") + " · "
                        + String(format: String(localized: "%lld min", table: "Interface"), 1)
                        + " · " + String(format: String(localized: "%lld min", table: "Interface"), 3))
            Text(String(localized: "Applies to new pauses in apps and Safari.", table: "Interface"))
            guideItem(title: String(localized: "Saved leaves", table: "Interface"),
                      text: String(localized: "Unused leaves are saved after each day as a reward.", table: "Interface"))
            Text(String(localized: "Saved leaves are a reward counter, not extra access.", table: "Interface"))
        }
    }

    private var screenAccessCard: some View {
        HowItWorksCard(title: AppLocalization.string("What happens to screen images"),
                       icon: "hand.raised.fill", tint: .green) {
            Text(AppLocalization.string("Slowth uses iOS screen recording to recognize Shorts, Reels, and Stories. While active, it receives images of your current screen, including other apps."))
            Text(AppLocalization.string("Selecting apps controls blocking, but screen access can include any app and sensitive information."))
            Text(ScreenRecordingCopy.privacyExplanation)
        }
    }

    private func guideItem(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(text)
        }
    }
    #endif
}

#if os(iOS)
struct ScreenRecordingSafetySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HowItWorksCard(title: AppLocalization.string("What Slowth can see"),
                                   icon: "eye.fill", tint: .teal) {
                        Text(AppLocalization.string("Slowth uses iOS screen recording to recognize Shorts, Reels, and Stories. While active, it receives images of your current screen, including other apps."))
                        Text(AppLocalization.string("Selecting apps controls blocking, but screen access can include any app and sensitive information."))
                    }
                    HowItWorksCard(title: AppLocalization.string("What happens to screen images"),
                                   icon: "hand.raised.fill", tint: .teal) {
                        Text(ScreenRecordingCopy.privacyExplanation)
                    }
                    HowItWorksCard(title: AppLocalization.string("Stopping screen access"),
                                   icon: "record.circle", tint: .red) {
                        Text(String(localized: "iOS shows a recording indicator while screen access is active. To stop, return to Slowth, tap Stop monitoring, and confirm in the system prompt.", table: "Interface"))
                    }
                }
                .padding(20)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(String(localized: "Safety", table: "Interface"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
    }
}
#endif

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

#if DEBUG
#Preview("How it works") {
    if let url = URL(string: "https://github.com/skar404/slowth/issues") {
        HowItWorksSheet(feedbackURL: url)
    }
}
#endif
