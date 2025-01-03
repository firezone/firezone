//
//  SessionNotification.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
import AppKit
#endif

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

public class SessionNotification: NSObject {
  public var signInHandler: (() -> Void)? = nil
  @Published private(set) var decision: UNAuthorizationStatus

  public override init() {
    self.decision = .notDetermined

    super.init()

#if os(iOS)
    let notificationCenter = UNUserNotificationCenter.current()

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

    notificationCenter.getNotificationSettings { notificationSettings in
      self.decision = notificationSettings.authorizationStatus
    }
#endif
  }

#if os(iOS)
  func askUserForNotificationPermissions() {
    guard case .notDetermined = self.decision else {
      Log.log("Already determined!")
      return
    }

    let notificationCenter = UNUserNotificationCenter.current()
    notificationCenter.requestAuthorization(options: [.sound, .alert]) { _, _ in
      notificationCenter.getNotificationSettings { notificationSettings in
        self.decision = notificationSettings.authorizationStatus
      }
    }
  }

  func loadAuthorizationStatus(handler: (UNAuthorizationStatus) -> Void) {

  }

  // In iOS, use User Notifications.
  // This gets called from the tunnel side.
  public static func showSignedOutNotificationiOS() {
    UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
      if notificationSettings.authorizationStatus == .authorized {
        Log.log(
          "Notifications are allowed. Alert style is \(notificationSettings.alertStyle.rawValue)"
        )
        let content = UNMutableNotificationContent()
        content.title = "Your Firezone session has ended"
        content.body = "Please sign in again to reconnect"
        content.categoryIdentifier = NotificationIndentifier.sessionEndedNotificationCategory.rawValue
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
  func showSignedOutAlertmacOS() {
    let alert = NSAlert()
    alert.messageText = "Your Firezone session has ended"
    alert.informativeText = "Please sign in again to reconnect"
    alert.addButton(withTitle: "Sign In")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    if response == NSApplication.ModalResponse.alertFirstButtonReturn {
      Log.log("\(#function): 'Sign In' clicked in notification")
      signInHandler?()
    }
  }
#endif
}

#if os(iOS)
extension SessionNotification: UNUserNotificationCenterDelegate {
  public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    Log.log("\(#function): 'Sign In' clicked in notification")
    let actionId = response.actionIdentifier
    let categoryId = response.notification.request.content.categoryIdentifier
    if categoryId == NotificationIndentifier.sessionEndedNotificationCategory.rawValue,
       actionId == NotificationIndentifier.signInNotificationAction.rawValue {
      // User clicked on 'Sign In' in the notification
      signInHandler?()
    }

    DispatchQueue.main.async {
      completionHandler()
    }
  }
}
#endif
