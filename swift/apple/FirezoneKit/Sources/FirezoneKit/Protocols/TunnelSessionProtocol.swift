//
//  TunnelSessionProtocol.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension

/// Abstracts NETunnelProviderSession for testing.
public protocol TunnelSessionProtocol: AnyObject {
  var status: NEVPNStatus { get }
  var statusUpdates: AsyncStream<NEVPNStatus> { get }
  func stopTunnel()
  // swiftlint:disable:next discouraged_optional_collection - matches NETunnelProviderSession API
  func startTunnel(options: [String: Any]?) throws
  func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws

  #if os(macOS)
    /// Fetches the last disconnect error from the tunnel session.
    /// NETunnelProviderSession already provides this, so conformance is free.
    func fetchLastDisconnectError(completionHandler: @escaping @Sendable (Error?) -> Void)
  #endif
}

// Default conformance for real session
extension NETunnelProviderSession: TunnelSessionProtocol {
  public var statusUpdates: AsyncStream<NEVPNStatus> {
    // Capture ObjectIdentifier (Sendable) instead of self to satisfy Swift 6 concurrency.
    // The session from the notification is used directly for reading status.
    let identity = ObjectIdentifier(self)
    return AsyncStream { continuation in
      let task = Task {
        for await notification in NotificationCenter.default.notifications(
          named: .NEVPNStatusDidChange)
        {
          guard let session = notification.object as? NETunnelProviderSession,
            ObjectIdentifier(session) == identity
          else { continue }
          continuation.yield(session.status)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
