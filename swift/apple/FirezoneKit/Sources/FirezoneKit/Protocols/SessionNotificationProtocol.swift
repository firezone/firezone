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
  var signInHandler: () async -> Void { get set }

  /// Requests notification permissions from the user.
  func askUserForNotificationPermissions() async throws -> UNAuthorizationStatus

  /// Loads the current notification authorization status.
  func loadAuthorizationStatus() async -> UNAuthorizationStatus

  /// Shows a notification for an unreachable resource.
  func showResourceNotification(title: String, body: String) async

  /// Shows a notification saying why the session ended, with a Sign In action if
  /// `requiresSignIn`.
  func showDisconnectedNotification(_ message: String, requiresSignIn: Bool)

  #if os(macOS)
    /// Shows an alert asking the user to restart to finish a system extension update.
    func showRestartRequiredAlertMacOS()

    /// Shows a notification that `version` is available.
    func showUpdateNotification(version: SemanticVersion)
  #endif
}
