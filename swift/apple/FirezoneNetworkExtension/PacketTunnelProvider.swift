//
//  PacketTunnelProvider.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import FirezoneKit
import NetworkExtension
import os

enum PacketTunnelProviderError: Error {
  case savedProtocolConfigurationIsInvalid(String)
  case tokenNotFoundInKeychain
  case couldNotSetNetworkSettings
}

class PacketTunnelProvider: NEPacketTunnelProvider {
  static let logger = Logger(subsystem: "dev.firezone.firezone", category: "packet-tunnel")

  private var adapter: Adapter?

  override func startTunnel(
    options _: [String: NSObject]? = nil,
    completionHandler: @escaping (Error?) -> Void
  ) {
    Self.logger.trace("\(#function)")

    guard let controlPlaneURLString = protocolConfiguration.serverAddress else {
      Self.logger.error("serverAddress is missing")
      completionHandler(
        PacketTunnelProviderError.savedProtocolConfigurationIsInvalid("serverAddress"))
      return
    }

    guard let tokenRef = protocolConfiguration.passwordReference else {
      Self.logger.error("passwordReference is missing")
      completionHandler(
        PacketTunnelProviderError.savedProtocolConfigurationIsInvalid("passwordReference"))
      return
    }

    Task {
      let keychain = Keychain()
      guard let token = await keychain.load(persistentRef: tokenRef) else {
        completionHandler(PacketTunnelProviderError.tokenNotFoundInKeychain)
        return
      }

      let adapter = Adapter(
        controlPlaneURLString: controlPlaneURLString, token: token, packetTunnelProvider: self)
      self.adapter = adapter
      do {
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
  }

  override func stopTunnel(with _: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    adapter?.stop {
      completionHandler()
      #if os(macOS)
        // HACK: This is a filthy hack to work around Apple bug 32073323
        exit(0)
      #endif
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    let query = String(data: messageData, encoding: .utf8) ?? ""
    adapter?.getDisplayableResourcesIfVersionDifferentFrom(referenceVersionString: query) {
      displayableResources in
      completionHandler?(displayableResources?.toData())
    }
  }
}
