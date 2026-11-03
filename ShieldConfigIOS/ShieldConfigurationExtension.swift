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
// Application shields consistently offer Slowth above Close.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        configuration(for: application)
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        configuration(for: application)
    }

    private func configuration(for application: Application) -> ShieldConfiguration {
        if GroupedApps.isEnabled { GroupedApps.rememberReturn(token: application.token, name: application.localizedDisplayName) }
        guard let target = Self.protectionTarget(application) else { return Self.unidentifiedConfiguration }
        if PauseOnlyApps.contains(target) { return Self.pauseOnlyConfiguration }
        if IOSPauseCoordinator.inferenceUnavailable(target) { return Self.unavailableConfiguration(target: target) }
        Self.recordInstagramShieldPresentation(for: application)
        return Self.applicationConfiguration
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        Self.currentConfiguration
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        Self.currentConfiguration
    }

    private static func protectionTarget(_ application: Application) -> String? {
        if GroupedApps.isEnabled { return "apps" }
        PauseOnlyApps.refreshSelections()
        guard let token = application.token else {
            PauseOnlyApps.recordRouting("configuration-no-token", appName: application.localizedDisplayName)
            RTLog.shieldConfig.notice("Pause-only routing: application has no token")
            return nil
        }
        let target = PauseOnlyApps.target(containing: token) ?? PauseOnlyApps.systemTarget(containing: token)
        PauseOnlyApps.recordRouting("configuration", token: token, target: target, appName: application.localizedDisplayName)
        let configured = PauseOnlyApps.targets.filter { PauseOnlyApps.selection($0) != nil }.count
        RTLog.shieldConfig.notice("Pause-only routing: target=\(target ?? "unmatched", privacy: .public), configured=\(configured, privacy: .public)")
        return target
    }

    // A translucent forest tint keeps the underlying app visible while giving
    // the white labels a consistent backdrop. Shared by every Shield state.
    private static let backgroundTint = UIColor(red: 0.09, green: 0.17, blue: 0.14, alpha: 0.38)
    private static let buttonColor = UIColor(red: 0.67, green: 0.80, blue: 0.61, alpha: 1)
    private static let buttonTextColor = UIColor(red: 0.12, green: 0.22, blue: 0.16, alpha: 1)

    private static func primaryLabel(bundle: Bundle) -> ShieldConfiguration.Label {
        .init(text: "Slowth", color: buttonTextColor)
    }

    private static func secondaryLabel(bundle: Bundle) -> ShieldConfiguration.Label? {
        .init(text: String(localized: "Close", table: "Interface", bundle: bundle), color: .white)
    }

    private static func applicationSubtitle(_ text: String, bundle: Bundle, application: Bool = true) -> String {
        if #available(iOS 26.5, *) { return text }
        guard application else { return text }
        let key = "Tap Slowth, then open its notification. If no banner appears, check Notification Center or open Slowth manually."
        return text + "\n\n" + bundle.localizedString(forKey: key, value: key, table: "ShieldNotifications")
    }

    private static var applicationConfiguration: ShieldConfiguration {
        let state = SharedStore.snapshot()
        let bundle = ShieldLocalization.bundle(in: Bundle(for: ShieldConfigurationExtension.self))
        return state.broadcastActive
            ? detectedConfiguration(state: state, bundle: bundle, application: true)
            : recordingOffConfiguration(state: state, bundle: bundle, application: true)
    }

    // The system owns button width and font. Use the short product name in
    // every locale; the subtitle explains that this opens the containing app.
    private static var unidentifiedConfiguration: ShieldConfiguration {
        let bundle = ShieldLocalization.bundle(in: Bundle(for: ShieldConfigurationExtension.self))
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: backgroundTint,
            icon: slowthAppIcon,
            title: .init(text: String(localized: "Blocked", bundle: bundle), color: .white),
            subtitle: .init(text: applicationSubtitle(String(localized: "Open Slowth to choose how to continue.", table: "Interface", bundle: bundle), bundle: bundle), color: .white.withAlphaComponent(0.8)),
            primaryButtonLabel: primaryLabel(bundle: bundle),
            primaryButtonBackgroundColor: buttonColor,
            secondaryButtonLabel: secondaryLabel(bundle: bundle))
    }

    private static func unavailableConfiguration(target: String) -> ShieldConfiguration {
        let bundle = ShieldLocalization.bundle(in: Bundle(for: ShieldConfigurationExtension.self))
        let labels = ["youtube": "YouTube", "instagram": "Instagram", "facebook": "Facebook", "x": "X"]
        let title = String(format: String(localized: "Unavailable for %@", table: "Interface", bundle: bundle),
                           labels[target] ?? target)
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: backgroundTint,
            icon: slowthAppIcon,
            title: .init(text: title, color: .white),
            subtitle: .init(text: applicationSubtitle(String(localized: "Open Slowth to choose how to continue.", table: "Interface", bundle: bundle), bundle: bundle), color: .white.withAlphaComponent(0.8)),
            primaryButtonLabel: primaryLabel(bundle: bundle),
            primaryButtonBackgroundColor: buttonColor,
            secondaryButtonLabel: secondaryLabel(bundle: bundle))
    }

    private static var pauseOnlyConfiguration: ShieldConfiguration {
        let bundle = ShieldLocalization.bundle(in: Bundle(for: ShieldConfigurationExtension.self))
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: backgroundTint,
            icon: slowthAppIcon,
            title: .init(text: String(localized: "Blocked", bundle: bundle), color: .white),
            subtitle: .init(text: applicationSubtitle(String(localized: "Currently supported only in pause mode. Open Slowth and start a pause to use this app. Screen recording does not unlock it.", table: "Interface", bundle: bundle), bundle: bundle), color: .white.withAlphaComponent(0.8)),
            primaryButtonLabel: primaryLabel(bundle: bundle),
            primaryButtonBackgroundColor: buttonColor,
            secondaryButtonLabel: secondaryLabel(bundle: bundle)
        )
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

    private static func recordingOffConfiguration(state: SharedState, bundle: Bundle, application: Bool = false) -> ShieldConfiguration {
        let openAppButton: ShieldConfiguration.Label?
        if #available(iOS 26.5, *) {
            openAppButton = ShieldConfiguration.Label(text: "Slowth", color: buttonTextColor)
        } else {
            openAppButton = nil
        }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: backgroundTint,
            icon: slowthAppIcon,
            title: ShieldConfiguration.Label(text: String(localized: "Blocked", bundle: bundle), color: .white),
            subtitle: ShieldConfiguration.Label(
                text: applicationSubtitle(subtitleText(
                    defaultText: String(localized: "Open Slowth to choose how to continue.", table: "Interface", bundle: bundle),
                    state: state,
                    variant: "recording off"
                ), bundle: bundle, application: application),
                color: UIColor.white.withAlphaComponent(0.8)
            ),
            primaryButtonLabel: application ? primaryLabel(bundle: bundle) : openAppButton,
            primaryButtonBackgroundColor: buttonColor,
            secondaryButtonLabel: application ? secondaryLabel(bundle: bundle) : nil
        )
    }

    private static func detectedConfiguration(state: SharedState, bundle: Bundle, application: Bool = false) -> ShieldConfiguration {
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: backgroundTint,
            icon: slowthAppIcon,
            title: ShieldConfiguration.Label(text: String(localized: "Blocked content detected", bundle: bundle), color: .white),
            subtitle: ShieldConfiguration.Label(
                text: applicationSubtitle(subtitleText(
                    defaultText: String(localized: "Your rest has started. Open Slowth to see the remaining time.", table: "Interface", bundle: bundle),
                    state: state,
                    variant: "content detected"
                ), bundle: bundle, application: application),
                color: UIColor.white.withAlphaComponent(0.8)
            ),
            primaryButtonLabel: application ? primaryLabel(bundle: bundle) : ShieldConfiguration.Label(text: String(localized: "Close", table: "Interface", bundle: bundle), color: buttonTextColor),
            // Match the primary button on the pause-only shield.
            primaryButtonBackgroundColor: buttonColor,
            secondaryButtonLabel: application ? secondaryLabel(bundle: bundle) : ShieldConfiguration.Label(
                text: String(localized: "Continue", bundle: bundle),
                color: .white
            )
        )
    }

    private static func subtitleText(
        defaultText: String,
        state: SharedState,
        variant: String
    ) -> String {
        guard DebugMode.shieldDiagnosticsEnabled else { return defaultText }
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
        // Use app-icon proportions with rounded corners instead of a circular badge.
        let size = CGSize(width: 96, height: 96)
        let badge = UIGraphicsImageRenderer(size: size).image { context in
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let outline = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.width * 0.225)
            context.cgContext.saveGState()
            outline.addClip()
            image.draw(in: bounds)
            context.cgContext.restoreGState()
            UIColor.white.withAlphaComponent(0.35).setStroke()
            outline.lineWidth = 2
            outline.stroke()
        }
        return badge.withRenderingMode(.alwaysOriginal)
    }()
}
