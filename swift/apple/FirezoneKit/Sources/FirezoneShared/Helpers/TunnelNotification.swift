import Foundation
import UserNotifications

/// Notification utilities for the tunnel (Network Extension) process.
///
/// These functions run in the NE process where `SessionNotification` (a `@MainActor` class
/// tied to the GUI) is not available.
public enum TunnelNotification {
  #if os(iOS)
    /// Shows a local notification telling the user their session has ended.
    ///
    /// Called from the tunnel side when an authentication error disconnects the session.
    /// On macOS, the equivalent alert is shown by the GUI process via `SessionNotification`.
    nonisolated public static func showSignedOutNotificationiOS() {
      UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
        if notificationSettings.authorizationStatus == .authorized {
          Log.log(
            "Notifications are allowed. Alert style is \(notificationSettings.alertStyle.rawValue)"
          )
          let content = UNMutableNotificationContent()
          content.title = "Your Firezone session has ended"
          content.body = "Please sign in again to reconnect"
          content.categoryIdentifier =
            NotificationIndentifier.sessionEndedNotificationCategory.rawValue
          let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
          let request = UNNotificationRequest(
            identifier: "FirezoneTunnelShutdown", content: content, trigger: trigger
          )
          UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
              Log.error(error)
            } else {
              Log.debug("\(#function): Successfully requested notification")
            }
          }
        }
      }
    }
  #endif
}
