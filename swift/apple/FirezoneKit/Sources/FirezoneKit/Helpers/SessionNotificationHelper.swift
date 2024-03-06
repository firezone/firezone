//
//  SessionNotificationHelper.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
import AppKit
#endif

import Foundation

#if os(iOS)
import UserNotifications
#endif


// SessionNotificationHelper helps with showing iOS local notifications
// when the session ends.
// In macOS, it helps with showing an alert when the session ends.

public enum NotificationIndentifier: String {
  case sessionEndedNotificationCategory
  case signInNotificationAction
  case dismissNotificationAction
}

public class SessionNotificationHelper: NSObject {

  enum NotificationDecision {
    case uninitialized
    case notDetermined
    case determined(isNotificationAllowed: Bool)

    var isInitialized: Bool {
      switch self {
      case .uninitialized: return false
      default: return true
      }
    }
  }

  private let logger: AppLogger
  private let authStore: AuthStore

  @Published var notificationDecision: NotificationDecision = .uninitialized {
    didSet {
      self.logger.log(
        "NotificationDecisionHelper: notificationDecision changed to \(notificationDecision)"
      )
    }
  }

  public init(logger: AppLogger, authStore: AuthStore) {

    self.logger = logger
    self.authStore = authStore

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
      let notificationActions = [signInAction, dismissAction]
      let certificateExpiryCategory = UNNotificationCategory(
        identifier: NotificationIndentifier.sessionEndedNotificationCategory.rawValue,
        actions: notificationActions,
        intentIdentifiers: [],
        hiddenPreviewsBodyPlaceholder: "",
        options: [])

      notificationCenter.setNotificationCategories([certificateExpiryCategory])
      notificationCenter.getNotificationSettings { notificationSettings in
        self.logger.log(
          "NotificationDecisionHelper: getNotificationSettings returned. authorizationStatus is \(notificationSettings.authorizationStatus)"
        )
        switch notificationSettings.authorizationStatus {
        case .notDetermined:
          self.notificationDecision = .notDetermined
        case .authorized:
          self.notificationDecision = .determined(isNotificationAllowed: true)
        case .denied:
          self.notificationDecision = .determined(isNotificationAllowed: false)
        default:
          break
        }
      }
    #endif
  }

  #if os(iOS)
    func askUserForNotificationPermissions() {
      guard case .notDetermined = self.notificationDecision else { return }
      let notificationCenter = UNUserNotificationCenter.current()
      notificationCenter.requestAuthorization(options: [.sound, .alert]) { isAuthorized, error in
        self.logger.log(
          "NotificationDecisionHelper.askUserForNotificationPermissions: isAuthorized = \(isAuthorized)"
        )
        if let error = error {
          self.logger.log(
            "NotificationDecisionHelper.askUserForNotificationPermissions: Error: \(error)"
          )
        }
        self.notificationDecision = .determined(isNotificationAllowed: isAuthorized)
      }
    }
  #endif

  #if os(iOS)
    // In iOS, use User Notifications.
    // This gets called from the tunnel side.
    public static func showSignedOutNotificationiOS(logger: AppLogger) {
      UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
        if notificationSettings.authorizationStatus == .authorized {
          logger.log(
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
              logger.error("showSignedOutNotificationiOS: Error requesting notification: \(error)")
            } else {
              logger.error("showSignedOutNotificationiOS: Successfully requested notification")
            }
          }
        }
      }
    }
  #elseif os(macOS)
    // In macOS, use a Cocoa alert.
    // This gets called from the app side.
    static func showSignedOutAlertmacOS(logger: AppLogger, authStore: AuthStore) {
      let alert = NSAlert()
      alert.messageText = "Your Firezone session has ended"
      alert.informativeText = "Please sign in again to reconnect"
      alert.addButton(withTitle: "Sign In")
      alert.addButton(withTitle: "Cancel")
      NSApp.activate(ignoringOtherApps: true)
      let response = alert.runModal()
      if response == NSApplication.ModalResponse.alertFirstButtonReturn {
        logger.log("NotificationDecisionHelper: \(#function): 'Sign In' clicked in notification")
        Task {
          do {
            try await authStore.signIn()
          } catch {
            logger.error("Error signing in: \(error)")
          }
        }
      }
    }
    #endif
}

#if os(iOS)
  extension SessionNotificationHelper: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
      self.logger.log("NotificationDecisionHelper: \(#function): 'Sign In' clicked in notification")
      let actionId = response.actionIdentifier
      let categoryId = response.notification.request.content.categoryIdentifier
      if categoryId == NotificationIndentifier.sessionEndedNotificationCategory.rawValue,
         actionId == NotificationIndentifier.signInNotificationAction.rawValue {
        // User clicked on 'Sign In' in the notification
        Task {
          do {
            try await self.authStore.signIn()
          } catch {
            self.logger.error("Error signing in: \(error)")
          }
          DispatchQueue.main.async {
            completionHandler()
          }
        }
      } else {
        DispatchQueue.main.async {
          completionHandler()
        }
      }
    }
  }
#endif
