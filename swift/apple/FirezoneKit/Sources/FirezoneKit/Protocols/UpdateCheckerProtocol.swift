//
//  UpdateCheckerProtocol.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Combine

  /// Abstracts update checking for testing.
  ///
  /// This protocol enables dependency injection in Store, allowing tests to
  /// run without accessing UNUserNotificationCenter which crashes in test context.
  /// Production uses `UpdateChecker`, tests use `MockUpdateChecker`.
  @MainActor
  public protocol UpdateCheckerProtocol: AnyObject, ObservableObject {
    var updateAvailable: Bool { get }
  }
#endif
