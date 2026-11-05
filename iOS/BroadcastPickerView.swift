#if canImport(FamilyControls)
import SwiftUI
import ReplayKit
import ManagedSettings

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
            // bounds without extending into the separate pause controls.
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
/// Match the Form row's container shape for both clipping and the state border.
/// A fixed corner radius can put the border outside the system's rounded mask.
struct RecordingPauseCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .background(SlowthAppearance.card)
            .clipShape(ContainerRelativeShape())
    }
}

/// Shared recording row for the main screen and the Shield handoff.
// Presentation-only fixture for local marketing captures. Never sets SharedStore,
// Screen Time authorization, ReplayKit state, or the durable pause ledger.
enum ScreenshotPresentation {
    static var recordingActive: Bool {
        activeProtection && !ProcessInfo.processInfo.arguments.contains("--screenshot-recording-off")
    }

    static var activeProtection: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--screenshot-active-protection")
        #else
        false
        #endif
    }
}

private struct MonitoringRecordingPresentationKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct AppRecordingCard: View {
    let preferredExtensionBundleID: String
    let isRecording: Bool
    var showsPause = false
    var pauseTarget: String? = nil
    var compact = false
    var showsStateBackground = true
    var detectionRestSeconds = 0
    @State private var pauseActive = false
    @State private var observedRecordingActive: Bool?
    private var recordingActive: Bool { observedRecordingActive ?? isRecording }
    private var stateAccent: Color {
        detectionRestSeconds > 0 ? SlowthAppearance.blocked
            : pauseActive ? SlowthAppearance.pause : SlowthAppearance.sage
    }

