//
//  PacketTunnelProvider.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import connlib
import Dependencies
import FirezoneKit
import NetworkExtension
import os

enum PacketTunnelProviderError: String, Error {
  case savedProtocolConfigurationIsInvalid
  case couldNotSetNetworkSettings
}

class PacketTunnelProvider: NEPacketTunnelProvider {
  let logger = Logger(subsystem: "dev.firezone.firezone", category: "packet-tunnel")

  // Till connlib is updated to expose the desired FFI, we'll use a mock
  private lazy var adapter = ConnlibMock.Adapter(with: self)
  private var displayableResources = DisplayableResources()

  private var startTunnelCompletionHandler: ((Error?) -> Void)?

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

    self.logger.log("portalURL = \(portalURL, privacy: .public)")
    self.logger.log("token = \(token, privacy: .public)")

    adapter.delegate = self

    adapter.start(portalURL: portalURL, token: token)
    startTunnelCompletionHandler = completionHandler
  }

  override func stopTunnel(with _: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    adapter.stop()

    #if os(macOS)
      // HACK: This is a filthy hack to work around Apple bug 32073323 (dup'd by us as 47526107).
      // Remove it when they finally fix this upstream and the fix has been rolled out to
      // sufficient quantities of users.
      exit(0)
    #endif
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    let query = String(data: messageData, encoding: .utf8)
    if query == displayableResources.versionString {
      // No updates since last query
      completionHandler?(nil)
    } else {
      // Return new version of resources
      completionHandler?(displayableResources.toData())
    }
  }
}

extension PacketTunnelProvider: ConnlibMockAdapterDelegate {
  func onConnected(interfaceAddresses: ConnlibMock.InterfaceAddresses) {
    self.logger.log("onConnected: \(interfaceAddresses.ipv4, privacy: .public), \(interfaceAddresses.ipv6, privacy: .public)")

    // The tunnel remote address of 127.0.0.1 is really just a placeholder
    // because we don't know the tunnel remote address at this point, and in
    // any case, there might be none or one or many, and it can keep changing.
    let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let dnsSettings = NEDNSSettings(servers: ["100.100.111.1"])
    dnsSettings.matchDomains = [""]

    let ipv4Settings = NEIPv4Settings(addresses: [interfaceAddresses.ipv4], subnetMasks: ["255.255.255.255"])
    let ipv6Settings = NEIPv6Settings(addresses: [interfaceAddresses.ipv6], networkPrefixLengths: [128])
    // No routes included as of now

    networkSettings.ipv4Settings = ipv4Settings
    networkSettings.ipv6Settings = ipv6Settings
    networkSettings.dnsSettings = dnsSettings

    setTunnelNetworkSettings(networkSettings) { [weak self] error in
      if let error = error {
        self?.logger.log("Error (setTunnelNetworkSettings): \(error)")
      }
      if let startTunnelCompletionHandler = self?.startTunnelCompletionHandler {
        self?.logger.log("setTunnelNetworkSettings succeeded")
        startTunnelCompletionHandler(error)
        self?.startTunnelCompletionHandler = nil
      }
    }
  }

  func onUpdateResources(resources: [ConnlibMock.Resource]) {
    self.displayableResources.update(connlibResources: resources)
  }

  func onDisconnect() {
    self.logger.log("onDisconnect")
  }
}

extension DisplayableResources {
  func update(connlibResources resourceList: [ConnlibMock.Resource]) {
    let resources: [(name: String, location: String)] = resourceList.map {
      switch $0.resourceLocation {
        case .dns(domain: let domain, ipv4: _, ipv6: _):
          return (name: $0.name, location: domain)
        case .cidr(addressRange: let addressRange):
          return (name: $0.name, location: addressRange)
      }
    }
    update(resources: resources)
  }
}
