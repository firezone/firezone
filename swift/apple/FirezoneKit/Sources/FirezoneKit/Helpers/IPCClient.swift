//
//  IPCClient.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
@preconcurrency import NetworkExtension
import SystemPackage

@MainActor
public final class IPCClient {
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

  private let encoder = PropertyListEncoder()
  private let decoder = PropertyListDecoder()

  public init() {}

  // MARK: - Public API

  public func start(
    session: TunnelSessionProtocol, configuration: TunnelConfiguration
  ) throws {
    let configData = try encoder.encode(configuration)
    let options: [String: NSObject] = [
      "configuration": configData as NSObject
    ]
    try session.startTunnel(options: options)
  }

  public func start(
    session: TunnelSessionProtocol, token: String, configuration: TunnelConfiguration
  ) throws {
    let configData = try encoder.encode(configuration)
    let options: [String: NSObject] = [
      "token": token as NSObject,
      "configuration": configData as NSObject,
    ]
    try session.startTunnel(options: options)
  }

  public func signOut(session: TunnelSessionProtocol) async throws {
    let message = ProviderMessage.signOut
    _ = try await sendProviderMessage(session: session, message: message)
    session.stopTunnel()
  }

  public func fetchState(
    session: TunnelSessionProtocol, currentHash: Data
  ) async throws -> Data? {
    let message = ProviderMessage.getState(currentHash)
    return try await sendProviderMessage(session: session, message: message)
  }

  public func setConfiguration(
    session: TunnelSessionProtocol, _ configuration: TunnelConfiguration
  ) async throws {
    let message = ProviderMessage.setConfiguration(configuration)
    _ = try await sendProviderMessage(session: session, message: message)
  }

  public func clearLogs(session: TunnelSessionProtocol) async throws {
    let message = ProviderMessage.clearLogs
    _ = try await sendProviderMessage(session: session, message: message)
  }

  public func fetchEncodedFirezoneId(session: TunnelSessionProtocol) async throws -> String? {
    guard let data = try await sendProviderMessage(session: session, message: .getEncodedFirezoneId)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  #if os(macOS)
    public func getLogFolderSize(session: TunnelSessionProtocol) async throws -> Int64 {
      let message = ProviderMessage.getLogFolderSize
      guard let data = try await sendProviderMessage(session: session, message: message)
      else {
        throw Error.noIPCData
      }

      return data.withUnsafeBytes { rawBuffer in
        rawBuffer.load(as: Int64.self)
      }
    }

    public func exportLogs(session: TunnelSessionProtocol, fd: FileDescriptor) async throws {
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
              guard let chunk = try? self.decoder.decode(LogChunk.self, from: data) else {
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
  #endif

  // MARK: - Private

  private func sendProviderMessage(
    session: TunnelSessionProtocol,
    message: ProviderMessage
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
  private func maybeCycleStart(_ session: TunnelSessionProtocol) async throws -> Bool {
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

// MARK: - Legacy static method for VPNConfigurationManager migration

extension IPCClient {
  /// Static convenience for use during legacy configuration migration only.
  /// VPNConfigurationManager.maybeMigrateConfiguration() uses this because it operates
  /// on a concrete NETunnelProviderSession before Store/DI is available.
  @MainActor
  static func setConfigurationForMigration(
    session: NETunnelProviderSession, _ configuration: TunnelConfiguration
  ) async throws {
    try await IPCClient().setConfiguration(session: session, configuration)
  }
}
