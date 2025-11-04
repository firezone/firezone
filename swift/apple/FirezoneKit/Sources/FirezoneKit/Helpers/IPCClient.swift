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
  static let encoder = PropertyListEncoder()
  static let decoder = PropertyListDecoder()

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

  static func clearLogs(session: NETunnelProviderSession) async throws {
    try await sendMessageWithoutResponse(session: session, message: ProviderMessage.clearLogs)
  }

  static func getLogFolderSize(session: NETunnelProviderSession) async throws -> Int64 {
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

  // Call this with a closure that will append each chunk to a buffer
  // of some sort, like a file. The completed buffer is a valid Apple Archive
  // in AAR format.
  static func exportLogs(
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
