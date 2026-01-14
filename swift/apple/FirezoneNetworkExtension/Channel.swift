import Foundation

/// Sender side of a channel - can only send values.
///
/// This wraps AsyncStream.Continuation to provide automatic cleanup via RAII.
/// When the sender is deallocated, the continuation is automatically finished,
/// matching Rust's behaviour where dropping a sender closes the channel.
final class Sender<T: Sendable>: Sendable {
  private let continuation: AsyncStream<T>.Continuation

  fileprivate init(continuation: AsyncStream<T>.Continuation) {
    self.continuation = continuation
  }

  /// Sends a value into the channel.
  @discardableResult
  func send(_ value: T) -> AsyncStream<T>.Continuation.YieldResult {
    continuation.yield(value)
  }

  /// Explicitly finishes the channel (optional, as deinit will do this automatically).
  func finish() {
    continuation.finish()
  }

  deinit {
    continuation.finish()
  }
}

/// Receiver side of a channel - can only receive values.
///
/// This wraps AsyncStream to provide the receiving end of the channel.
/// Values can be consumed by iterating over the stream:
///
///     for await value in receiver.stream {
///         // handle value
///     }
///
final class Receiver<T: Sendable>: Sendable {
  let stream: AsyncStream<T>

  fileprivate init(stream: AsyncStream<T>) {
    self.stream = stream
  }
}

/// Channel factory - creates sender/receiver pairs matching Rust's channel pattern.
///
/// This provides a type-safe way to create unidirectional communication channels,
/// where the sender can only send and the receiver can only receive.
///
/// Example usage:
///
///     let (sender, receiver) = Channel.create<Event>()
///
///     // Producer task
///     Task {
///         sender.send(someEvent)
///     }
///
///     // Consumer task
///     Task {
///         for await event in receiver.stream {
///             handle(event)
///         }
///     }
///
struct Channel {
  /// Creates a sender/receiver pair for type-safe unidirectional communication.
  static func create<T: Sendable>() -> (Sender<T>, Receiver<T>) {
    // Required pattern for AsyncStream continuation capture
    // swiftlint:disable:next implicitly_unwrapped_optional
    var continuation: AsyncStream<T>.Continuation!
    let stream = AsyncStream<T> { cont in
      continuation = cont
    }

    let sender = Sender(continuation: continuation)
    let receiver = Receiver(stream: stream)

    return (sender, receiver)
  }
}
