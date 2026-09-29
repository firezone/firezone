//
//  SessionNotification.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import UserNotifications

#if os(macOS)
  import AppKit
#endif

// SessionNotification helps with showing iOS local notifications
// when the session ends.
// In macOS, it helps with showing an alert when the session ends.

public enum NotificationIndentifier: String {
  case sessionEndedNotificationCategory
  case sessionEndedWithoutSignInNotificationCategory
  case signInNotificationAction
  case dismissNotificationAction
}

@MainActor
public class SessionNotification: NSObject, SessionNotificationProtocol {
  public var signInHandler: () async -> Void = {}
  #if os(macOS)
    private let userDefaults: UserDefaults
  #endif
  private let notificationCenter = UNUserNotificationCenter.current()

  #if os(macOS)
    public init(userDefaults: UserDefaults) {
      self.userDefaults = userDefaults
      super.init()
      registerWithNotificationCenter()

      notificationCenter.requestAuthorization(options: [.sound, .badge, .alert]) { _, error in
        guard let error = error else { return }

        // If the user hasn't enabled notifications for Firezone, we may receive
        // a notificationsNotAllowed error here. Don't log it.
        if let unError = error as? UNError,
          unError.code == .notificationsNotAllowed
        {
          return
        }

        // Log all other errors
        Log.error(error)
      }
    }
  #else
    override public init() {
      super.init()
      registerWithNotificationCenter()
    }
  #endif

  private func registerWithNotificationCenter() {
    // A process has one delegate and one set of categories, so nothing else may set either.
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

    // Signing in again cannot restore these sessions, so this category only dismisses.
    let sessionEndedWithoutSignInCategory = UNNotificationCategory(
      identifier: NotificationIndentifier.sessionEndedWithoutSignInNotificationCategory.rawValue,
      actions: [dismissAction],
      intentIdentifiers: [],
      hiddenPreviewsBodyPlaceholder: "",
      options: [])

    var categories: Set<UNNotificationCategory> = [
      sessionEndedCategory, sessionEndedWithoutSignInCategory,
    ]

    #if os(macOS)
      let ignoreVersionAction = UNNotificationAction(
        identifier: UpdateNotification.dismissActionIdentifier,
        title: "Ignore Version",
        options: [])

      categories.insert(
        UNNotificationCategory(
          identifier: UpdateNotification.categoryIdentifier,
          actions: [ignoreVersionAction],
          intentIdentifiers: [],
          options: []))
    #endif

    notificationCenter.setNotificationCategories(categories)
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
    nonisolated public static func showDisconnectedNotificationiOS(_ message: String) {
      UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
        if notificationSettings.authorizationStatus == .authorized {
          Log.log(
            "Notifications are allowed. Alert style is \(notificationSettings.alertStyle.rawValue)"
          )
          let content = UNMutableNotificationContent()
          content.title = "Your Firezone session has ended"
          content.body = message
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

    /// Tells the user the session ended, in the words it ended with, when signing in
    /// again cannot restore it.
    nonisolated public static func showDisconnectedNotificationWithoutSignIniOS(_ message: String) {
      UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
        guard notificationSettings.authorizationStatus == .authorized else {
          Log.warning("Cannot show the disconnected notification: notifications denied")
          return
        }

        let content = UNMutableNotificationContent()
        content.title = "Your Firezone session has ended"
        content.body = message
        content.sound = .default
        content.categoryIdentifier =
          NotificationIndentifier.sessionEndedWithoutSignInNotificationCategory.rawValue
        let request = UNNotificationRequest(
          identifier: "FirezoneTunnelShutdownWithoutSignIn",
          content: content,
          trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
          if let error {
            Log.error(error)
          } else {
            Log.debug("Disconnected notification without sign-in requested")
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
    public func showDisconnectedAlertMacOS(_ message: String?) async {
      await MacOSAlert.showDisconnectedAlert(message)
    }

    @MainActor
    public func showRestartRequiredAlertMacOS() {
      MacOSAlert.showRestartRequiredAlert()
    }

    public func showUpdateNotification(version: SemanticVersion) {
      UpdateNotification.setLastNotifiedVersion(version: version, userDefaults: userDefaults)

      let content = UNMutableNotificationContent()
      content.title = "Update Firezone"
      content.body = "New version available"
      content.sound = .default
      content.categoryIdentifier = UpdateNotification.categoryIdentifier

      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
      )

      notificationCenter.add(request) { error in
        if let error = error {
          Log.error(error)
        }
      }
    }
  #endif
}

extension SessionNotification: UNUserNotificationCenterDelegate {
  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let actionId = response.actionIdentifier
    let categoryId = response.notification.request.content.categoryIdentifier
    if categoryId == NotificationIndentifier.sessionEndedNotificationCategory.rawValue,
      actionId == NotificationIndentifier.signInNotificationAction.rawValue
    {
      Log.log("\(#function): 'Sign In' clicked in notification")
      Task { @MainActor in
        await signInHandler()
      }
    }

    #if os(macOS)
      if categoryId == UpdateNotification.categoryIdentifier {
        Task { @MainActor in
          guard actionId == UpdateNotification.dismissActionIdentifier else {
            await NSWorkspace.shared.openAsync(UpdateNotification.downloadURL())
            return
          }

          // Don't notify them again for this version
          if let version = UpdateNotification.getLastNotifiedVersion(userDefaults: userDefaults) {
            UpdateNotification.setLastDismissedVersion(version: version, userDefaults: userDefaults)
          }
        }
      }
    #endif

    completionHandler()
  }

  #if os(macOS)
    nonisolated public func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler:
        @escaping (
          UNNotificationPresentationOptions
        ) -> Void
    ) {
      // Show the notification even when the app is in the foreground
      completionHandler([.badge, .banner, .sound])
    }
  #endif
}
