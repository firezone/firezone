//
//  SessionNotification.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import UserNotifications

// SessionNotification helps with showing iOS local notifications
// when the session ends.
// In macOS, it helps with showing an alert when the session ends.

public enum NotificationIndentifier: String {
  case sessionEndedNotificationCategory
  case signInNotificationAction
  case dismissNotificationAction
}

@MainActor
public class SessionNotification: NSObject {
  public var signInHandler = {}
  private let notificationCenter = UNUserNotificationCenter.current()

  override public init() {
    super.init()

    #if os(iOS)
      notificationCenter.delegate = self

      let signInAction = UNNotificationAction(
        identifier: NotificationIndentifier.signInNotificationAction.rawValue,
        title: "Sign In",
        options: [.authenticationRequired, .foreground])

      let dismissAction = UNNotificationAction(
        identifier: NotificationIndentifier.dismissNotificationAction.rawValue,
        title: "Dismiss",
        options: [])

      let certificateExpiryCategory = UNNotificationCategory(
        identifier: NotificationIndentifier.sessionEndedNotificationCategory.rawValue,
        actions: [signInAction, dismissAction],
        intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: "",
        options: [])

      notificationCenter.setNotificationCategories([certificateExpiryCategory])
    #endif
  }

  func askUserForNotificationPermissions() async throws -> UNAuthorizationStatus {
    // Ask the user for permission.
    try await notificationCenter.requestAuthorization(options: [.sound, .alert])

    // Retrieve the result
    return await loadAuthorizationStatus()
  }

  func loadAuthorizationStatus() async -> UNAuthorizationStatus {
    let settings = await notificationCenter.notificationSettings()

    return settings.authorizationStatus
  }

  /// Shows a notification for an unreachable resource
  ///
  /// - Parameters:
  ///   - title: The notification title
  ///   - body: The notification body text
  func showResourceNotification(title: String, body: String) async {
    // Check if we have permission to show notifications
    let settings = await notificationCenter.notificationSettings()
    guard settings.authorizationStatus == .authorized else {
      Log.log("Cannot show notification - not authorized")
      return
    }

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: UUID().uuidString,
      content: content,
      trigger: nil  // Show immediately
    )

    do {
      try await notificationCenter.add(request)
      Log.log("Notification shown: \(title)")
    } catch {
      Log.warning("Failed to show notification: \(error)")
    }
  }

  #if os(iOS)
    // In iOS, use User Notifications.
    // This gets called from the tunnel side.
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
  #elseif os(macOS)
    // In macOS, use a Cocoa alert.
    // This gets called from the app side.
    @MainActor
    func showSignedOutAlertmacOS(_ message: String?) async {
      let signInClicked = await MacOSAlert.showSignedOutAlert(message)
      if signInClicked {
        Log.log("\(#function): 'Sign In' clicked in notification")
        signInHandler()
      }
    }
  #endif
}

#if os(iOS)
  extension SessionNotification: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping () -> Void
    ) {
      Log.log("\(#function): 'Sign In' clicked in notification")
      let actionId = response.actionIdentifier
      let categoryId = response.notification.request.content.categoryIdentifier
      if categoryId == NotificationIndentifier.sessionEndedNotificationCategory.rawValue,
        actionId == NotificationIndentifier.signInNotificationAction.rawValue
      {
        // User clicked on 'Sign In' in the notification
        Task { @MainActor in
          signInHandler()
        }
      }

      completionHandler()
    }
  }
#endif
