//
//  UpdateCheckerProtocol.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Combine

  /// Abstracts update checking to support dependency injection.
  ///
  /// In production, `UpdateChecker` uses `UNUserNotificationCenter` indirectly
  /// via `NotificationAdapter`, which can crash in test contexts.
  /// By depending on this protocol, tests can inject `MockUpdateChecker` to
  /// avoid that indirect `UNUserNotificationCenter` access.
  @MainActor
  public protocol UpdateCheckerProtocol: AnyObject, ObservableObject {
    var updateAvailable: Bool { get }
  }
#endif
