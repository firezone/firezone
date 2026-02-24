//
//  RealTunnelController.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import NetworkExtension
import SystemPackage

/// Production implementation of TunnelControllerProtocol.
///
/// Wraps VPNConfigurationManager for lifecycle operations and delegates
/// IPC operations to IPCClient static methods.
@MainActor
public final class RealTunnelController: TunnelControllerProtocol {
  private var vpnManager: VPNConfigurationManager?

  // Task consuming VPN status updates; its presence means observers are active.
  private var vpnStatusTask: CancellableTask?

  public init() {}

  // MARK: - State

  public var session: TunnelSessionProtocol? {
    vpnManager?.session()
  }

  public var isLoaded: Bool {
    vpnManager != nil
  }

  // MARK: - Lifecycle

  public func load() async throws -> Bool {
    if let manager = try await VPNConfigurationManager.load() {
      try await manager.maybeMigrateConfiguration()
      self.vpnManager = manager
      return true
    }
    return false
  }

  public func enable() async throws {
    guard let manager = vpnManager else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try await manager.enable()
  }

  public func installConfiguration() async throws {
    self.vpnManager = try await VPNConfigurationManager()
  }

  // MARK: - IPC Operations

  public func fetchResources(currentHash: Data) async throws -> Data? {
    guard let session = vpnManager?.session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    return try await IPCClient.fetchState(session: session, currentHash: currentHash)
  }

  public func setConfiguration(_ config: TunnelConfiguration) async throws {
    guard let session = vpnManager?.session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try await IPCClient.setConfiguration(session: session, config)
  }

  public func start(configuration: TunnelConfiguration) throws {
    guard let session = vpnManager?.session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try IPCClient.start(session: session, configuration: configuration)
  }

  public func start(token: String, configuration: TunnelConfiguration) throws {
    guard let session = vpnManager?.session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try IPCClient.start(session: session, token: token, configuration: configuration)
  }

  public func signOut() async throws {
    guard let session = vpnManager?.session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try await IPCClient.signOut(session: session)
  }

  public func clearLogs() async throws {
    guard let session = vpnManager?.session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try await IPCClient.clearLogs(session: session)
  }

  public func fetchFirezoneId() async throws -> String? {
    guard let session = vpnManager?.session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    return try await IPCClient.fetchEncodedFirezoneId(session: session)
  }

  #if os(macOS)
    public func getLogFolderSize() async throws -> Int64 {
      guard let session = vpnManager?.session() else {
        throw VPNConfigurationManagerError.managerNotInitialized
      }
      return try await IPCClient.getLogFolderSize(session: session)
    }

    public func exportLogs(fd: FileDescriptor) async throws {
      guard let session = vpnManager?.session() else {
        throw VPNConfigurationManagerError.managerNotInitialized
      }
      try await IPCClient.exportLogs(session: session, fd: fd)
    }

    public func fetchLastDisconnectError(handler: @escaping @Sendable (Error?) -> Void) {
      guard let session = vpnManager?.session() else { return }
      session.fetchLastDisconnectError(completionHandler: handler)
    }
  #endif

  // MARK: - Status

  public func stop() {
    session?.stopTunnel()
  }

  public func subscribeToStatusUpdates(
    handler: @escaping @Sendable (NEVPNStatus) async throws -> Void
  ) {
    guard vpnStatusTask == nil else {
      Log.debug("Status observers already active, skipping")
      return
    }
    guard let session = vpnManager?.session() else { return }
    let statusStream = IPCClient.vpnStatusUpdates(session: session)
    vpnStatusTask = CancellableTask {
      for await status in statusStream {
        do { try await handler(status) } catch {
          Log.error(error)
        }
      }
    }
  }
}
