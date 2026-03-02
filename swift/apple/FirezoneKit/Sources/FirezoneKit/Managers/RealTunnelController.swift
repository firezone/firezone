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
    try await requireManager().enable()
  }

  public func installConfiguration() async throws {
    self.vpnManager = try await VPNConfigurationManager()
  }

  // MARK: - IPC Operations

  public func fetchResources(currentHash: Data) async throws -> Data? {
    try await IPCClient.fetchState(session: requireSession(), currentHash: currentHash)
  }

  public func setConfiguration(_ config: TunnelConfiguration) async throws {
    try await IPCClient.setConfiguration(session: requireSession(), config)
  }

  public func start(configuration: TunnelConfiguration) throws {
    try IPCClient.start(session: requireSession(), configuration: configuration)
  }

  public func start(token: String, configuration: TunnelConfiguration) throws {
    try IPCClient.start(session: requireSession(), token: token, configuration: configuration)
  }

  public func signOut() async throws {
    try await IPCClient.signOut(session: requireSession())
  }

  public func clearLogs() async throws {
    try await IPCClient.clearLogs(session: requireSession())
  }

  public func fetchFirezoneId() async throws -> String? {
    try await IPCClient.fetchEncodedFirezoneId(session: requireSession())
  }

  #if os(macOS)
    public func getLogFolderSize() async throws -> Int64 {
      try await IPCClient.getLogFolderSize(session: requireSession())
    }

    public func exportLogs(fd: FileDescriptor) async throws {
      try await IPCClient.exportLogs(session: requireSession(), fd: fd)
    }

    public func fetchLastDisconnectError(handler: @escaping @Sendable (Error?) -> Void) {
      vpnManager?.session()?.fetchLastDisconnectError(completionHandler: handler)
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

  // MARK: - Private

  private func requireManager() throws -> VPNConfigurationManager {
    guard let vpnManager else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    return vpnManager
  }

  private func requireSession() throws -> NETunnelProviderSession {
    guard let session = try requireManager().session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    return session
  }
}
