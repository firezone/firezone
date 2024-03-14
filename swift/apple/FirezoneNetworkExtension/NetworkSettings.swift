//
//  NetworkSettings.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0

import FirezoneKit
import Foundation
import NetworkExtension
import os.log

class NetworkSettings {

  // Unchanging values
  let tunnelAddressIPv4: String
  let tunnelAddressIPv6: String
  let dnsAddresses: [String]

  // WireGuard has an 80-byte overhead. We could try setting tunnelOverheadBytes
  // but that's not a reliable way to calculate how big our packets should be,
  // so just use the minimum.
  let mtu: NSNumber = 1280

  public var routes4: [NEIPv4Route] = []
  public var routes6: [NEIPv6Route] = []

  // Modifiable values
  private(set) var resourceDomains: [String] = []
  private(set) var matchDomains: [String] = [""]

  // To keep track of modifications
  private(set) var hasUnappliedChanges: Bool

  init(
    tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddresses: [String]
  ) {
    self.tunnelAddressIPv4 = tunnelAddressIPv4
    self.tunnelAddressIPv6 = tunnelAddressIPv6
    self.dnsAddresses = dnsAddresses
    self.hasUnappliedChanges = true
  }

  func setResourceDomains(_ resourceDomains: [String]) {
    let sortedResourceDomains = resourceDomains.sorted()
    if self.resourceDomains != sortedResourceDomains {
      self.resourceDomains = sortedResourceDomains
    }
    self.hasUnappliedChanges = true
  }

  func setMatchDomains(_ matchDomains: [String]) {
    self.matchDomains = matchDomains
    self.hasUnappliedChanges = true
  }

  func apply(
    on packetTunnelProvider: NEPacketTunnelProvider?,
    logger: AppLogger,
    completionHandler: ((Error?) -> Void)?
  ) {
    guard let packetTunnelProvider = packetTunnelProvider else {
      logger.error("\(#function): packetTunnelProvider not initialized! This should not happen.")
      return
    }

    guard self.hasUnappliedChanges else {
      logger.error("NetworkSettings.apply: No changes to apply")
      completionHandler?(nil)
      return
    }

    logger.log("NetworkSettings.apply: Applying network settings")
    // We don't really know the connlib gateway IP address at this point, but just using 127.0.0.1 is okay
    // because the OS doesn't really need this IP address.
    // NEPacketTunnelNetworkSettings taking in tunnelRemoteAddress is probably a bad abstraction caused by
    // NEPacketTunnelNetworkSettings inheriting from NETunnelNetworkSettings.

    let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

    let ipv4Settings = NEIPv4Settings(
      addresses: [tunnelAddressIPv4], subnetMasks: ["255.255.255.255"])
      ipv4Settings.includedRoutes = self.routes4
    tunnelNetworkSettings.ipv4Settings = ipv4Settings

    let ipv6Settings = NEIPv6Settings(addresses: [tunnelAddressIPv6], networkPrefixLengths: [128])
      ipv6Settings.includedRoutes = self.routes6
    tunnelNetworkSettings.ipv6Settings = ipv6Settings

    let dnsSettings = NEDNSSettings(servers: dnsAddresses)
    // Intercept all DNS queries; SplitDNS will be handled by connlib
    dnsSettings.matchDomains = matchDomains
    dnsSettings.matchDomainsNoSearch = true
    tunnelNetworkSettings.dnsSettings = dnsSettings
    tunnelNetworkSettings.mtu = mtu

    self.hasUnappliedChanges = false
    logger.log("Attempting to set network settings")
    packetTunnelProvider.setTunnelNetworkSettings(tunnelNetworkSettings) { error in
      if let error = error {
        logger.error("NetworkSettings.apply: Error: \(error)")
      } else {
        guard !self.hasUnappliedChanges else {
          // Changes were made while the packetTunnelProvider was setting the network settings
          logger.log(
            """
            NetworkSettings.apply:
              Applying changes made to network settings while we were applying the network settings
            """)
          self.apply(on: packetTunnelProvider, logger: logger, completionHandler: completionHandler)
          return
        }
        logger.log("NetworkSettings.apply: Applied successfully")
      }
      completionHandler?(error)
    }
  }
}

// For creating IPv4 routes
enum IPv4SubnetMaskLookup {
  static let table: [Int: String] = [
    0: "0.0.0.0",
    1: "128.0.0.0",
    2: "192.0.0.0",
    3: "224.0.0.0",
    4: "240.0.0.0",
    5: "248.0.0.0",
    6: "252.0.0.0",
    7: "254.0.0.0",
    8: "255.0.0.0",
    9: "255.128.0.0",
    10: "255.192.0.0",
    11: "255.224.0.0",
    12: "255.240.0.0",
    13: "255.248.0.0",
    14: "255.252.0.0",
    15: "255.254.0.0",
    16: "255.255.0.0",
    17: "255.255.128.0",
    18: "255.255.192.0",
    19: "255.255.224.0",
    20: "255.255.240.0",
    21: "255.255.248.0",
    22: "255.255.252.0",
    23: "255.255.254.0",
    24: "255.255.255.0",
    25: "255.255.255.128",
    26: "255.255.255.192",
    27: "255.255.255.224",
    28: "255.255.255.240",
    29: "255.255.255.248",
    30: "255.255.255.252",
    31: "255.255.255.254",
    32: "255.255.255.255",
  ]
}


extension NetworkSettings {
  struct Cidr: Codable {
      let address: String
      let prefix: Int

      var asNEIPv4Route: NEIPv4Route {
          return NEIPv4Route(destinationAddress: address, subnetMask: String(prefix))
      }

      var asNEIPv6Route: NEIPv6Route {
          return NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: prefix))
      }
  }
}
