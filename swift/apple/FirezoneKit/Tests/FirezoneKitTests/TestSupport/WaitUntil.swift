//
//  WaitUntil.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct TimeoutError: Error {}

/// Waits for `condition` to hold, giving up after `timeout`.
///
/// What tests wait on here is other tasks reaching a point, which takes as long
/// as the scheduler needs. A fixed sleep either gives that time away or, on a
/// loaded machine, ends first and reports a failure that says nothing about the
/// code under test.
func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while await !condition() {
    guard clock.now < deadline else { throw TimeoutError() }

    try await Task.sleep(for: .milliseconds(10))
  }
}
