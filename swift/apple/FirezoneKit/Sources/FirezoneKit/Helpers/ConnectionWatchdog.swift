//
//  ConnectionWatchdog.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Monitors connection state and triggers a callback if stuck for too long.
///
/// Use this to detect when the VPN connection is stuck in a transitional state
/// (like "connecting") and needs intervention. The watchdog can be started when
/// entering a state, and will fire the callback if not cancelled before the timeout.
///
/// Example usage:
/// ```swift
/// let watchdog = ConnectionWatchdog(timeoutNs: 10_000_000_000) {
///     // Handle timeout - e.g., restart the connection
/// }
/// watchdog.start()  // When entering connecting state
/// watchdog.cancel() // When transitioning to connected/disconnected
/// ```
@MainActor
final class ConnectionWatchdog {
  private var watchdogTask: Task<Void, Never>?
  private let timeoutNs: UInt64
  private let onTimeout: @MainActor () async -> Void

  /// Create a new watchdog with the specified timeout.
  ///
  /// - Parameters:
  ///   - timeoutNs: Timeout in nanoseconds (default: 10 seconds)
  ///   - onTimeout: Async callback to execute if the watchdog fires
  init(timeoutNs: UInt64 = 10_000_000_000, onTimeout: @escaping @MainActor () async -> Void) {
    self.timeoutNs = timeoutNs
    self.onTimeout = onTimeout
  }

  /// Start the watchdog timer. If already running, cancels the previous timer first.
  func start() {
    cancel()
    watchdogTask = Task { [weak self, timeoutNs, onTimeout] in
      try? await Task.sleep(nanoseconds: timeoutNs)
      guard !Task.isCancelled, self != nil else { return }
      await onTimeout()
    }
  }

  /// Cancel the watchdog timer if running.
  func cancel() {
    watchdogTask?.cancel()
    watchdogTask = nil
  }

  /// Check if the watchdog is currently active (started and not cancelled).
  var isActive: Bool {
    guard let task = watchdogTask else { return false }
    return !task.isCancelled
  }
}
