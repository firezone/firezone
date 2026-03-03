//
//  VPNConfigurationProtocol.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import NetworkExtension

/// Abstracts VPN configuration lifecycle for dependency injection.
///
/// Models the system API surface (NETunnelProviderManager) closely,
/// keeping the delegating implementation thin and trivially correct.
/// Production uses `RealVPNConfigurationProvider`, tests use `MockVPNConfigProvider`.
@MainActor
public protocol VPNConfigurationProtocol {
  /// Loads an existing VPN configuration if available.
  /// - Returns: `true` if a configuration was loaded, `false` if none exists.
  func loadConfiguration() async throws -> Bool

  /// Creates and installs a new VPN configuration.
  func installConfiguration() async throws

  /// Enables the VPN configuration (re-activates if another VPN was selected).
  func enable() async throws

  /// Returns the current tunnel session, or `nil` if no configuration is loaded.
  func session() -> TunnelSessionProtocol?
}
