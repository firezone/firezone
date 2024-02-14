//
//  NotificationDecisionHelper.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import UserNotifications

public class NotificationDecisionHelper {

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

  @Published var notificationDecision: NotificationDecision = .uninitialized {
    didSet {
      self.logger.log(
        "NotificationDecisionHelper: notificationDecision changed to \(notificationDecision)"
      )
    }
  }

  init(logger: AppLogger) {

    self.logger = logger

    #if os(iOS)
      UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
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
}
