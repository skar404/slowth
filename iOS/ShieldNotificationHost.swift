import UIKit
import UserNotifications

final class ShieldNotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // App.init runs before UIKit has created UIApplication.shared. Capture
        // the launched instance here so foreground DB access gets a valid task.
        IOSPauseDatabase.beginHostAccess = {
            try PauseDatabaseBackgroundTask.begin(application: application)
        }
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            _ = ShieldNotification.open(identifier: response.notification.request.identifier,
                defaultAction: response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                userInfo: response.notification.request.content.userInfo,
                isKnown: { IOSPauseCoordinator.apps.contains($0) }) { target in
                    let token = (response.notification.request.content.userInfo[ShieldNotification.navigationTokenKey] as? String)
                        .flatMap { Data(base64Encoded: $0) }
                    SharedStore.requestRealtimeRecordingPrompt(target: target, navigationToken: token)
                    UserDefaults.standard.set("ios", forKey: "uiMode")
                }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(ShieldNotification.recognizes(notification.request.identifier) ? [.banner, .list] : [])
    }
}
