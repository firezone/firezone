//
//  RealTunnelController.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import NetworkExtension

/// Production implementation of TunnelControllerProtocol.
///
/// Wraps VPNConfigurationManager for lifecycle operations and delegates
/// IPC operations to IPCClient static methods.
@MainActor
public final class RealTunnelController: TunnelControllerProtocol {
  private var vpnManager: VPNConfigurationManager?

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
    return try await IPCClient.fetchResources(session: session, currentHash: currentHash)
  }

  public func setConfiguration(_ config: TunnelConfiguration) async throws {
    guard let session = vpnManager?.session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try await IPCClient.setConfiguration(session: session, config)
  }

  public func start() throws {
    guard let session = vpnManager?.session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try IPCClient.start(session: session)
  }

  public func start(token: String) throws {
    guard let session = vpnManager?.session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try IPCClient.start(session: session, token: token)
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

  // MARK: - Status

  public func stop() {
    session?.stopTunnel()
  }

  public func subscribeToStatusUpdates(
    handler: @escaping @Sendable (NEVPNStatus) async throws -> Void
  ) {
    guard let session = vpnManager?.session() else { return }
    IPCClient.subscribeToVPNStatusUpdates(session: session, handler: handler)
  }
}
