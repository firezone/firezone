//
//  RetryPolicyTests.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Testing

@testable import FirezoneKit

@Suite("RetryPolicy Tests")
struct RetryPolicyTests {

  @Test("Exponential backoff calculates correct delays in nanoseconds")
  func exponentialBackoffNanoseconds() {
    let policy = RetryPolicy(maxAttempts: 5, baseDelayMs: 100)

    #expect(policy.delay(forAttempt: 0) == 100_000_000)  // 100ms
    #expect(policy.delay(forAttempt: 1) == 200_000_000)  // 200ms
    #expect(policy.delay(forAttempt: 2) == 400_000_000)  // 400ms
    #expect(policy.delay(forAttempt: 3) == 800_000_000)  // 800ms
    #expect(policy.delay(forAttempt: 4) == 1_600_000_000)  // 1600ms
  }

  @Test("Exponential backoff calculates correct delays in milliseconds")
  func exponentialBackoffMilliseconds() {
    let policy = RetryPolicy(maxAttempts: 5, baseDelayMs: 100)

    #expect(policy.delayMs(forAttempt: 0) == 100)
    #expect(policy.delayMs(forAttempt: 1) == 200)
    #expect(policy.delayMs(forAttempt: 2) == 400)
    #expect(policy.delayMs(forAttempt: 3) == 800)
    #expect(policy.delayMs(forAttempt: 4) == 1600)
  }

  @Test("shouldRetry respects maxAttempts boundary")
  func shouldRetryBoundary() {
    let policy = RetryPolicy(maxAttempts: 3, baseDelayMs: 100)

    #expect(policy.shouldRetry(attempt: 0) == true)
    #expect(policy.shouldRetry(attempt: 1) == true)
    #expect(policy.shouldRetry(attempt: 2) == true)
    #expect(policy.shouldRetry(attempt: 3) == false)
    #expect(policy.shouldRetry(attempt: 4) == false)
  }

  @Test("shouldRetry with zero maxAttempts never retries")
  func zeroMaxAttempts() {
    let policy = RetryPolicy(maxAttempts: 0, baseDelayMs: 100)

    #expect(policy.shouldRetry(attempt: 0) == false)
  }

  @Test("Default resourceFetch policy has expected values")
  func defaultResourceFetchPolicy() {
    let policy = RetryPolicy.resourceFetch

    #expect(policy.maxAttempts == 5)
    #expect(policy.baseDelayMs == 100)
  }

  @Test("Custom base delay scales exponentially")
  func customBaseDelay() {
    let policy = RetryPolicy(maxAttempts: 3, baseDelayMs: 50)

    #expect(policy.delayMs(forAttempt: 0) == 50)
    #expect(policy.delayMs(forAttempt: 1) == 100)
    #expect(policy.delayMs(forAttempt: 2) == 200)
  }

  @Test("Large attempt numbers produce large delays")
  func largeAttemptNumber() {
    let policy = RetryPolicy(maxAttempts: 10, baseDelayMs: 100)

    // 100ms * 2^9 = 51200ms = 51.2 seconds
    #expect(policy.delayMs(forAttempt: 9) == 51200)
  }
}