    var body: some View {
        VStack(spacing: 0) {
            RealtimeRecordingCard(preferredExtensionBundleID: preferredExtensionBundleID,
                                  isRecording: isRecording, compact: compact, isPaused: pauseActive,
                                  detectionRestSeconds: detectionRestSeconds)
            if showsPause {
                PausePanel(safari: false, preferredTarget: pauseTarget, embedded: true,
                           compact: true, sharedBackground: true, monitoringFooter: true,
                           monitoringActive: recordingActive)
            }
        }
        .background(showsStateBackground
                    ? (detectionRestSeconds > 0 ? stateAccent.opacity(0.12)
                       : pauseActive ? stateAccent.opacity(0.09)
                       : recordingActive ? stateAccent.opacity(0.16) : Color.clear)
                    : Color.clear)
        .overlay {
            if showsStateBackground && (recordingActive || pauseActive || detectionRestSeconds > 0) {
                ContainerRelativeShape()
                    .strokeBorder(stateAccent.opacity(0.38), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(MonitoringPausePresentationKey.self) { pauseActive = $0 }
        .onPreferenceChange(MonitoringRecordingPresentationKey.self) { observedRecordingActive = $0 }
    }
}

/// The entire upper row belongs to ReplayKit. Pause controls are a sibling view
/// with their own hit area and eligibility, independent of recording readiness.
struct RealtimeRecordingCard: View {
    let preferredExtensionBundleID: String
    let isRecording: Bool
    var compact = false
    var isPaused = false
    var detectionRestSeconds = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var observedRecording: Bool?
    @State private var hasSelection = SharedStore.hasRecordingSelection()
    private var accent: Color {
        detectionRestSeconds > 0 ? SlowthAppearance.blocked
            : isPaused ? SlowthAppearance.pause : SlowthAppearance.sage
    }

    private var actionTitle: String {
        displayedRecording ? String(localized: "Stop monitoring", table: "Interface")
            : String(localized: "Start monitoring", table: "Interface")
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 20))
        layout {
            ring
            VStack(alignment: .leading, spacing: 6) {
                Text(detectionRestSeconds > 0 ? AppLocalization.string("Blocked")
                     : String(localized: "Monitoring", table: "Interface"))
                    .font(.headline)
                    .foregroundStyle(detectionRestSeconds > 0 || isPaused || displayedRecording ? accent : Color.primary)
                Label {
                    Text(detectionRestSeconds > 0 ? String(localized: "Take a short pause", table: "Interface")
                         : displayedRecording ? String(localized: "Screen recording is active")
                         : String(localized: "Screen recording is off", table: "Interface"))
                } icon: {
                    Image(systemName: detectionRestSeconds > 0 ? "lock.fill"
                          : displayedRecording ? "checkmark.circle.fill" : "circle")
                }
                .font(.subheadline)
                .foregroundStyle(detectionRestSeconds > 0 || displayedRecording || isPaused ? accent : Color.secondary)
                Text(actionTitle)
                    .font(.subheadline)
                    .foregroundStyle(accent)
                    .frame(minHeight: detectionRestSeconds > 0 ? 44 : nil, alignment: .leading)
                    .accessibilityHidden(detectionRestSeconds > 0)
                    .overlay {
                        if detectionRestSeconds > 0 {
                            BroadcastPickerView(preferredExtensionBundleID: preferredExtensionBundleID,
                                showsSystemControl: false, accessibilityLabel: actionTitle)
                                .accessibilityIdentifier("recording.action")
                        }
                    }
                if !displayedRecording && !hasSelection && !ScreenshotPresentation.activeProtection {
                    Text(String(localized: "Choose at least one app to start recording.", table: "Interface"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(displayedRecording || hasSelection || ScreenshotPresentation.activeProtection ? 1 : 0.5)
        .accessibilityHidden(detectionRestSeconds == 0)
        .overlay {
            if detectionRestSeconds == 0 {
                BroadcastPickerView(preferredExtensionBundleID: preferredExtensionBundleID,
                                showsSystemControl: false, accessibilityLabel: actionTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("recording.action")
            }
        }
        .task {
            guard !ScreenshotPresentation.activeProtection else { return }
            while !Task.isCancelled {
                hasSelection = SharedStore.hasRecordingSelection()
                let active = SharedStore.snapshot().broadcastActive
                if observedRecording != active { observedRecording = active }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        .onChange(of: isRecording) { observedRecording = $0 }
        .preference(key: MonitoringRecordingPresentationKey.self, value: displayedRecording)
    }

    private var ring: some View {
        let size: CGFloat = compact ? 76 : 96
        return ZStack {
            Circle().strokeBorder(accent.opacity(0.09), lineWidth: size * 0.12)
            Circle().strokeBorder(accent.opacity(displayedRecording ? 0.65 : 0.22), lineWidth: 1.5)
                .padding(size * 0.045)
            Circle().fill(detectionRestSeconds > 0 ? accent.opacity(0.10)
                          : displayedRecording ? accent : accent.opacity(0.1))
                .padding(size * 0.18)
            if detectionRestSeconds > 0 {
                Text(Duration.seconds(detectionRestSeconds).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: size * 0.26, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent)
                    .accessibilityLabel(String(localized: "Time remaining", table: "Interface"))
                    .accessibilityValue(Duration.seconds(detectionRestSeconds).formatted(.time(pattern: .minuteSecond)))
                    .accessibilityIdentifier("recording.detection-pause")
            } else {
                Image(systemName: "power")
                .font(.system(size: size * 0.23, weight: .medium))
                .foregroundStyle(displayedRecording
                                 ? (colorScheme == .dark ? Color.black : .white) : accent)
            }
        }
        .frame(width: size, height: size)
    }

    private var displayedRecording: Bool {
        ScreenshotPresentation.activeProtection ? isRecording : (observedRecording ?? isRecording)
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

private struct RecordingSheetBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationBackground(SlowthAppearance.card)
                .scrollBounceBehavior(.basedOnSize)
        } else {
            content.background(SlowthAppearance.card)
        }
    }
}

private struct RecordingPromptHeight: PreferenceKey {
    static var defaultValue: CGFloat = 220
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct RealtimeRecordingPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var applicationOpenFailed = false
    @State private var contentHeight: CGFloat = 220

    let preferredExtensionBundleID: String
    let isRecording: Bool
    var onLearnMore: () -> Void = {}
    var pauseTarget: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                AppRecordingCard(preferredExtensionBundleID: preferredExtensionBundleID,
                                 isRecording: isRecording, showsPause: pauseTarget != nil,
                                 pauseTarget: pauseTarget, compact: true, showsStateBackground: false)
                if let url = (pauseTarget == "apps" ? GroupedApps.returnTarget : pauseTarget).flatMap(IOSApplicationLink.url(for:)) {
                    Button {
                        applicationOpenFailed = false
                        UIApplication.shared.open(url, options: [:]) { opened in
                            applicationOpenFailed = !opened
                            if opened { dismiss() }
                        }
                    } label: {
                        Label(String(localized: "Return to app", table: "ApplicationNavigation"),
                              systemImage: "arrow.uturn.backward")
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("recording.return-to-app")
                }
                if pauseTarget == "apps", GroupedApps.returnTarget.flatMap(IOSApplicationLink.url(for:)) == nil {
                    Text(String(localized: "Return using the app switcher.", table: "Interface"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if applicationOpenFailed {
                    Text(String(localized: "Could not open the app. Open it manually.", table: "ApplicationNavigation"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: RecordingPromptHeight.self, value: geometry.size.height)
                }
            }
        }
        .scrollIndicators(.hidden)
        .onPreferenceChange(RecordingPromptHeight.self) { contentHeight = $0 }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize
            ? [.large] : [.height(max(220, contentHeight)), .large])
        .presentationDragIndicator(.visible)
        .accessibilityAction(.escape) { dismiss() }
        .modifier(RecordingSheetBackground())
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
