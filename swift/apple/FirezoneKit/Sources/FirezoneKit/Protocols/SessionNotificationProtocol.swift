//
//  SessionNotificationProtocol.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import UserNotifications

/// Abstracts session notification operations for testing.
///
/// This protocol enables dependency injection in Store, allowing tests to
/// run without accessing UNUserNotificationCenter which is unavailable in test context.
/// Production uses `SessionNotification`, tests use `MockSessionNotification`.
@MainActor
public protocol SessionNotificationProtocol: AnyObject {
  /// Handler called when user clicks "Sign In" in a session expired notification.
  var signInHandler: () -> Void { get set }

  /// Requests notification permissions from the user.
  func askUserForNotificationPermissions() async throws -> UNAuthorizationStatus

  /// Loads the current notification authorization status.
  func loadAuthorizationStatus() async -> UNAuthorizationStatus

  #if os(macOS)
    /// Shows a signed-out alert on macOS.
    func showSignedOutAlertMacOS(_ message: String?) async
  #endif
}
