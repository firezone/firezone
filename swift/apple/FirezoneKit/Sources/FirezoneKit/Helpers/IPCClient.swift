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

  private static let runningStatuses: [NEVPNStatus] = [.connected, .connecting, .reasserting]
  private static let settlingStatuses: [NEVPNStatus] = runningStatuses + [.disconnecting]
  private static let stopTimeout: Duration = .seconds(5)
  private static let stopPollInterval: Duration = .milliseconds(100)

  // The GUI must save providerConfiguration before calling this so any MDM forced
  // overrides are available to the provider.
  // A `nil` token asks the provider to load the saved token. The identity reference
  // pins the optional device certificate the app displayed.
  @MainActor
  public static func start(
    session: any TunnelSessionProtocol,
    token: String?,
    identityReference: Data?
  ) throws {
    var options: [String: NSObject] = ["authentication": "tokenAndCertificate" as NSObject]

    if let token {
      options["token"] = token as NSObject
    }
    if let identityReference {
      options["identityReference"] = identityReference as NSObject
    }

    try session.startTunnel(options: options)
  }

  /// A start that states no intent, as the system's own starts do: the provider derives the
  /// credentials from the keychain and the profile.
  @MainActor
  public static func start(session: any TunnelSessionProtocol) throws {
    try session.startTunnel(options: nil)
  }

  /// Stops the tunnel if it is running, and waits for the provider to go away.
  ///
  /// `stopTunnel` only asks. The provider is still up for a moment afterwards, so callers
  /// that need it gone rather than going have to wait for the status to follow. Reports
  /// whether there was a running tunnel, so the caller can put back what it took down.
  @MainActor
  static func stopIfRunning(session: any TunnelSessionProtocol) async -> Bool {
    let wasRunning = runningStatuses.contains(session.status)

    if wasRunning {
      session.stopTunnel()
    }

    var waited: Duration = .zero
    while !Task.isCancelled, settlingStatuses.contains(session.status), waited < stopTimeout {
      try? await Task.sleep(for: stopPollInterval)
      waited += stopPollInterval
    }

    return wasRunning
  }

  @MainActor
  public static func signOut(session: any TunnelSessionProtocol) async throws {
    let message = ProviderMessage.signOut
    _ = try await sendProviderMessage(session: session, message: message)

    session.stopTunnel()
  }

  @MainActor
  static func pollUpdates(
    session: any TunnelSessionProtocol, currentHash: Data
  ) async throws -> StatePollResponse {
    let message = ProviderMessage.pollUpdates(StatePollRequest(stateHash: currentHash))

    guard
      let data = try await sendProviderMessage(
        session: session,
        message: message,
        cycleStartIfStopped: false
      )
    else {
      throw Error.noIPCData
    }

    guard let response = try? decoder.decode(StatePollResponse.self, from: data) else {
      throw Error.decodeIPCDataFailed
    }

    return response
  }

  @MainActor
  static func setInternetResourceEnabled(
    session: any TunnelSessionProtocol,
    _ enabled: Bool
  ) async throws {
    let message = ProviderMessage.setInternetResourceEnabled(enabled)
    _ = try await sendProviderMessage(session: session, message: message)
  }

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

  /// Sends `message` to the provider, waking a stopped tunnel first if asked to.
  ///
  /// Polling opts out: cycle-starting from the poll loop would wake the extension
  /// without a tunnel behind it, and the stop that follows churns the VPN status,
  /// which starts the loop over again.
  private static func sendProviderMessage(
    session: any TunnelSessionProtocol,
    message: ProviderMessage,
    cycleStartIfStopped: Bool = true
  ) async throws -> Data? {
    let isCycleStart = cycleStartIfStopped ? try await maybeCycleStart(session) : false

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
