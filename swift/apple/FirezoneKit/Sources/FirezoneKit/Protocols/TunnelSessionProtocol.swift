//
//  TunnelSessionProtocol.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension

/// Abstracts NETunnelProviderSession for testing.
///
/// This protocol enables dependency injection in Store, allowing tests to
/// simulate VPN status changes without requiring a real Network Extension.
protocol TunnelSessionProtocol: AnyObject {
  var status: NEVPNStatus { get }
  func stopTunnel()
}

// Default conformance for real session
extension NETunnelProviderSession: TunnelSessionProtocol {}
