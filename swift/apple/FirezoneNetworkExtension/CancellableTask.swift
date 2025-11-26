import Foundation

/// RAII wrapper that cancels its task on deallocation.
///
/// This enables actors to manage task lifecycles without needing `nonisolated(unsafe)`.
/// When stored as an actor-isolated property, the task is automatically cancelled
/// when the actor is deallocated (via ARC releasing the wrapper).
///
/// Fully Sendable because Task<Void, Never> is Sendable and the property is immutable.
final class CancellableTask: Sendable {
  private let task: Task<Void, Never>

  init(_ task: Task<Void, Never>) {
    self.task = task
  }

  deinit {
    task.cancel()
  }
}
