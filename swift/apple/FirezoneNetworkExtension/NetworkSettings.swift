//
//  NetworkSettings.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0

import FirezoneKit
import Foundation
import NetworkExtension
import os.log

class NetworkSettings {
  // WireGuard has an 80-byte overhead. We could try setting tunnelOverheadBytes
  // but that's not a reliable way to calculate how big our packets should be,
  // so just use the minimum.
  let mtu: NSNumber = 1280

  // Constants
  private weak var packetTunnelProvider: NEPacketTunnelProvider?
  private(set) var logger: AppLogger

  // Modifiable values
  public var tunnelAddressIPv4: String?
  public var tunnelAddressIPv6: String?
  public var dnsAddresses: [String] = []
  public var routes4: [NEIPv4Route] = []
  public var routes6: [NEIPv6Route] = []
  public var matchDomains: [String] = [""]

  init(packetTunnelProvider: PacketTunnelProvider?, logger: AppLogger) {
    self.packetTunnelProvider = packetTunnelProvider
    self.logger = logger
  }

  func apply(beforeHandler: (() -> Void)?, completionHandler: (() -> Void)?) {
    // We don't really know the connlib gateway IP address at this point, but just using 127.0.0.1 is okay
    // because the OS doesn't really need this IP address.
    // NEPacketTunnelNetworkSettings taking in tunnelRemoteAddress is probably a bad abstraction caused by
    // NEPacketTunnelNetworkSettings inheriting from NETunnelNetworkSettings.
    let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

    // Set tunnel addresses and routes
    let ipv4Settings = NEIPv4Settings(
      addresses: [tunnelAddressIPv4!],subnetMasks: ["255.255.255.255"])
    let ipv6Settings = NEIPv6Settings(addresses: [tunnelAddressIPv6!], networkPrefixLengths: [128])
    let dnsSettings = NEDNSSettings(servers: dnsAddresses)
    ipv4Settings.includedRoutes = routes4
    ipv6Settings.includedRoutes = routes6
    dnsSettings.matchDomains = matchDomains
    dnsSettings.matchDomainsNoSearch = true
    tunnelNetworkSettings.ipv4Settings = ipv4Settings
    tunnelNetworkSettings.ipv6Settings = ipv6Settings
    tunnelNetworkSettings.dnsSettings = dnsSettings
    tunnelNetworkSettings.mtu = mtu

    // For disabling path monitoring while apply network settings
    beforeHandler?()

    packetTunnelProvider!.setTunnelNetworkSettings(tunnelNetworkSettings) { error in
      if let error = error {
        self.logger.error("\(#function): Error occurred while applying network settings! Error: \(error.localizedDescription)")
      }

      completionHandler?()
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

// Route convenience helpers. Data is from connlib and guaranteed to be valid.
// Otherwise, we should crash and learn about it.
extension NetworkSettings {
  static func parseRoutes4(routes4: [String]) -> [NEIPv4Route] {
    return routes4.map { route4 in
      let components = route4.split(separator: "/")
      let address = String(components[0])
      let prefix: Int = Int(components[1])!
      let mask = IPv4SubnetMaskLookup.table[prefix]!
      return NEIPv4Route(destinationAddress: address, subnetMask: mask)
    }
  }

  static func parseRoutes6(routes6: [String]) -> [NEIPv6Route] {
    routes6.map { route6 in
      let components = route6.split(separator: "/")
      let address = String(components[0])
      let prefix: NSNumber = NSNumber(value: Int(components.last!)!)
      return NEIPv6Route(destinationAddress: address, networkPrefixLength: prefix)
    }
  }
}
