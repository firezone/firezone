import Testing

@testable import FirezoneKit

/// Thread-safe flag for testing
private actor Flag {
  var value: Bool = false

  func set(_ newValue: Bool) {
    value = newValue
  }

  /// The flag once it is set, or its value at `timeout`.
  ///
  /// What these tests wait on is a task noticing cancellation, which takes as
  /// long as the scheduler needs. A fixed sleep either gives that away or, on a
  /// loaded machine, ends first and reports a failure that says nothing about
  /// the code under test.
  func waitUntilSet(timeout: Duration = .seconds(5)) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)

    while ContinuousClock.now < deadline {
      if value {
        return true
      }

      try? await Task.sleep(for: .milliseconds(5))
    }

    return value
  }
}

@Suite("CancellableTask Tests")
struct CancellableTaskTests {

  @Test("Task executes its operation")
  func taskExecutesOperation() async {
    let executed = Flag()

    let task = CancellableTask {
      await executed.set(true)
    }

    let wasExecuted = await executed.waitUntilSet()
    #expect(wasExecuted == true)

    // Keep task alive until assertion
    _ = task
  }

  @Test("Task is cancelled when CancellableTask is deallocated")
  func taskCancelledOnDealloc() async {
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

    let taskWasCancelled = await wasCancelled.waitUntilSet()
    #expect(taskWasCancelled == true)
  }

  @Test("Setting to nil cancels the task")
  func settingToNilCancelsTask() async {
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

    let taskWasCancelled = await wasCancelled.waitUntilSet()
    #expect(taskWasCancelled == true)

    // Silence unused variable warning
    _ = task
  }
}
