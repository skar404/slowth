import ManagedSettings
import ManagedSettingsUI
import UIKit
#if canImport(FamilyControls)
import FamilyControls
#endif

// Customizes the system Shield screen shown when ManagedSettingsStore
// shields YouTube. Reads SharedStore (App Group) to tell apart
// "blocked because recording isn't on" from "blocked content was detected
// while recording" — a single synchronous UserDefaults
// snapshot read, safe to call from configuration(shielding:).
//
// The detected variant offers a safe default (close the app) and a secondary
// Continue action that adds a brief intentional pause before release.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        Self.recordInstagramShieldPresentation(for: application)
        return Self.currentConfiguration
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        Self.recordInstagramShieldPresentation(for: application)
        return Self.currentConfiguration
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        Self.currentConfiguration
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        Self.currentConfiguration
    }

    private static var currentConfiguration: ShieldConfiguration {
        let state = SharedStore.snapshot()
        let bundle = ShieldLocalization.bundle(in: Bundle(for: ShieldConfigurationExtension.self))
        let broadcastActive = state.broadcastActive
        RTLog.shieldConfig.notice("configuration(shielding:): broadcastActive=\(broadcastActive, privacy: .public) — showing \(broadcastActive ? "detected" : "recordingOff", privacy: .public) variant")
        return broadcastActive
            ? detectedConfiguration(state: state, bundle: bundle)
            : recordingOffConfiguration(state: state, bundle: bundle)
    }

    private static func recordInstagramShieldPresentation(for application: Application) {
        #if canImport(FamilyControls)
        guard let token = application.token,
              let data = SharedStore.instagramSelectionData(),
              let selection = try? JSONDecoder().decode(
                  FamilyActivitySelection.self,
                  from: data
              ),
              selection.applicationTokens.contains(token) else {
            return
        }
        SharedStore.setLastInstagramShieldPresentedAt(Date())
        RTLog.shieldConfig.notice("Instagram shield presented — app launch observed")
        #endif
    }

    private static func recordingOffConfiguration(state: SharedState, bundle: Bundle) -> ShieldConfiguration {
        let openAppButton: ShieldConfiguration.Label?
        if #available(iOS 26.5, *) {
            openAppButton = ShieldConfiguration.Label(text: String(localized: "Open Slowth", bundle: bundle), color: .white)
        } else {
            openAppButton = nil
        }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: UIColor(red: 0.10, green: 0.10, blue: 0.16, alpha: 1),
            icon: slowthAppIcon,
            title: ShieldConfiguration.Label(text: String(localized: "Blocked", bundle: bundle), color: .white),
            subtitle: ShieldConfiguration.Label(
                text: subtitleText(
                    defaultText: String(localized: "Open Slowth and start screen recording to unlock enabled apps. They stay open while you're not viewing selected blocked content.\n\nIf you notice any issues, please share your feedback.", bundle: bundle),
                    state: state,
                    variant: "recording off"
                ),
                color: UIColor.white.withAlphaComponent(0.8)
            ),
            primaryButtonLabel: openAppButton,
            primaryButtonBackgroundColor: UIColor(red: 0.90, green: 0.20, blue: 0.32, alpha: 1)
        )
    }

    private static func detectedConfiguration(state: SharedState, bundle: Bundle) -> ShieldConfiguration {
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: UIColor(red: 0.10, green: 0.10, blue: 0.16, alpha: 1),
            icon: slowthAppIcon,
            title: ShieldConfiguration.Label(text: String(localized: "Blocked content detected", bundle: bundle), color: .white),
            subtitle: ShieldConfiguration.Label(
                text: subtitleText(
                    defaultText: String(localized: "Take a short break, then continue. Leave the blocked screen — Slowth will block it again if you stay there.\n\nIf you notice any issues, please share your feedback.", bundle: bundle),
                    state: state,
                    variant: "content detected"
                ),
                color: UIColor.white.withAlphaComponent(0.8)
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: String(localized: "Close app", bundle: bundle), color: .white),
            primaryButtonBackgroundColor: UIColor(red: 0.90, green: 0.20, blue: 0.32, alpha: 1),
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: String(localized: "Continue", bundle: bundle),
                color: UIColor.white.withAlphaComponent(0.85)
            )
        )
    }

    private static func subtitleText(
        defaultText: String,
        state: SharedState,
        variant: String
    ) -> String {
        guard DebugMode.isEnabled else { return defaultText }
        let diagnostics = state.realtimeShieldDiagnostics
        let requiredHits = diagnostics.requiredConsecutiveHits.map(String.init) ?? "?"
        let prediction = [diagnostics.lastApp, diagnostics.lastContent]
            .compactMap { $0 }
            .joined(separator: "/")
        let updated = diagnostics.updatedAt.map {
            String(format: "%.1fs ago", max(0, Date().timeIntervalSince($0)))
        } ?? "never"

        var lines = [
            "DEBUG · \(variant)",
            "model \(diagnostics.modelStatus) · \(diagnostics.modelVersion ?? "—")",
            "prediction \(prediction.isEmpty ? "—" : prediction)",
            "joint \(score("youtube_shorts", diagnostics)) · \(score("instagram_reels", diagnostics)) · \(score("instagram_stories", diagnostics))",
            "streak S \(diagnostics.youtubeShortsStreak)/\(requiredHits) · R \(diagnostics.instagramReelsStreak)/\(requiredHits) · St \(diagnostics.instagramStoriesStreak)/\(requiredHits)",
            "frames \(diagnostics.receivedVideoFrames) · inference \(diagnostics.inferenceCount) · \(milliseconds(diagnostics.lastInferenceDurationMS))/\(milliseconds(diagnostics.inferenceP95MS)) p95",
            "latched Y \(flag(diagnostics.youtubeShieldLatched)) · I \(flag(diagnostics.instagramShieldLatched)) · updated \(updated)"
        ]
        if let error = diagnostics.lastClassifierError, !error.isEmpty {
            lines.append("error \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private static func score(_ key: String, _ diagnostics: RealtimeShieldDiagnostics) -> String {
        let shortName: String
        switch key {
        case "youtube_shorts": shortName = "S"
        case "instagram_reels": shortName = "R"
        default: shortName = "St"
        }
        let value = diagnostics.jointProbabilities?[key]
        let threshold = diagnostics.confidenceThresholds?[key]
        return "\(shortName) \(decimal(value))/\(decimal(threshold))"
    }

    private static func decimal(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f", value)
    }

    private static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—ms" }
        return String(format: "%.1fms", value)
    }

    private static func flag(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    private static let slowthAppIcon: UIImage? = {
        let bundle = Bundle(for: ShieldConfigurationExtension.self)
        guard let url = bundle.url(forResource: "SlowthAppIcon", withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else {
            RTLog.shieldConfig.error("Slowth shield icon resource is missing — using system fallback")
            return UIImage(systemName: "hourglass")
        }
        return image.withRenderingMode(.alwaysOriginal)
    }()
}
