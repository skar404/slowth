#if canImport(FamilyControls)
import SwiftUI
import ReplayKit

private final class ChromeHidingBroadcastPickerView: RPSystemBroadcastPickerView {
    var hidesSystemControlChrome = false {
        didSet {
            setNeedsLayout()
            hideSystemControlChromeIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hideSystemControlChromeIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
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
        picker.accessibilityLabel = accessibilityLabel
        picker.accessibilityTraits = .button
        // Custom UIViewRepresentables don't automatically honor SwiftUI's
        // .disabled()/environment isEnabled — apply it manually so a
        // disabled BroadcastPickerView is actually untappable, not just
        // visually dimmed by a modifier with no effect on the UIButton.
        picker.isUserInteractionEnabled = isEnabled
        picker.alpha = isEnabled ? 1.0 : 0.4
    }
}

/// Compact ReplayKit control for the system toolbar on Duo. The actual tap
/// stays with RPSystemBroadcastPickerView, including its start/stop confirmation.
struct RecordingToolbarButton: View {
    let preferredExtensionBundleID: String
    @State private var isRecording = SharedStore.snapshot().broadcastActive

    var body: some View {
        Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
            .font(.title2)
            .foregroundStyle(.red)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            .overlay {
                BroadcastPickerView(
                    preferredExtensionBundleID: preferredExtensionBundleID,
                    showsSystemControl: false,
                    accessibilityLabel: isRecording
                        ? String(localized: "Stop screen recording")
                        : String(localized: "Start screen recording")
                )
                .accessibilityIdentifier("duo.recording")
            }
            .task {
                while !Task.isCancelled {
                    isRecording = SharedStore.snapshot().broadcastActive
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
    }
}

/// Shared appearance and copy for the main screen and the Shield handoff.
struct AppRecordingCard: View {
    let preferredExtensionBundleID: String
    let isRecording: Bool
    let onLearnMore: () -> Void

    var body: some View {
        RealtimeRecordingCard(
            preferredExtensionBundleID: preferredExtensionBundleID,
            isRecording: isRecording,
            guidance: String(localized: "Screen recording helps detect and block short videos.", table: "Interface"),
            embedded: true
        )
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: onLearnMore) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(6)
            .accessibilityLabel(String(localized: "How it works"))
            .accessibilityIdentifier("recording.help")
        }
    }
}

struct RealtimeRecordingCard: View {
    let preferredExtensionBundleID: String
    let isRecording: Bool
    let guidance: String
    var prominent = false
    var embedded = false
    @State private var observedRecording: Bool?

    var body: some View {
        HStack(spacing: prominent ? 14 : 8) {
            ZStack {
                Circle()
                    .fill(embedded ? Color.clear : statusColor.opacity(0.14))
                    .frame(width: prominent ? 44 : 32, height: prominent ? 44 : 32)
                Image(systemName: displayedRecording ? "stop.circle" : embedded ? "record.circle" : "lock.open.fill")
                    .font(.system(size: prominent ? 22 : embedded ? 20 : 16, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: prominent ? 8 : 2) {
                Text(displayedRecording ? String(localized: "Screen recording is active") : String(localized: "Start screen recording"))
                    .font(embedded ? .body.weight(.bold) : prominent ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(embedded ? statusColor : Color.primary)
                if displayedRecording || !guidance.isEmpty {
                Text(displayedRecording ? String(localized: "Tap anywhere here to stop.") : guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: embedded ? 36 : 8)

            if !embedded {
            Image(systemName: displayedRecording ? "stop.circle.fill" : "record.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 34, height: 34)
            }
        }
        .padding(prominent || embedded ? 20 : 9)
        .frame(maxWidth: .infinity, minHeight: prominent ? 132 : embedded ? 80 : nil, alignment: .leading)
        .background {
            if embedded {
                statusColor.opacity(0.14)
            } else {
                RoundedRectangle(cornerRadius: prominent ? 22 : 12, style: .continuous)
                    .fill(statusColor.opacity(displayedRecording ? 0.18 : 0.08))
            }
        }
        .overlay {
            if !prominent && !embedded {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    statusColor.opacity(displayedRecording ? 0.55 : 0.18),
                    lineWidth: displayedRecording ? 1.5 : 1
                )
            }
        }
        .overlay {
            BroadcastPickerView(
                preferredExtensionBundleID: preferredExtensionBundleID,
                showsSystemControl: false,
                accessibilityLabel: displayedRecording
                    ? String(localized: "Stop screen recording")
                    : String(localized: "Start screen recording")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            while !Task.isCancelled {
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
        observedRecording ?? isRecording
    }

    private var statusColor: Color {
        if displayedRecording { return .red }
        guard embedded else { return .accentColor }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.66, green: 0.81, blue: 0.62, alpha: 1)
                : UIColor(red: 0.27, green: 0.44, blue: 0.29, alpha: 1)
        })
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

                    VStack(spacing: 12) {
                        AppRecordingCard(
                            preferredExtensionBundleID: preferredExtensionBundleID,
                            isRecording: isRecording,
                            onLearnMore: onLearnMore
                        )
                        if let pauseTarget {
                            ShieldPauseButton(target: pauseTarget, onStarted: { dismiss() })
                        }
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
