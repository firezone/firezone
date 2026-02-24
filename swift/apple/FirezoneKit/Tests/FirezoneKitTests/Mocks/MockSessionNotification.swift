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
  var signInHandler: () async -> Void = {}

  // Tracking
  var askUserForNotificationPermissionsCallCount = 0
  var loadAuthorizationStatusCallCount = 0
  var showSignedOutAlertCallCount = 0
  var lastAlertMessage: String?
  var showResourceNotificationCallCount = 0
  var lastResourceNotificationTitle: String?
  var lastResourceNotificationBody: String?

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

  func showResourceNotification(title: String, body: String) async {
    showResourceNotificationCallCount += 1
    lastResourceNotificationTitle = title
    lastResourceNotificationBody = body
  }

  #if os(macOS)
    func showSignedOutAlertMacOS(_ message: String?) async {
      showSignedOutAlertCallCount += 1
      lastAlertMessage = message
    }
  #endif
}
