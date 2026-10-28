#if canImport(FamilyControls)
import SwiftUI
import ReplayKit

private final class ChromeHidingBroadcastPickerView: RPSystemBroadcastPickerView {
    var hostEnabled = true { didSet { refreshReadiness() } }
    private var readinessTimer: Timer?

    private func refreshReadiness() {
        let active = AppGroup.defaults.bool(forKey: SharedStoreKey.broadcastActive)
        let enabled = active || (hostEnabled && SharedStore.hasRecordingSelection())
        isUserInteractionEnabled = enabled
        alpha = enabled ? 1 : 0.4
        for button in subviews.compactMap({ $0 as? UIButton }) { button.isEnabled = enabled }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        refreshReadiness()
        return super.hitTest(point, with: event)
    }

    var hidesSystemControlChrome = false {
        didSet {
            setNeedsLayout()
            hideSystemControlChromeIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hideSystemControlChromeIfNeeded()
        if hidesSystemControlChrome {
            // ReplayKit's default button is only icon-sized. Match the row's
            // bounds without extending into the separate help or pause controls.
            subviews.compactMap { $0 as? UIButton }.forEach { $0.frame = bounds }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        readinessTimer?.invalidate()
        readinessTimer = nil
        refreshReadiness()
        if window != nil {
            readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.refreshReadiness()
            }
        }
        hideSystemControlChromeIfNeeded()
    }

    private func hideSystemControlChromeIfNeeded() {
        guard hidesSystemControlChrome else { return }
        Self.hideSystemControlChrome(in: self)
    }

    private static func hideSystemControlChrome(in view: UIView) {
        view.backgroundColor = .clear

        if let imageView = view as? UIImageView {
            // ReplayKit changes this image when broadcasting starts. Keeping
            // the image view transparent prevents the active-state glyph from
            // reappearing even when the system unhides or updates it later.
            imageView.isHidden = true
            imageView.alpha = 0
            imageView.layer.opacity = 0
        }

        if let button = view as? UIButton {
            button.tintColor = .clear
            button.backgroundColor = .clear
            button.imageView?.isHidden = true
            button.imageView?.alpha = 0
            button.imageView?.layer.opacity = 0
            button.titleLabel?.isHidden = true
            button.titleLabel?.alpha = 0
        }

        view.subviews.forEach { hideSystemControlChrome(in: $0) }
    }
}

// SwiftUI wrapper for the system broadcast picker button. Tapping it starts
// (or stops) the ReplayKit broadcast session backed by UnscrollBroadcastIOS —
// there's no in-app way to start a broadcast except through this system UI.
struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtensionBundleID: String
    var showsSystemControl = true
    var accessibilityLabel = String(localized: "Start or stop screen recording")

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        let picker = ChromeHidingBroadcastPickerView(frame: container.bounds)
        picker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        configure(picker, isEnabled: context.environment.isEnabled)
        container.addSubview(picker)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let picker = uiView.subviews.first as? ChromeHidingBroadcastPickerView else {
            return
        }
        configure(picker, isEnabled: context.environment.isEnabled)
    }

    private func configure(_ picker: ChromeHidingBroadcastPickerView, isEnabled: Bool) {
        picker.preferredExtension = preferredExtensionBundleID
        picker.showsMicrophoneButton = false
        picker.tintColor = showsSystemControl ? .systemRed : .clear
        picker.backgroundColor = .clear
        picker.hidesSystemControlChrome = !showsSystemControl
        picker.isAccessibilityElement = false
        for button in picker.subviews.compactMap({ $0 as? UIButton }) {
            button.accessibilityLabel = accessibilityLabel
            button.accessibilityTraits = .button
        }
        // Custom UIViewRepresentables don't automatically honor SwiftUI's
        // .disabled()/environment isEnabled — apply it manually so a
        // disabled BroadcastPickerView is actually untappable, not just
        // visually dimmed by a modifier with no effect on the UIButton.
        picker.hostEnabled = isEnabled
    }
}

/// Compact ReplayKit control for the system toolbar on Duo. The actual tap
/// stays with RPSystemBroadcastPickerView, including its start/stop confirmation.
struct RecordingToolbarButton: View {
    let preferredExtensionBundleID: String
    @State private var isRecording = SharedStore.snapshot().broadcastActive
    @State private var hasSelection = SharedStore.hasRecordingSelection()

    var body: some View {
        Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
            .font(.title2)
            .foregroundStyle(.red)
            .opacity(isRecording || hasSelection ? 1 : 0.4)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            .overlay {
                BroadcastPickerView(
                    preferredExtensionBundleID: preferredExtensionBundleID,
                    showsSystemControl: false,
                    accessibilityLabel: isRecording
                        ? String(localized: "Stop screen recording")
                        : String(localized: "Enable blocking", table: "Interface")
                )
                .accessibilityIdentifier("duo.recording")
            }
            .task {
                while !Task.isCancelled {
                    isRecording = SharedStore.snapshot().broadcastActive
                    hasSelection = SharedStore.hasRecordingSelection()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
    }
}

/// One shared outline; each child owns only its own controls and hit area.
struct RecordingPauseCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .background(SlowthAppearance.card)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Shared recording row for the main screen and the Shield handoff.
// Presentation-only fixture for local marketing captures. Never sets SharedStore,
// Screen Time authorization, ReplayKit state, or the durable pause ledger.
enum ScreenshotPresentation {
    static var activeProtection: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--screenshot-active-protection")
        #else
        false
        #endif
    }
}

struct AppRecordingCard: View {
    let preferredExtensionBundleID: String
    let isRecording: Bool
    let onLearnMore: () -> Void
    var showsPause = false
    var pauseTarget: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            RealtimeRecordingCard(
                preferredExtensionBundleID: preferredExtensionBundleID,
                isRecording: isRecording,
                guidance: String(localized: "Screen recording helps detect and block short videos.", table: "Interface"),
                embedded: true,
                headerOnly: showsPause,
                onLearnMore: onLearnMore
            )
            if showsPause {
                PausePanel(safari: false, preferredTarget: pauseTarget, embedded: true,
                           compact: true, sharedBackground: true,
                           recordingExtensionBundleID: preferredExtensionBundleID,
                           isRecording: isRecording)
            }
        }
    }
}

