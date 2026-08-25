import Testing

@testable import FirezoneKit

/// Thread-safe flag for testing
private actor Flag {
  var value: Bool = false

  func set(_ newValue: Bool) {
    value = newValue
  }

  func get() -> Bool {
    value
  }
}

@Suite("CancellableTask Tests")
struct CancellableTaskTests {

  @Test("Task executes its operation")
  func taskExecutesOperation() async throws {
    let executed = Flag()

    let task = CancellableTask {
      await executed.set(true)
    }

    try await waitUntil { await executed.get() }

    // Keep task alive until assertion
    _ = task
  }

  @Test("Task is cancelled when CancellableTask is deallocated")
  func taskCancelledOnDealloc() async throws {
    let wasCancelled = Flag()

    do {
      _ = CancellableTask {
        do {
          try await Task.sleep(for: .seconds(10))
        } catch is CancellationError {
          await wasCancelled.set(true)
        } catch {}
      }
      // CancellableTask goes out of scope here, triggering deinit -> cancel
    }

    try await waitUntil { await wasCancelled.get() }
  }

  @Test("Setting to nil cancels the task")
  func settingToNilCancelsTask() async throws {
    let wasCancelled = Flag()

    var task: CancellableTask? = CancellableTask {
      do {
        try await Task.sleep(for: .seconds(10))
      } catch is CancellationError {
        await wasCancelled.set(true)
      } catch {}
    }

    // Set to nil, triggering cancellation
    task = nil

    try await waitUntil { await wasCancelled.get() }

    // Silence unused variable warning
    _ = task
  }
}
