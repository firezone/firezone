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
  func taskExecutesOperation() async {
    let executed = Flag()

    let task = CancellableTask {
      await executed.set(true)
    }

    // Give the task time to execute
    try? await Task.sleep(for: .milliseconds(50))

    let wasExecuted = await executed.get()
    #expect(wasExecuted == true)

    // Keep task alive until assertion
    _ = task
  }

  @Test("Task is cancelled when CancellableTask is deallocated")
  func taskCancelledOnDealloc() async {
    let wasCancelled = Flag()

    do {
      let _ = CancellableTask {
        // Wait long enough that we can dealloc the wrapper
        // When the CancellableTask is deallocated and calls cancel(),
        // Task.sleep throws CancellationError and aborts immediately (no need to wait 10 seconds)
        // The try? suppresses the error since CancellableTask requires a non-throwing closure
        try? await Task.sleep(for: .seconds(10))

        // After cancellation, Task.isCancelled will be true
        if Task.isCancelled {
          await wasCancelled.set(true)
        }
      }
      // CancellableTask goes out of scope here, triggering deinit -> cancel
    }

    // Give the cancelled task time to handle the cancellation
    try? await Task.sleep(for: .milliseconds(50))

    let taskWasCancelled = await wasCancelled.get()
    #expect(taskWasCancelled == true)
  }

  @Test("Setting to nil cancels the task")
  func settingToNilCancelsTask() async {
    let wasCancelled = Flag()

    var task: CancellableTask? = CancellableTask {
      // Task.sleep throws CancellationError when cancelled
      // The try? suppresses the error since CancellableTask requires a non-throwing closure
      try? await Task.sleep(for: .seconds(10))

      // After cancellation, Task.isCancelled will be true
      if Task.isCancelled {
        await wasCancelled.set(true)
      }
    }

    // Set to nil, triggering cancellation
    task = nil

    // Give the cancelled task time to check its cancellation status
    try? await Task.sleep(for: .milliseconds(50))

    let taskWasCancelled = await wasCancelled.get()
    #expect(taskWasCancelled == true)

    // Silence unused variable warning
    _ = task
  }
}
