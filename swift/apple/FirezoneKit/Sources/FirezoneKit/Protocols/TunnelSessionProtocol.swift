//
//  TunnelSessionProtocol.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
@preconcurrency import NetworkExtension

/// Abstracts the slice of `NETunnelProviderSession` that the GUI talks to, so a
/// mock session can drive `Store` without a real Network Extension.
///
/// The methods mirror Apple's API exactly, which lets `NETunnelProviderSession`
/// conform without a wrapper to keep in sync. The one addition is the status
/// stream, which Apple only offers as a notification.
public protocol TunnelSessionProtocol: AnyObject, Sendable {
  var status: NEVPNStatus { get }
  /// Every status the session takes on from now, in order.
  func statusUpdates() -> AsyncStream<NEVPNStatus>
  // swiftlint:disable:next discouraged_optional_collection
  func startTunnel(options: [String: Any]?) throws
  func stopTunnel()
  func sendProviderMessage(_ messageData: Data, responseHandler: ((Data?) -> Void)?) throws
  func fetchLastDisconnectError(completionHandler: @escaping @Sendable (Error?) -> Void)
}

extension NETunnelProviderSession: TunnelSessionProtocol {
  /// Every connection in the process posts `NEVPNStatusDidChange` with itself as the
  /// object; only this session's are passed on.
  public func statusUpdates() -> AsyncStream<NEVPNStatus> {
    AsyncStream { continuation in
      let task = Task {
        for await notification in NotificationCenter.default.notifications(
          named: .NEVPNStatusDidChange)
        {
          guard let sender = notification.object as? NETunnelProviderSession, sender === self
          else { continue }

          continuation.yield(self.status)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
