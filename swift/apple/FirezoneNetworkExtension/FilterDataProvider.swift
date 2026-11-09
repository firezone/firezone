//
//  FilterDataProvider.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKit
import Foundation
import Network
import NetworkExtension
import os

#if os(macOS)
  import Security
#endif

/// Keeps unlisted applications out of the tunnel, beside the packet tunnel provider.
///
/// Routing stays with the packet tunnel: this only answers whether the app behind a new
/// socket flow may talk to a destination the tunnel routes. The policy comes from the
/// file the packet tunnel keeps current in the app group container, so no decision ever
/// waits on the network.
class FilterDataProvider: NEFilterDataProvider {
  private let logger = Logger(subsystem: "dev.firezone.firezone", category: "app-filter")
  /// Replaced by the watcher's queue while flows are decided on the provider's, hence the lock.
  private let policy = OSAllocatedUnfairLock(initialState: AppFilterPolicy.off)
  private var policyWatcher: (any DispatchSourceFileSystemObject)?

  override func startFilter(completionHandler: @escaping ((any Error)?) -> Void) {
    reloadPolicy()
    watchPolicy()
    logger.info("Started app filter, enforcing=\(self.policy.withLock { $0.isEnforcing })")
    completionHandler(nil)
  }

  override func stopFilter(
    with reason: NEProviderStopReason, completionHandler: @escaping () -> Void
  ) {
    policyWatcher?.cancel()
    policyWatcher = nil
    completionHandler()
  }

  override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
    let policy = policy.withLock { $0 }
    guard policy.isEnforcing,
      let socketFlow = flow as? NEFilterSocketFlow,
      let destination = Self.destination(of: socketFlow)
    else {
      return .allow()
    }

    let app = Self.sourceApp(of: flow)
    switch policy.decide(app: app, destination: destination) {
    case .allow:
      return .allow()
    case .deny:
      logger.debug("Denied flow from \(app ?? "<unknown>", privacy: .public)")
      return .drop()
    }
  }

  // MARK: - Policy

  private func reloadPolicy() {
    let loaded = AppFilterPolicy.load() ?? .off
    policy.withLock { $0 = loaded }
  }

  /// Re-reads the policy whenever the packet tunnel rewrites it.
  private func watchPolicy() {
    guard let url = AppFilterPolicy.fileURL else { return }

    // Watching the directory survives the atomic replace of the file itself.
    let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
    guard fd >= 0 else { return }

    let watcher = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: .write, queue: .global())
    watcher.setEventHandler { [weak self] in self?.reloadPolicy() }
    watcher.setCancelHandler { close(fd) }
    watcher.resume()
    policyWatcher = watcher
  }

  // MARK: - Destination

  /// The remote IP literal of a socket flow, without any IPv6 zone.
  ///
  /// Older systems expose no structured endpoint, so their flows pass unfiltered.
  private static func destination(of flow: NEFilterSocketFlow) -> String? {
    guard #available(iOS 18, macOS 15, *),
      case .hostPort(let host, _) = flow.remoteFlowEndpoint
    else { return nil }

    switch host {
    case .ipv4(let address):
      return "\(address)"
    case .ipv6(let address):
      return "\(address)".split(separator: "%", maxSplits: 1).first.map(String.init)
    case .name(let name, _):
      return name
    @unknown default:
      return nil
    }
  }

  // MARK: - Identity

  /// The signing identifier of the app responsible for the flow, or `nil` when the platform has none.
  private static func sourceApp(of flow: NEFilterFlow) -> String? {
    #if os(macOS)
      guard let token = flow.sourceAppAuditToken else { return nil }

      var code: SecCode?
      let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
      guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
        let code
      else { return nil }

      var staticCode: SecStaticCode?
      guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
      else { return nil }

      var info: CFDictionary?
      guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
        let info = info as? [String: Any]
      else { return nil }

      return info[kSecCodeInfoIdentifier as String] as? String
    #else
      return flow.sourceAppIdentifier
    #endif
  }
}
