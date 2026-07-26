import Foundation

/// RAII wrapper that cancels its task on deallocation.
///
/// This enables classes to manage task lifecycles cleanly.
/// When stored as a property, the task is automatically cancelled
/// when the property is set to nil or the owner is deallocated (via ARC releasing the wrapper).
///
/// Fully Sendable because Task<Void, Never> is Sendable and the property is immutable.
public final class CancellableTask: Sendable {
  private let task: Task<Void, Never>

  public init(_ operation: @escaping @Sendable () async -> Void) {
    self.task = Task(operation: operation)
  }

  /// Awaits the task's completion without cancelling it, giving up once
  /// `timeout` elapses.
  ///
  /// Built on a stream raced by two tasks because awaiting a non-throwing
  /// task's `value` never returns early on cancellation.
  public func wait(timeout: Duration) async {
    let task = self.task

    let events = AsyncStream<Void> { continuation in
      Task {
        await task.value
        continuation.finish()
      }
      Task {
        try? await Task.sleep(for: timeout)
        continuation.finish()
      }
    }

    for await _ in events {}
  }

  deinit {
    task.cancel()
  }
}
