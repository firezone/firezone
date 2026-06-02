//
//  TunnelSessionProtocol.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

@preconcurrency import NetworkExtension

/// Abstracts the slice of `NETunnelProviderSession` that the GUI talks to, so a
/// mock session can drive `Store` without a real Network Extension.
///
/// The methods mirror Apple's API exactly, which lets `NETunnelProviderSession`
/// conform via an empty extension — there is no "real" wrapper to keep in sync.
public protocol TunnelSessionProtocol: AnyObject, Sendable {
  var status: NEVPNStatus { get }
  // swiftlint:disable:next discouraged_optional_collection
  func startTunnel(options: [String: Any]?) throws
  func stopTunnel()
  func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws
  func fetchLastDisconnectError(completionHandler: @escaping @Sendable (Error?) -> Void)
}

extension NETunnelProviderSession: TunnelSessionProtocol {}
