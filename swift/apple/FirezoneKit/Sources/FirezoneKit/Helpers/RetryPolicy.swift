//
//  RetryPolicy.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Configurable retry policy with exponential backoff.
///
/// Use this for operations that may fail transiently and benefit from retrying
/// with increasing delays between attempts.
struct RetryPolicy: Sendable {
  let maxAttempts: Int
  let baseDelayMs: Int

  /// Default policy for resource fetching during extension startup.
  /// Retries up to 5 times with delays: 100ms, 200ms, 400ms, 800ms, 1600ms
  static let resourceFetch = RetryPolicy(maxAttempts: 5, baseDelayMs: 100)

  /// Calculate the delay in nanoseconds for a given attempt number.
  /// Uses exponential backoff: baseDelayMs * 2^attempt
  func delay(forAttempt attempt: Int) -> UInt64 {
    let delayMs = baseDelayMs * (1 << attempt)
    return UInt64(delayMs * 1_000_000)
  }

  /// Returns the delay in milliseconds for logging purposes.
  func delayMs(forAttempt attempt: Int) -> Int {
    baseDelayMs * (1 << attempt)
  }

  /// Check if another retry should be attempted.
  func shouldRetry(attempt: Int) -> Bool {
    attempt < maxAttempts
  }
}
