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
  static func start(session: NETunnelProviderSession) throws {
    try session.startTunnel()
  }

  // Sign in
  @MainActor
  static func start(session: NETunnelProviderSession, token: String) throws {
    let options: [String: NSObject] = [
      "token": token as NSObject
    ]

    try session.startTunnel(options: options)
  }

  @MainActor
  static func signOut(session: NETunnelProviderSession) async throws {
    let message = ProviderMessage.signOut
    let _ = try await sendProviderMessage(session: session, message: message)

    session.stopTunnel()
  }

  @MainActor
  static func fetchResources(
    session: NETunnelProviderSession, currentHash: Data
  ) async throws -> Data? {
    let message = ProviderMessage.getResourceList(currentHash)

    // Get data from the provider - if hash matches, provider returns nil
    return try await sendProviderMessage(session: session, message: message)
  }

  @MainActor
  static func setConfiguration(
    session: NETunnelProviderSession, _ configuration: TunnelConfiguration
  ) async throws {
    let message = ProviderMessage.setConfiguration(configuration)
    let _ = try await sendProviderMessage(session: session, message: message)
  }

  // MARK: - Low-level IPC operations

  @MainActor
  static func clearLogs(session: NETunnelProviderSession) async throws {
    let message = ProviderMessage.clearLogs
    let _ = try await sendProviderMessage(session: session, message: message)
  }

  @MainActor
  static func getLogFolderSize(session: NETunnelProviderSession) async throws -> Int64 {
    let message = ProviderMessage.getLogFolderSize
    guard let data = try await sendProviderMessage(session: session, message: message)
    else {
      throw Error.noIPCData
    }

    return data.withUnsafeBytes { rawBuffer in
      rawBuffer.load(as: Int64.self)
    }
  }

  @MainActor
  static func exportLogs(session: NETunnelProviderSession, fileHandle: FileHandle) async throws {
    let isCycleStart = try await maybeCycleStart(session)
    defer {
      if isCycleStart { session.stopTunnel() }
    }

    let message = ProviderMessage.exportLogs
    let encodedMessage = try encoder.encode(message)

    func loop() async throws {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Swift.Error>) in
        do {
          try session.sendProviderMessage(encodedMessage) { data in
            guard let data = data else {
              return continuation.resume(throwing: Error.noIPCData)
            }
            guard let chunk = try? decoder.decode(LogChunk.self, from: data) else {
              return continuation.resume(throwing: Error.decodeIPCDataFailed)
            }

            do {
              try fileHandle.seekToEnd()
              fileHandle.write(chunk.data)

              continuation.resume()

              if !chunk.done {
                Task { try await loop() }
              }
            } catch {
              return continuation.resume(throwing: error)
            }
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }

    // Start exporting
    try await loop()
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

  private static func sendProviderMessage(
    session: NETunnelProviderSession,
    message: ProviderMessage,
  ) async throws -> Data? {
    let isCycleStart = try await maybeCycleStart(session)

    defer {
      if isCycleStart { session.stopTunnel() }
    }

    return try await withCheckedThrowingContinuation { continuation in
      do {
        try session.sendProviderMessage(encoder.encode(message)) { data in
          continuation.resume(returning: data)
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  /// On macOS, the tunnel needs to be in a connected, connecting, or reasserting state for the utun to be removed
  /// upon stopTunnel. We do this by ensuring the tunnel is "started" prior to any IPC call. If so, we return true
  /// so that the caller may stop the tunnel afterwards.
  ///
  /// After system extension replacement, the session status may be .invalid. In this case, we attempt to wake
  /// the extension by calling startTunnel with cycleStart option, which will transition it to a usable state.
  private static func maybeCycleStart(_ session: NETunnelProviderSession) async throws -> Bool {
    #if os(macOS)
      // Try to wake extension if disconnected, disconnecting, or invalid (e.g., after system extension replacement)
      if [.disconnected, .disconnecting, .invalid].contains(session.status) {
        let options: [String: NSObject] = [
          "cycleStart": true as NSObject
        ]

        try session.startTunnel(options: options)

        // Give the system some time to start the tunnel (100ms)
        try await Task.sleep(nanoseconds: 100_000_000)

        return true
      }
    #endif

    return false
  }
}
