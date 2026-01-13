//
//  ConnectionWatchdogTests.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Testing

@testable import FirezoneKit

@Suite("ConnectionWatchdog Tests")
struct ConnectionWatchdogTests {

  @Test("Watchdog fires after timeout")
  @MainActor
  func firesAfterTimeout() async {
    let fired = Flag()
    let watchdog = ConnectionWatchdog(timeoutNs: 100_000_000) {  // 100ms
      await fired.set(true)
    }

    watchdog.start()
    #expect(watchdog.isActive == true)

    try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms - wait for timeout with margin
    #expect(await fired.get() == true)
  }

  @Test("Watchdog can be cancelled before firing")
  @MainActor
  func cancelPreventsCallback() async {
    let fired = Flag()
    let watchdog = ConnectionWatchdog(timeoutNs: 200_000_000) {  // 200ms
      await fired.set(true)
    }

    watchdog.start()
    #expect(watchdog.isActive == true)

    watchdog.cancel()
    #expect(watchdog.isActive == false)

    try? await Task.sleep(nanoseconds: 350_000_000)  // 350ms - past timeout with margin
    #expect(await fired.get() == false)
  }

  @Test("Starting again cancels previous watchdog")
  @MainActor
  func restartCancelsPrevious() async {
    let counter = Counter()
    let watchdog = ConnectionWatchdog(timeoutNs: 100_000_000) {  // 100ms
      await counter.increment()
    }

    watchdog.start()
    try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms - before first fires
    watchdog.start()  // Restart - should cancel previous

    try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms - only second should fire

    let count = await counter.get()
    #expect(count == 1)  // Only the second watchdog should have fired
  }

  @Test("Watchdog is not active before start")
  @MainActor
  func notActiveBeforeStart() {
    let watchdog = ConnectionWatchdog(timeoutNs: 100_000_000) {}
    #expect(watchdog.isActive == false)
  }

  @Test("Watchdog is not active after cancel")
  @MainActor
  func notActiveAfterCancel() {
    let watchdog = ConnectionWatchdog(timeoutNs: 100_000_000) {}
    watchdog.start()
    watchdog.cancel()
    #expect(watchdog.isActive == false)
  }

  @Test("Multiple cancels are safe")
  @MainActor
  func multipleCancelsAreSafe() {
    let watchdog = ConnectionWatchdog(timeoutNs: 100_000_000) {}
    watchdog.cancel()  // Cancel before start
    watchdog.start()
    watchdog.cancel()
    watchdog.cancel()  // Cancel again
    watchdog.cancel()  // And again
    #expect(watchdog.isActive == false)
  }
}

// MARK: - Test Helpers

/// Thread-safe flag for async tests
private actor Flag {
  var value: Bool = false

  func set(_ newValue: Bool) {
    value = newValue
  }

  func get() -> Bool {
    value
  }
}

/// Thread-safe counter for async tests
private actor Counter {
  var value: Int = 0

  func increment() {
    value += 1
  }

  func get() -> Int {
    value
  }
}
