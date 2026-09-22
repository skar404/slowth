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

struct RealtimeRecordingCard: View {
    let preferredExtensionBundleID: String
    let isRecording: Bool
    let guidance: String
    @State private var observedRecording: Bool?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: displayedRecording ? "record.circle.fill" : "lock.open.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayedRecording ? String(localized: "Screen recording is active") : String(localized: "Start screen recording"))
                    .font(.headline)
                Text(displayedRecording ? String(localized: "Tap anywhere here to stop.") : guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: displayedRecording ? "stop.circle.fill" : "record.circle.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(statusColor.opacity(displayedRecording ? 0.18 : 0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    statusColor.opacity(displayedRecording ? 0.55 : 0.18),
                    lineWidth: displayedRecording ? 1.5 : 1
                )
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
        displayedRecording ? .red : .accentColor
    }
}

struct ScreenRecordingInfoCard: View {
    let onLearnMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(String(localized: "Why screen recording?"), systemImage: "questionmark.circle.fill")
                .font(.subheadline.weight(.semibold))
            Text(String(localized: "Slowth uses iOS screen recording to recognize Shorts, Reels, and Stories. While active, it receives images of your current screen, including other apps."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(ScreenRecordingCopy.privacyExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(String(localized: "Screen access and blocking details"), action: onLearnMore)
                .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct RealtimeRecordingPromptSheet: View {
    @Environment(\.dismiss) private var dismiss

    let preferredExtensionBundleID: String
    let isRecording: Bool
    var onLearnMore: () -> Void = {}

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.red)

                VStack(spacing: 8) {
                    Text(String(localized: "Start screen recording"))
                        .font(.title2.weight(.bold))
                    Text(String(localized: "Tap the card below and confirm in the system prompt. Selected apps unlock while screen analysis runs. Detecting content you chose to block locks the entire app."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                RealtimeRecordingCard(
                    preferredExtensionBundleID: preferredExtensionBundleID,
                    isRecording: isRecording,
                    guidance: String(localized: "Tap anywhere here to start.")
                )

                ScreenRecordingInfoCard(onLearnMore: onLearnMore)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle(String(localized: "In-app blocking"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}
#endif
