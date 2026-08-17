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
  case administratorActionRequiredNotificationCategory
  case signInNotificationAction
  case dismissNotificationAction
}

@MainActor
public class SessionNotification: NSObject, SessionNotificationProtocol {
  public var signInHandler: () async -> Void = {}
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

      let sessionEndedCategory = UNNotificationCategory(
        identifier: NotificationIndentifier.sessionEndedNotificationCategory.rawValue,
        actions: [signInAction, dismissAction],
        intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: "",
        options: [])

      let administratorActionRequiredCategory = UNNotificationCategory(
        identifier: NotificationIndentifier.administratorActionRequiredNotificationCategory
          .rawValue,
        actions: [dismissAction],
        intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: "",
        options: [])

      notificationCenter.setNotificationCategories([
        sessionEndedCategory,
        administratorActionRequiredCategory,
      ])
    #endif
  }

  public func askUserForNotificationPermissions() async throws -> UNAuthorizationStatus {
    // Ask the user for permission.
    try await notificationCenter.requestAuthorization(options: [.sound, .alert])

    // Retrieve the result
    return await loadAuthorizationStatus()
  }

  public func loadAuthorizationStatus() async -> UNAuthorizationStatus {
    let settings = await notificationCenter.notificationSettings()

    return settings.authorizationStatus
  }

  /// Shows a notification for an unreachable resource
  ///
  /// - Parameters:
  ///   - title: The notification title
  ///   - body: The notification body text
  public func showResourceNotification(title: String, body: String) async {
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

    nonisolated public static func showDeviceAttestationFailureNotificationiOS(_ message: String) {
      showAdministratorActionRequiredNotificationiOS(
        identifier: "FirezoneDeviceAttestationFailed",
        title: "Device attestation failed",
        message: message
      )
    }

    nonisolated public static func showX509ConnectionFailureNotificationiOS(_ message: String) {
      showAdministratorActionRequiredNotificationiOS(
        identifier: "FirezoneX509ConnectionFailed",
        title: "Firezone disconnected",
        message: message
      )
    }

    nonisolated private static func showAdministratorActionRequiredNotificationiOS(
      identifier: String,
      title: String,
      message: String
    ) {
      UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
        guard notificationSettings.authorizationStatus == .authorized else {
          Log.warning("Cannot show administrator-action notification: notifications denied")
          return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = SessionAuthenticationMode.x509.failureMessage(message)
        content.sound = .default
        content.categoryIdentifier =
          NotificationIndentifier.administratorActionRequiredNotificationCategory.rawValue
        let request = UNNotificationRequest(
          identifier: identifier,
          content: content,
          trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
          if let error {
            Log.error("Failed to show administrator-action notification: \(error)")
          } else {
            Log.info("Administrator-action notification shown")
          }
        }
      }
    }
  #elseif os(macOS)
    // In macOS, use a Cocoa alert.
    // This gets called from the app side.
    @MainActor
    public func showSignedOutAlertMacOS(_ message: String?) async {
      let signInClicked = await MacOSAlert.showSignedOutAlert(message)
      if signInClicked {
        Log.log("\(#function): 'Sign In' clicked in notification")
        await signInHandler()
      }
    }

    @MainActor
    public func showDisconnectedAlertMacOS(
      _ message: String?,
      authenticationMode: SessionAuthenticationMode
    ) async {
      await MacOSAlert.showDisconnectedAlert(message, authenticationMode: authenticationMode)
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
      let actionId = response.actionIdentifier
      let categoryId = response.notification.request.content.categoryIdentifier
      Log.log("\(#function): notification response (category=\(categoryId), action=\(actionId))")
      if categoryId == NotificationIndentifier.sessionEndedNotificationCategory.rawValue,
        actionId == NotificationIndentifier.signInNotificationAction.rawValue
      {
        // User clicked on 'Sign In' in the notification
        Log.log("\(#function): 'Sign In' clicked in session-ended notification")
        Task { @MainActor in
          await signInHandler()
        }
      }

      completionHandler()
    }
  }
#endif
