//
//  TunnelControllerProtocol.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import NetworkExtension

/// Unified tunnel control and IPC protocol.
///
/// This protocol abstracts all VPN tunnel management and IPC operations that Store needs,
/// enabling dependency injection for testing without a real VPN configuration.
/// Production uses `RealTunnelController`, tests use `MockTunnelController`.
@MainActor
public protocol TunnelControllerProtocol {
  // MARK: - State

  var session: TunnelSessionProtocol? { get }
  var isLoaded: Bool { get }

  // MARK: - Lifecycle

  /// Loads an existing VPN configuration if available.
  /// - Returns: `true` if a configuration was loaded, `false` if none exists.
  func load() async throws -> Bool

  /// Enables the VPN configuration.
  func enable() async throws

  /// Creates and installs a new VPN configuration.
  func installConfiguration() async throws

  // MARK: - IPC Operations

  /// Fetches resources from the tunnel provider.
  /// - Parameter currentHash: Hash of the current resource list for optimization.
  /// - Returns: Resource data if changed, `nil` if unchanged.
  /// - Throws: Error if tunnel communication fails.
  func fetchResources(currentHash: Data) async throws -> Data?

  /// Sends configuration to the tunnel provider.
  func setConfiguration(_ config: TunnelConfiguration) async throws

  /// Starts the tunnel without authentication.
  func start() throws

  /// Starts the tunnel with an authentication token.
  func start(token: String) throws

  /// Signs out and disconnects the tunnel.
  func signOut() async throws

  /// Clears tunnel logs.
  func clearLogs() async throws

  // MARK: - Status

  /// Stops the tunnel.
  func stop()

  /// Subscribes to VPN status updates.
  func subscribeToStatusUpdates(handler: @escaping @Sendable (NEVPNStatus) async throws -> Void)
}
