//
//  IPCClient.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
@preconcurrency import NetworkExtension

// TODO: Use a more abstract IPC protocol to make this less terse

enum IPCClient {
  enum Error: Swift.Error {
    case decodeIPCDataFailed
    case noIPCData
    case invalidStatus(NEVPNStatus)

    var localizedDescription: String {
      switch self {
      case .decodeIPCDataFailed:
        return "Decoding IPC data failed."
      case .noIPCData:
        return "No IPC data returned from the XPC connection!"
      case .invalidStatus(let status):
        return "The IPC operation couldn't complete because the VPN status is \(status)."
      }
    }
  }

  // Encoder used to send messages to the tunnel
  private static let encoder = PropertyListEncoder()
  private static let decoder = PropertyListDecoder()

  // Auto-connect
  @MainActor
  static func start(session: NETunnelProviderSession, configuration: Configuration) throws {
    let tunnelConfiguration = configuration.toTunnelConfiguration()
    let configData = try encoder.encode(tunnelConfiguration)
    let options: [String: NSObject] = [
      "configuration": configData as NSObject
    ]

    try validateSession(session).startTunnel(options: options)
  }

  // Sign in
  @MainActor
  static func start(session: NETunnelProviderSession, token: String, configuration: Configuration)
    throws
  {
    let tunnelConfiguration = configuration.toTunnelConfiguration()
    let configData = try encoder.encode(tunnelConfiguration)
    let options: [String: NSObject] = [
      "token": token as NSObject,
      "configuration": configData as NSObject,
    ]

    try validateSession(session).startTunnel(options: options)
  }

  static func signOut(session: NETunnelProviderSession) async throws {
    try await sendMessageWithoutResponse(session: session, message: ProviderMessage.signOut)
    try stop(session: session)
  }

  static func stop(session: NETunnelProviderSession) throws {
    try validateSession(session).stopTunnel()
  }

