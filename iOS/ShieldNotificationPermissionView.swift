import SwiftUI
import UserNotifications

struct ShieldNotificationPermissionView: View {
    var onContinue: (() -> Void)? = nil
    var isInitialOffer = false
    @AppStorage("shieldNotificationOfferHandled") private var offerHandled = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var alertsEnabled = false
    @State private var busy = false
    @State private var showSettings = false

    var body: some View {
        if #available(iOS 26.5, *) {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 16) {
            if onContinue != nil {
                Text(String(localized: "Enable notifications", table: "Interface"))
                    .font(.title2.bold())
                Text(String(localized: "Open Slowth from the blocking notification. If the banner disappears, find it in Notification Center. During recording, use Settings → Notifications → Screen Sharing → Allow Notifications. This optional switch applies to all apps.", table: "Interface"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await enable() }
            } label: {
                Label(onContinue != nil ? (status == .notDetermined ? String(localized: "Enable notifications", table: "Interface") : String(localized: "Open Settings")) : text(alertsEnabled ? "Notifications for opening Slowth are enabled" : "Enable notifications to open Slowth from blocking"),
                      systemImage: alertsEnabled ? "bell.badge.fill" : "bell")
            }
            .disabled(busy)
            if let onContinue {
                Button(status == .notDetermined
                       ? String(localized: "Skip", table: "Interface")
                       : String(localized: "Continue", table: "Interface"), action: onContinue)
                    .disabled(busy)
            }
            }
            .task {
                await refresh()
                if alertsEnabled {
                    offerHandled = true
                    onContinue?()
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await refresh() } }
            }
            .alert(text("Notification settings"), isPresented: $showSettings) {
                Button(text("Open settings")) {
                    openSettings()
                }
                Button(text("Cancel"), role: .cancel) {}
            } message: {
                Text(text("Allow banners in Settings. Focus may hide notifications; you can always open Slowth manually."))
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
    }

    private func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "ShieldNotifications")
    }

    @MainActor private func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
        alertsEnabled = settings.authorizationStatus == .authorized && settings.alertSetting == .enabled
    }

    @MainActor private func enable() async {
        busy = true
        defer {
            busy = false
            // After the first explicit tap, keep permission management in the
            // app's Settings, regardless of grant/denial or the current status.
            offerHandled = true
        }
        await refresh()
        if status == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            await refresh()
            if alertsEnabled { onContinue?() }
            else if onContinue == nil && !isInitialOffer { showSettings = true }
        } else if onContinue != nil || isInitialOffer {
            openSettings()
        } else {
            showSettings = true
        }
    }
}
