import SwiftUI

struct IOSWelcomeView: View {
    let isCompact: Bool
    var isDuo: Bool = false
    var authorized: Bool = false
    @AppStorage("iosWelcomeNotificationsHandled") private var notificationsHandled = false
    let requestAuthorization: () async -> Bool
    let onAuthorized: () -> Void
    let onSafari: () -> Void
    let onClose: () -> Void
    @State private var authorizationGranted = false
    @State private var requesting = false
    @State private var denied = false
    @State private var fittedHeight: CGFloat = 460
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var stepSize = 36

    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 36

    private var hasAuthorization: Bool { authorized || authorizationGranted }

    private var needsNotifications: Bool {
        if #available(iOS 26.5, *) { return false }
        return !notificationsHandled
    }

    private var compactDuo: Bool { isDuo && !isCompact && !dynamicTypeSize.isAccessibilitySize }

    private var canvas: Color {
        if compactDuo { return Color(uiColor: .systemBackground) }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.065, alpha: 1)
                : UIColor(red: 0.975, green: 0.971, blue: 0.961, alpha: 1)
        })
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: compactDuo ? 12 : 20) {
                        let headerLayout = compactDuo
                            ? AnyLayout(HStackLayout(alignment: .center, spacing: 16))
                            : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                        headerLayout {
                            Image(systemName: "leaf.fill")
                                .font(.system(size: compactDuo ? 24 : 30))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            Text(String(localized: "Set up\napp protection", table: "Interface"))
                                .font(.system(size: compactDuo ? 24 : titleSize, weight: .bold))
                                .tracking(-1)
                                .accessibilityAddTraits(.isHeader)
                            if compactDuo {
                                Spacer(minLength: 0)
                                closeButton
                            }
                        }

                        if needsNotifications {
                            ShieldNotificationPermissionView(onContinue: { notificationsHandled = true })
                        } else {
                            protectionSteps
                        }

                        if !compactDuo { Spacer(minLength: 0) }
                        if !needsNotifications { actions }
                    }
                    .frame(minHeight: max(0, compactDuo ? 0 : geometry.size.height - 32), alignment: .topLeading)
                    .padding(.horizontal, 24)
                    .padding(.top, compactDuo ? 20 : 8)
                    .padding(.bottom, compactDuo ? 16 : 24)
                    .frame(maxWidth: compactDuo ? 500 : 480)
                    .frame(maxWidth: .infinity)
                    .background {
                        if compactDuo {
                            GeometryReader { content in
                                Color.clear.preference(key: WelcomeHeightKey.self, value: content.size.height)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .background(canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(compactDuo ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    closeButton
                }
            }
        }
        .onPreferenceChange(WelcomeHeightKey.self) { height in
            if compactDuo { fittedHeight = min(590, max(460, ceil(height) + 8)) }
        }
        .modifier(WelcomePresentation(isCompact: isCompact, compactDuo: compactDuo, fittedHeight: fittedHeight))
    }

    private var closeButton: some View {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(String(localized: "Close", table: "Interface"))
                    .accessibilityIdentifier("welcome.close")
    }

    private var protectionSteps: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(1, title: String(localized: "Allow Screen Time", table: "Interface"),
                 detail: String(localized: "Allows Slowth to block the whole app when selected content is detected.", table: "Interface"),
                 active: !hasAuthorization)
            step(2, title: String(localized: "Choose apps and content", table: "Interface"),
                 detail: String(localized: "Content recognition happens only on your device.", table: "Interface"),
                 active: hasAuthorization)
            step(3, title: String(localized: "Enable blocking", table: "Interface"),
                 detail: String(localized: "Screen recording lets Slowth recognize short videos and stories on your device. You start it yourself.", table: "Interface"),
                 active: false, hasNext: false)
        }
        .padding(.vertical, compactDuo ? 0 : 8)
    }

    private func step(_ number: Int, title: String, detail: String? = nil, active: Bool, hasNext: Bool = true) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return layout {
            Text(number.formatted())
                .font(.body.weight(.medium))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .frame(width: compactDuo ? 28 : stepSize, height: compactDuo ? 28 : stepSize)
                .background(active ? Color.accentColor : Color.primary.opacity(0.06), in: Circle())
            VStack(alignment: .leading, spacing: compactDuo ? 3 : 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(active ? .primary : .secondary)
                    .frame(minHeight: compactDuo ? 28 : stepSize, alignment: .leading)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, hasNext ? (compactDuo ? 12 : 36) : 0)
        .background(alignment: .topLeading) {
            if hasNext && !dynamicTypeSize.isAccessibilitySize {
                // Use the entire measured row, including wrapped text and spacing.
                // Leave a small gap at both circles while following the row height.
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1)
                    .padding(.top, (compactDuo ? 28 : stepSize) + 5)
                    .padding(.bottom, 5)
                    .offset(x: ((compactDuo ? 28 : stepSize) - 1) / 2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if denied && !hasAuthorization {
                Text(String(localized: "Screen Time access was not granted. You can try again or continue without app protection.", table: "Interface"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("welcome.denied")
            }
            Button {
                if hasAuthorization { onAuthorized(); return }
                guard !requesting else { return }
                requesting = true
                Task { @MainActor in
                    let granted = await requestAuthorization()
                    requesting = false
                    if granted { authorizationGranted = true; denied = false } else { denied = true }
                }
            } label: {
                HStack {
                    Text(hasAuthorization
                         ? String(localized: "Choose apps and content", table: "Interface")
                         : denied
                         ? String(localized: "Try again", table: "Interface")
                         : String(localized: "Continue", table: "Interface"))
                        .fontWeight(.semibold)
                    if requesting { ProgressView().tint(.white) }
                }
                .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(requesting)
            .accessibilityIdentifier("welcome.continue")
            Text(hasAuthorization
                 ? String(localized: "Choose at least one app to start recording.", table: "Interface")
                 : String(localized: "A system Screen Time permission request will open.", table: "Interface"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 4) { secondaryActions }
            } else {
                HStack(spacing: 24) { secondaryActions }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        Button(action: onClose) {
            Text(String(localized: "Not now", table: "Interface"))
                .fontWeight(.semibold)
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("welcome.skip")
        Button(action: onSafari) {
            Text(String(localized: "Set up Safari", table: "Interface"))
                .font(.subheadline)
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("welcome.safari")
    }


}

private struct WelcomeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

@available(iOS 18.0, *)
private struct DuoWelcomeSizing: PresentationSizing {
    let height: CGFloat
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        ProposedViewSize(width: 500, height: height)
    }
}

private struct WelcomePresentation: ViewModifier {
    let isCompact: Bool
    let compactDuo: Bool
    let fittedHeight: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if compactDuo, #available(iOS 18.0, *) {
            content.presentationSizing(DuoWelcomeSizing(height: fittedHeight))
                .presentationDetents([.height(fittedHeight)])
                .presentationBackground(Color(uiColor: .systemBackground))
        } else if isCompact {
            content.presentationDetents([.large]).presentationDragIndicator(.visible)
        } else {
            content // Native centered, adaptive iPad sheet.
        }
    }
}

#if DEBUG
#Preview("Welcome · iPhone") {
    IOSWelcomeView(isCompact: true, requestAuthorization: { true },
        onAuthorized: {}, onSafari: {}, onClose: {})
}
#Preview("Welcome · iPad · dark") {
    IOSWelcomeView(isCompact: false, requestAuthorization: { true },
        onAuthorized: {}, onSafari: {}, onClose: {})
        .frame(width: 620, height: 760)
        .preferredColorScheme(.dark)
}
#Preview("Welcome · large text · RTL") {
    IOSWelcomeView(isCompact: true, requestAuthorization: { false },
        onAuthorized: {}, onSafari: {}, onClose: {})
        .environment(\.dynamicTypeSize, .accessibility3)
        .environment(\.layoutDirection, .rightToLeft)
        .environment(\.locale, Locale(identifier: "ar"))
}
#endif