  @MainActor
  static func fetchResources(session: NETunnelProviderSession, currentHash: Data) async throws -> Data? {
    // Get data from the provider - if hash matches, provider returns nil
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data?, Swift.Error>) in
      do {
        let encoded = try encoder.encode(ProviderMessage.getResourceList(currentHash))
        try validateSession(session, requiredStatuses: [.connected]).sendProviderMessage(encoded) { data in
          continuation.resume(returning: data)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  #if os(macOS)
    // On macOS, IPC calls to the system extension won't work after it's been upgraded, until the startTunnel call.
    // Since we rely on IPC for the GUI to function, we need to send a dummy `startTunnel` that doesn't actually
    // start the tunnel, but causes the system to wake the extension.
    @MainActor
    static func dryStartStopCycle(session: NETunnelProviderSession, configuration: Configuration)
      throws
    {
      let tunnelConfiguration = configuration.toTunnelConfiguration()
      let configData = try encoder.encode(tunnelConfiguration)
      let options: [String: NSObject] = [
        "dryRun": true as NSObject,
        "configuration": configData as NSObject,
      ]
      try validateSession(session).startTunnel(options: options)
    }
  #endif

  static func setConfiguration(session: NETunnelProviderSession, _ configuration: Configuration)
    async throws
  {
    let tunnelConfiguration = await configuration.toTunnelConfiguration()
    let message = ProviderMessage.setConfiguration(tunnelConfiguration)

    if session.status != .connected {
      Log.trace("Not setting configuration whilst not connected")
      return
    }
    try await sendMessageWithoutResponse(session: session, message: message)
  }

  // MARK: - Log operations with utun cleanup

  #if os(macOS)
    /// Wraps an IPC call with wake-up and cleanup logic when VPN is not connected.
    ///
    /// On macOS, IPC calls can wake the network extension, which creates a utun device.
    /// If not properly cleaned up (via stop), these devices accumulate.
    @MainActor
    private static func wrapIPCCallIfNeeded<T: Sendable>(
      session: NETunnelProviderSession,
      configuration: Configuration,
      operation: @MainActor () async throws -> T
    ) async throws -> T {
      if session.status == .connected {
        // Extension already running, utun already created, just execute
        return try await operation()
      }

      // Extension needs waking, must cleanup afterwards
      try dryStartStopCycle(session: session, configuration: configuration)

      // Wait for extension to wake up and be ready for IPC (500ms)
      try await Task.sleep(nanoseconds: 500_000_000)

      defer {
        do {
          try stop(session: session)
        } catch {
          Log.error(error)
        }
      }

      return try await operation()
    }
  #else
    /// On iOS, IPC calls don't have the utun accumulation issue. Execute directly.
    private static func wrapIPCCallIfNeeded<T: Sendable>(
      session: NETunnelProviderSession,
      configuration: Configuration,
      operation: @MainActor () async throws -> T
    ) async throws -> T {
      return try await operation()
    }
  #endif

  // MARK: - Low-level IPC operations

  @MainActor
  static func clearLogs(session: NETunnelProviderSession, configuration: Configuration)
    async throws
  {
    try await wrapIPCCallIfNeeded(session: session, configuration: configuration) {
      try await sendMessageWithoutResponse(session: session, message: ProviderMessage.clearLogs)
    }
  }

  @MainActor
  static func getLogFolderSize(
    session: NETunnelProviderSession, configuration: Configuration
  ) async throws -> Int64 {
    return try await wrapIPCCallIfNeeded(session: session, configuration: configuration) {
      return try await withCheckedThrowingContinuation { continuation in

        do {
          try validateSession(session).sendProviderMessage(
            encoder.encode(ProviderMessage.getLogFolderSize)
          ) { data in

            guard let data = data
            else {
              continuation
                .resume(throwing: Error.noIPCData)

              return
            }
            data.withUnsafeBytes { rawBuffer in
              continuation.resume(returning: rawBuffer.load(as: Int64.self))
            }
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  @MainActor
  static func exportLogs(
    session: NETunnelProviderSession,
    configuration: Configuration,
    fileHandle: FileHandle
  ) async throws {
    try await wrapIPCCallIfNeeded(session: session, configuration: configuration) {
      try await withCheckedThrowingContinuation { continuation in
        exportLogsCallback(
          session: session,
          appender: { chunk in
            do {
              // Append each chunk to the archive
              try fileHandle.seekToEnd()
              fileHandle.write(chunk.data)

              if chunk.done {
                try fileHandle.close()
                continuation.resume()
              }
            } catch {
              try? fileHandle.close()
              continuation.resume(throwing: error)
            }
          },
          errorHandler: { error in
            try? fileHandle.close()
            continuation.resume(throwing: error)
          }
        )
      }
    }
  }

  // Call this with a closure that will append each chunk to a buffer
  // of some sort, like a file. The completed buffer is a valid Apple Archive
  // in AAR format.
  private static func exportLogsCallback(
    session: NETunnelProviderSession,
    appender: @escaping (LogChunk) -> Void,
    errorHandler: @escaping (Error) -> Void
  ) {
    func loop() {
      do {
        try validateSession(session).sendProviderMessage(
          encoder.encode(ProviderMessage.exportLogs)
        ) { data in
          guard let data = data
          else {
            errorHandler(Error.noIPCData)

            return
          }

          guard
            let chunk = try? decoder.decode(
              LogChunk.self, from: data
            )
          else {
            errorHandler(Error.decodeIPCDataFailed)

            return
          }

          appender(chunk)

          if !chunk.done {
            // Continue
            loop()
          }
        }
      } catch {
        Log.error(error)
      }
    }

    // Start exporting
    loop()
  }

  // Subscribe to system notifications about our VPN status changing
  // and let our handler know about them.
  static func subscribeToVPNStatusUpdates(
    session: NETunnelProviderSession,
    handler: @escaping @MainActor (NEVPNStatus) async throws -> Void
  ) {
    Task {
      for await notification in NotificationCenter.default.notifications(
        named: .NEVPNStatusDidChange)
      {
        guard let notificationSession = notification.object as? NETunnelProviderSession
        else {
          return
        }

        // Only handle notifications for our session
        if notificationSession === session {
          do { try await handler(notificationSession.status) } catch { Log.error(error) }
        }
      }
    }
  }

  static func sessionStatus(session: NETunnelProviderSession) -> NEVPNStatus {
    return session.status
  }

  private static func validateSession(
    _ session: NETunnelProviderSession,
    requiredStatuses: Set<NEVPNStatus> = []
  ) throws -> NETunnelProviderSession {
    if requiredStatuses.isEmpty || requiredStatuses.contains(session.status) {
      return session
    }

    throw Error.invalidStatus(session.status)
  }

  private static func sendMessageWithoutResponse(
    session: NETunnelProviderSession,
    message: ProviderMessage
  ) async throws {
    try await withCheckedThrowingContinuation { continuation in
      do {
        try validateSession(session).sendProviderMessage(encoder.encode(message)) { _ in
          continuation.resume()
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
