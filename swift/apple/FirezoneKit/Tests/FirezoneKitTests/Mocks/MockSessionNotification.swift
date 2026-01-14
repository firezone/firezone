//
//  MockSessionNotification.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import UserNotifications

@testable import FirezoneKit

/// Mock implementation of SessionNotificationProtocol for testing.
///
/// This mock allows tests to run without accessing UNUserNotificationCenter,
/// which is unavailable in test context.
@MainActor
final class MockSessionNotification: SessionNotificationProtocol {
  var signInHandler: () -> Void = {}

  // Tracking
  var askUserForNotificationPermissionsCallCount = 0
  var loadAuthorizationStatusCallCount = 0
  var showSignedOutAlertCallCount = 0
  var lastAlertMessage: String?

  // Configurable responses
  var authorizationStatus: UNAuthorizationStatus = .notDetermined

  func askUserForNotificationPermissions() async throws -> UNAuthorizationStatus {
    askUserForNotificationPermissionsCallCount += 1
    return authorizationStatus
  }

  func loadAuthorizationStatus() async -> UNAuthorizationStatus {
    loadAuthorizationStatusCallCount += 1
    return authorizationStatus
  }

  #if os(macOS)
    func showSignedOutAlertMacOS(_ message: String?) async {
      showSignedOutAlertCallCount += 1
      lastAlertMessage = message
    }
  #endif
}
