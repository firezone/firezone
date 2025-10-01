import FirezoneKit
import Foundation
import NetworkExtension

/// SessionManager owns the Session lifecycle and manages command/event multiplexing.
///
/// This actor follows Android's pattern where the event loop owns the Session instance.
/// When the event loop exits, the Session is automatically cleaned up, ensuring Drop
/// is called on the Rust side to prevent memory leaks.
///
/// Commands are sent via AsyncStream (similar to Kotlin's Channel).
/// Events are polled from Rust's nextEvent() and forwarded to the event handler.
actor SessionManager {
  // Session ownership
  private var session: Session?
  private var eventLoopTask: Task<Void, Never>?

  // Command channel (Swift equivalent of Kotlin's Channel)
  private let commandContinuation: AsyncStream<SessionCommand>.Continuation
  private let commandStream: AsyncStream<SessionCommand>

  // Event handler callback
  private let eventHandler: (Event) async -> Void

  // Logging interval for event loop health monitoring
  private static let eventPollingLogInterval = 100

  init(eventHandler: @escaping (Event) async -> Void) {
    self.eventHandler = eventHandler
    (commandStream, commandContinuation) = AsyncStream.makeStream()
  }

  /// Starts the session and event loop.
  ///
  /// This creates a Rust Session via UniFFI and spawns the event loop task
  /// that owns the session lifecycle.
  func start(
    apiUrl: String,
    token: Token,
    deviceId: String,
    accountSlug: String,
    logFilter: String
  ) throws {
    Log.log("SessionManager: Starting session for account: \(accountSlug)")

    // Get device metadata
    let deviceName = DeviceMetadata.getDeviceName()
    let osVersion = DeviceMetadata.getOSVersion()
    let deviceInfo = try JSONEncoder().encode(DeviceMetadata.deviceInfo())
    let deviceInfoStr = String(data: deviceInfo, encoding: .utf8) ?? "{}"
    let logDir = SharedAccess.connlibLogFolderURL?.path ?? "/tmp/firezone"

    // Create the session
    let session: Session
    do {
      session = try Session.newApple(
        apiUrl: apiUrl,
        token: token.description,
        deviceId: deviceId,
        accountSlug: accountSlug,
        deviceName: deviceName,
        osVersion: osVersion,
        logDir: logDir,
        logFilter: logFilter,
        deviceInfo: deviceInfoStr
      )
    } catch {
      Log.error(error)
      throw AdapterError.connlibConnectError(String(describing: error))
    }

    self.session = session

    // Start event loop - THIS OWNS THE SESSION
    eventLoopTask = Task { [weak self] in
      await self?.runEventLoop(session: session)
    }

    Log.log("SessionManager: Session started successfully")
  }

  /// The main event loop that owns the Session lifecycle.
  ///
  /// This uses withTaskGroup to multiplex between:
  /// 1. Event polling from Rust (nextEvent)
  /// 2. Command handling from Swift (command channel)
  ///
  /// When either task completes, both are cancelled and the session is cleaned up.
  /// This ensures the Session's Drop is called on the Rust side.
  private func runEventLoop(session: Session) async {
    Log.log("SessionManager: Starting event loop")

    // Multiplex between commands and events
    await withTaskGroup(of: Void.self) { group in
      // Event polling task - polls Rust for events
      group.addTask { [weak self] in
        guard let self = self else { return }

        var eventCount = 0
        var pollAttempts = 0

        while !Task.isCancelled {
          pollAttempts += 1

          do {
            // Poll for next event from Rust
            if let event = try await session.nextEvent() {
              eventCount += 1
              Log.log(
                "SessionManager: Event received (\(eventCount)): \(String(describing: event))")
              await self.eventHandler(event)
            } else {
              // No event returned - session has ended
              Log.log("SessionManager: Event stream ended, exiting event loop")
              break
            }
          } catch {
            Log.error(error)
            Log.log("SessionManager: Error in event polling, exiting event loop")
            break
          }

          // Periodic health check logging
          if pollAttempts % Self.eventPollingLogInterval == 0 {
            Log.log("SessionManager: Event polling active - \(eventCount) events processed")
          }
        }

        Log.log("SessionManager: Event polling finished after \(eventCount) events")
      }

      // Command handling task - processes commands from Swift
      group.addTask { [weak self] in
        guard let self = self else { return }

        for await command in self.commandStream {
          await self.handleCommand(command, session: session)

          // Exit loop if disconnect command
          if case .disconnect = command {
            Log.log("SessionManager: Disconnect command received, exiting command loop")
            break
          }
        }

        Log.log("SessionManager: Command handling finished")
      }

      // Wait for first task to complete, then cancel all
      _ = await group.next()
      Log.log("SessionManager: One task completed, cancelling event loop")
      group.cancelAll()
    }

    // Cleanup when event loop exits
    // Assigning to `nil` will invoke `Drop` on the Rust side
    // Do NOT call disconnect() explicitly - let Drop handle everything
    Log.log("SessionManager: Event loop finished, cleaning up session")
    self.session = nil
    Log.log("SessionManager: Session cleaned up")
  }

  /// Handles a command by calling the appropriate session method.
  private func handleCommand(_ command: SessionCommand, session: Session) async {
    switch command {
    case .disconnect:
      Log.log("SessionManager: Handling disconnect command")
      // Assigning to `nil` will invoke `Drop` on the Rust side
      // Do NOT call disconnect() explicitly - let Drop handle everything
      self.session = nil

    case .setDisabledResources(let resources):
      Log.log("SessionManager: Handling setDisabledResources command")
      do {
        try session.setDisabledResources(disabledResources: resources)
      } catch {
        Log.error(error)
      }

    case .setDns(let servers):
      Log.log("SessionManager: Handling setDns command")
      do {
        try session.setDns(dnsServers: servers)
      } catch {
        Log.error(error)
      }

    case .reset(let reason):
      Log.log("SessionManager: Handling reset command: \(reason)")
      session.reset(reason: reason)
    }
  }

  /// Sends a command to the session via the command channel.
  ///
  /// This is safe to call from any thread/actor context.
  nonisolated func sendCommand(_ command: SessionCommand) {
    commandContinuation.yield(command)
  }

  /// Sets the TUN device by searching for it (async wrapper for setTunFromSearch).
  func setTunFromSearch() async throws {
    guard let session = session else {
      throw AdapterError.invalidSession(nil)
    }
    try session.setTunFromSearch()
  }

  /// Clears the session, triggering Drop on the Rust side.
  ///
  /// This must happen asynchronously to allow Rust to break cyclic dependencies
  /// between the runtime and the task that is executing the callback.
  func clearSession() async {
    // Assigning to `nil` will invoke `Drop` on the Rust side
    Log.log("SessionManager: Clearing session")
    self.session = nil
  }

  /// Stops the session by sending a disconnect command and cancelling the event loop.
  func stop() async {
    Log.log("SessionManager: Stopping")
    sendCommand(.disconnect)

    // Wait briefly for graceful shutdown
    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    // Cancel event loop task
    eventLoopTask?.cancel()
    eventLoopTask = nil

    // Close command stream
    commandContinuation.finish()

    Log.log("SessionManager: Stopped")
  }

  deinit {
    Log.log("SessionManager: deinit")
  }
}

/// Commands that can be sent to the Session.
///
/// This mirrors Android's TunnelCommand sealed class.
enum SessionCommand {
  case disconnect
  case setDisabledResources(String)
  case setDns(String)
  case reset(String)
}
