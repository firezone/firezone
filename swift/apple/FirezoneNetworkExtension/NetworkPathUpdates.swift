import Network

/// Creates an AsyncStream that emits NWPath updates.
///
/// Cancels the monitor via `onTermination` when the consuming Task is cancelled.
/// This enables actors to manage NWPathMonitor lifecycle without needing
/// `nonisolated(unsafe)` or `@unchecked Sendable`.
func networkPathUpdates() -> AsyncStream<Network.NWPath> {
  let (stream, continuation) = AsyncStream.makeStream(of: Network.NWPath.self)

  let monitor = NWPathMonitor()
  monitor.pathUpdateHandler = { path in
    continuation.yield(path)
  }
  monitor.start(queue: .global())

  // Cancel monitor when stream terminates (Task cancelled or finished)
  continuation.onTermination = { _ in
    monitor.cancel()
  }

  return stream
}
