import ManagedSettings
import ManagedSettingsUI
import UIKit

// Customizes the system Shield screen shown when ManagedSettingsStore shields
// the YouTube app. The paired "Remove block" secondary button is handled by
// UnscrollShieldActionIOS's ShieldActionExtension, not here — this extension
// only controls appearance.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        Self.shortsBlockedConfiguration
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        Self.shortsBlockedConfiguration
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        Self.shortsBlockedConfiguration
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        Self.shortsBlockedConfiguration
    }

    private static var shortsBlockedConfiguration: ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: UIColor(red: 0.10, green: 0.10, blue: 0.16, alpha: 1),
            icon: UIImage(systemName: "hourglass"),
            title: ShieldConfiguration.Label(text: "Shorts detected", color: .white),
            subtitle: ShieldConfiguration.Label(
                text: "Slowth paused YouTube because it looks like you're watching Shorts.",
                color: UIColor.white.withAlphaComponent(0.8)
            ),
            primaryButtonLabel: ShieldConfiguration.Label(text: "OK", color: .white),
            primaryButtonBackgroundColor: UIColor(red: 0.36, green: 0.46, blue: 0.95, alpha: 1),
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: "Remove block",
                color: UIColor.white.withAlphaComponent(0.7)
            )
        )
    }
}
