//
//  PacketTunnelProvider.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import NetworkExtension
import os

enum PacketTunnelProviderError: String, Error {
  case savedProtocolConfigurationIsInvalid
  case couldNotSetNetworkSettings
}

class PacketTunnelProvider: NEPacketTunnelProvider {
  static let logger = Logger(subsystem: "dev.firezone.firezone", category: "packet-tunnel")

  private lazy var adapter = Adapter(with: self)

  override func startTunnel(
    options _: [String: NSObject]? = nil,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol else {
      completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
      return
    }

    let providerConfiguration = tunnelProviderProtocol.providerConfiguration
    guard let portalURL = providerConfiguration?["portalURL"] as? String else {
      completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
      return
    }
    guard let token = providerConfiguration?["token"] as? String else {
      completionHandler(PacketTunnelProviderError.savedProtocolConfigurationIsInvalid)
      return
    }

    Self.logger.log("portalURL = \(portalURL, privacy: .public)")
    Self.logger.log("token = \(token, privacy: .public)")

    do {
      // Once connlib is updated to take in portalURL and token, this call
      // should become adapter.start(portalURL: portalURL, token: token)
      try adapter.start { error in
        if let error {
          Self.logger.error("Error in adapter.start: \(error)")
        }
        completionHandler(error)
      }
    } catch {
      completionHandler(error)
    }
  }

  override func stopTunnel(with _: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    adapter.stop { error in
      if let error {
        Self.logger.error("Error in adapter.stop: \(error)")
      }
      completionHandler()
    }

    #if os(macOS)
      // HACK: This is a filthy hack to work around Apple bug 32073323 (dup'd by us as 47526107).
      // Remove it when they finally fix this upstream and the fix has been rolled out to
      // sufficient quantities of users.
      exit(0)
    #endif
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    let query = String(data: messageData, encoding: .utf8) ?? ""
    adapter.getDisplayableResourcesIfVersionDifferentFrom(referenceVersionString: query) { displayableResources in
      completionHandler?(displayableResources?.toData())
    }
  }
}