struct RealtimeRecordingCard: View {
    let preferredExtensionBundleID: String
    let isRecording: Bool
    let guidance: String
    var prominent = false
    var embedded = false
    var headerOnly = false
    var actionOnly = false
    var onLearnMore: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var observedRecording: Bool?
    @State private var hasSelection = SharedStore.hasRecordingSelection()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !actionOnly {
                HStack(alignment: .center, spacing: 8) {
                    Text(displayedRecording
                         ? String(localized: "Screen recording is active")
                         : hasSelection ? guidance
                         : String(localized: "Choose at least one app to start recording.", table: "Interface"))
                        .font(displayedRecording ? .subheadline.weight(.semibold) : .footnote)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let onLearnMore {
                        Button(action: onLearnMore) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.secondary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "How it works"))
                        .accessibilityIdentifier("recording.help")
                    }
                }
            }
            if !headerOnly {
                Label(displayedRecording
                      ? String(localized: "Stop screen recording")
                      : String(localized: "Enable blocking", table: "Interface"),
                      systemImage: displayedRecording ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .foregroundStyle(displayedRecording || colorScheme == .light ? Color.white : Color.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: prominent ? 56 : 48,
                           maxHeight: actionOnly ? .infinity : nil)
                    .background(displayedRecording ? Color.red : SlowthAppearance.sage,
                                in: RoundedRectangle(cornerRadius: 14))
                    .opacity(displayedRecording || hasSelection ? 1 : 0.5)
                    .accessibilityHidden(true)
                    .overlay {
                        // The native ReplayKit button owns just this visible button,
                        // never the explanatory copy, help button or pause controls.
                        BroadcastPickerView(
                            preferredExtensionBundleID: preferredExtensionBundleID,
                            showsSystemControl: false,
                            accessibilityLabel: displayedRecording
                                ? String(localized: "Stop screen recording")
                                : String(localized: "Enable blocking", table: "Interface")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("recording.action")
                    }
            }
        }
        .padding(actionOnly ? 0 : prominent ? 20 : 16)
        .background {
            if embedded || actionOnly { Color.clear }
            else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.accentColor.opacity(0.06))
            }
        }
        .task {
            guard !ScreenshotPresentation.activeProtection else { return }
            while !Task.isCancelled {
                hasSelection = SharedStore.hasRecordingSelection()
                let active = SharedStore.snapshot().broadcastActive
                if observedRecording != active {
                    observedRecording = active
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        .onChange(of: isRecording) { active in
            observedRecording = active
        }
        .accessibilityElement(children: .contain)
    }

    private var displayedRecording: Bool {
        ScreenshotPresentation.activeProtection || (observedRecording ?? isRecording)
    }


}

struct ScreenRecordingInfoCard: View {
    let onLearnMore: () -> Void
    @AppStorage("screenRecordingInfoDismissed", store: AppGroup.defaults)
    private var dismissed = false

    var body: some View {
        Group {
            if !dismissed {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(String(localized: "Why screen recording?"), systemImage: "questionmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                        Spacer(minLength: 4)
                        Button {
                            dismissed = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Done"))
                    }
                    Text(String(localized: "Slowth uses iOS screen recording to recognize Shorts, Reels, and Stories. While active, it receives images of your current screen, including other apps."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ScreenRecordingCopy.privacyExplanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Screen access and blocking details"), action: onLearnMore)
                        .font(.caption.weight(.semibold))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

struct RealtimeRecordingPromptSheet: View {
    @Environment(\.dismiss) private var dismiss

    let preferredExtensionBundleID: String
    let isRecording: Bool
    var onLearnMore: () -> Void = {}
    var pauseTarget: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(String(localized: "Choose how to continue", table: "Interface"))
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)

                    RecordingPauseCard {
                        AppRecordingCard(
                            preferredExtensionBundleID: preferredExtensionBundleID,
                            isRecording: isRecording,
                            onLearnMore: onLearnMore,
                            showsPause: pauseTarget != nil,
                            pauseTarget: pauseTarget
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "Slowth analyzes your screen, including other apps, on this device. Audio is ignored.", table: "Interface"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(String(localized: "In-app blocking"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .tint(Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.66, green: 0.81, blue: 0.62, alpha: 1)
                : UIColor(red: 0.27, green: 0.44, blue: 0.29, alpha: 1)
        }))
    }
}
#endif

#if DEBUG && canImport(FamilyControls)
#Preview("Recording prompt") {
    RealtimeRecordingPromptSheet(
        preferredExtensionBundleID: "", isRecording: false, pauseTarget: "youtube")
}
#Preview("Recording prompt · active") {
    RealtimeRecordingPromptSheet(
        preferredExtensionBundleID: "", isRecording: true, pauseTarget: "youtube")
}
#endif
