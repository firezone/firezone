//
//  IPCClient.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
@preconcurrency import NetworkExtension
import SystemPackage

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

  // Auto-connect: the GUI must save providerConfiguration before calling this so
  // any MDM forced overrides are available to the provider.
  @MainActor
  static func start(session: any TunnelSessionProtocol) throws {
    try session.startTunnel(options: nil)
  }

  // Sign in
  @MainActor
  static func start(session: any TunnelSessionProtocol, token: String) throws {
    try session.startTunnel(options: ["token": token as NSObject])
  }

  @MainActor
  static func signOut(session: any TunnelSessionProtocol) async throws {
    let message = ProviderMessage.signOut
    _ = try await sendProviderMessage(session: session, message: message)

    session.stopTunnel()
  }

  @MainActor
  static func fetchState(
    session: any TunnelSessionProtocol, currentHash: Data
  ) async throws -> Data? {
    let message = ProviderMessage.getState(currentHash)

    // Get data from the provider - if hash matches, provider returns nil
    return try await sendProviderMessage(session: session, message: message)
  }

  @MainActor
  static func setInternetResourceEnabled(
    session: any TunnelSessionProtocol,
    _ enabled: Bool
  ) async throws {
    let message = ProviderMessage.setInternetResourceEnabled(enabled)
    _ = try await sendProviderMessage(session: session, message: message)
  }

  // Asks the provider to drain the flow-log spool. Delivering the message
  // starts the provider if it isn't running (macOS cycle-starts it in
  // `sendProviderMessage`, iOS launches the appex to deliver the message).
  @MainActor
  static func drainFlowLogs(session: any TunnelSessionProtocol) async throws {
    let message = ProviderMessage.drainFlowLogs
    _ = try await sendProviderMessage(session: session, message: message)
  }

  // MARK: - Low-level IPC operations

  @MainActor
  static func clearLogs(session: any TunnelSessionProtocol) async throws {
    let message = ProviderMessage.clearLogs
    _ = try await sendProviderMessage(session: session, message: message)
  }

  @MainActor
  static func getLogFolderSize(session: any TunnelSessionProtocol) async throws -> Int64 {
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
  static func fetchEncodedFirezoneId(session: any TunnelSessionProtocol) async throws -> String? {
    guard let data = try await sendProviderMessage(session: session, message: .getEncodedFirezoneId)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @MainActor
  static func exportLogs(session: any TunnelSessionProtocol, fd: FileDescriptor) async throws {
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

  /// Returns a stream of VPN status updates for the given session.
  ///
  /// Filters `NEVPNStatusDidChange` notifications to only those matching `session`.
  /// The caller is responsible for consuming the stream in a task they manage.
  static func vpnStatusUpdates(
    session: any TunnelSessionProtocol
  ) -> AsyncStream<NEVPNStatus> {
    AsyncStream { continuation in
      let task = Task {
        for await notification in NotificationCenter.default.notifications(
          named: .NEVPNStatusDidChange)
        {
          guard let notificationSession = notification.object as? NETunnelProviderSession
          else {
            return
          }

          if notificationSession === session {
            continuation.yield(notificationSession.status)
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func sendProviderMessage(
    session: any TunnelSessionProtocol,
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
  private static func maybeCycleStart(_ session: any TunnelSessionProtocol) async throws -> Bool {
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
