//
//  RealVPNConfigurationProvider.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import NetworkExtension

/// Production implementation of VPNConfigurationProtocol.
///
/// Thin wrapper around VPNConfigurationManager. Intentionally minimal
/// so the untested delegation layer has almost no logic.
@MainActor
public final class RealVPNConfigurationProvider: VPNConfigurationProtocol {
  private var vpnManager: VPNConfigurationManager?

  public init() {}

  public func loadConfiguration() async throws -> Bool {
    if let manager = try await VPNConfigurationManager.load() {
      try await manager.maybeMigrateConfiguration()
      self.vpnManager = manager
      return true
    }
    return false
  }

  public func installConfiguration() async throws {
    self.vpnManager = try await VPNConfigurationManager()
  }

  public func enable() async throws {
    guard let vpnManager else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try await vpnManager.enable()
  }

  public func session() -> TunnelSessionProtocol? {
    vpnManager?.session()
  }
}
