//
//  TunnelControllerProtocol.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension

/// High-level tunnel control operations.
///
/// This protocol abstracts the VPN tunnel management operations that Store needs,
/// enabling dependency injection for testing without a real VPN configuration.
@MainActor
protocol TunnelControllerProtocol {
  var session: TunnelSessionProtocol? { get }

  func start() throws
  func stop()
  func subscribeToStatusUpdates(handler: @escaping (NEVPNStatus) async throws -> Void)
}
