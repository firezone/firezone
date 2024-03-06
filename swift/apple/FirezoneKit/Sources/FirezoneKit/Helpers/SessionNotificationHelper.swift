//
//  SessionNotificationHelper.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import UserNotifications

// NotificationDecisionHelper helps with iOS local notifications.
// It doesn't do anything in macOS.

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
}

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
