//
//  IPCClient.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
@preconcurrency import NetworkExtension
import SystemPackage

// TODO: Use a more abstract IPC protocol to make this less terse

public enum IPCClient {
  public enum Error: Swift.Error {
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
  public static func start(
    session: NETunnelProviderSession, configuration: TunnelConfiguration
  ) throws {
    let configData = try encoder.encode(configuration)
    let options: [String: NSObject] = [
      "configuration": configData as NSObject
    ]
    try session.startTunnel(options: options)
  }

  // Sign in
  @MainActor
  public static func start(
    session: NETunnelProviderSession, token: String, configuration: TunnelConfiguration
  ) throws {
    let configData = try encoder.encode(configuration)
    let options: [String: NSObject] = [
      "token": token as NSObject,
      "configuration": configData as NSObject,
    ]

    try session.startTunnel(options: options)
  }

  @MainActor
  static func signOut(session: NETunnelProviderSession) async throws {
    let message = ProviderMessage.signOut
    _ = try await sendProviderMessage(session: session, message: message)

    session.stopTunnel()
  }

  @MainActor
  static func fetchState(
    session: NETunnelProviderSession, currentHash: Data
  ) async throws -> Data? {
    let message = ProviderMessage.getState(currentHash)

    // Get data from the provider - if hash matches, provider returns nil
    return try await sendProviderMessage(session: session, message: message)
  }

  @MainActor
  static func setConfiguration(
    session: NETunnelProviderSession, _ configuration: TunnelConfiguration
  ) async throws {
    let message = ProviderMessage.setConfiguration(configuration)
    _ = try await sendProviderMessage(session: session, message: message)
  }

  // MARK: - Low-level IPC operations

  @MainActor
  static func clearLogs(session: NETunnelProviderSession) async throws {
    let message = ProviderMessage.clearLogs
    _ = try await sendProviderMessage(session: session, message: message)
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
  static func exportLogs(session: NETunnelProviderSession, fd: FileDescriptor) async throws {
    let isCycleStart = try await maybeCycleStart(session)
    defer {
      if isCycleStart { session.stopTunnel() }
    }

    let message = ProviderMessage.exportLogs
    let encodedMessage = try encoder.encode(message)

    func nextChunk() async throws -> LogChunk {
      try await withCheckedThrowingContinuation { continuation in
        do {
          try session.sendProviderMessage(encodedMessage) { data in
            guard let data else {
              return continuation.resume(throwing: Error.noIPCData)
            }
            guard let chunk = try? decoder.decode(LogChunk.self, from: data) else {
              return continuation.resume(throwing: Error.decodeIPCDataFailed)
            }
            continuation.resume(returning: chunk)
          }
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }

    while true {
      let chunk = try await nextChunk()

      try fd.writeAll(chunk.data)

      if chunk.done { break }
    }
  }

  // Subscribe to system notifications about our VPN status changing
  // and let our handler know about them.
  public static func subscribeToVPNStatusUpdates(
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
  private static func maybeCycleStart(_ session: NETunnelProviderSession) async throws -> Bool {
    if session.status == .invalid {
      throw Error.invalidStatus(session.status)
    }

    #if os(macOS)
      if [.disconnected, .disconnecting].contains(session.status) {
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
