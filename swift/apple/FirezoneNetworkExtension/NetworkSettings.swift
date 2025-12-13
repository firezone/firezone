//
//  NetworkSettings.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0

import FirezoneKit
import Foundation
import NetworkExtension
import os.log

class NetworkSettings: Equatable {
  // WireGuard has an 80-byte overhead. We could try setting tunnelOverheadBytes
  // but that's not a reliable way to calculate how big our packets should be,
  // so just use the minimum.
  let mtu: NSNumber = 1280

  // These will only be initialized once and then don't change
  private weak var packetTunnelProvider: NEPacketTunnelProvider?

  // Modifiable values
  public var tunnelAddressIPv4: String?
  public var tunnelAddressIPv6: String?
  public var dnsAddresses: [String] = []
  public var routes4: [NEIPv4Route] = []
  public var routes6: [NEIPv6Route] = []

  // Private to ensure we append the search domain if we set it.
  private var matchDomains: [String] = [""]
  private var searchDomains: [String] = [""]

  init(packetTunnelProvider: PacketTunnelProvider?) {
    self.packetTunnelProvider = packetTunnelProvider
  }

  static func == (lhs: NetworkSettings, rhs: NetworkSettings) -> Bool {
    lhs.tunnelAddressIPv4 == rhs.tunnelAddressIPv4
      && lhs.tunnelAddressIPv6 == rhs.tunnelAddressIPv6
      && lhs.dnsAddresses == rhs.dnsAddresses
      && lhs.matchDomains == rhs.matchDomains
      && lhs.searchDomains == rhs.searchDomains
      && lhs.routes4.count == rhs.routes4.count
      && lhs.routes6.count == rhs.routes6.count
      && zip(lhs.routes4, rhs.routes4).allSatisfy {
        $0.destinationAddress == $1.destinationAddress
          && $0.destinationSubnetMask == $1.destinationSubnetMask
      }
      && zip(lhs.routes6, rhs.routes6).allSatisfy {
        $0.destinationAddress == $1.destinationAddress
          && $0.destinationNetworkPrefixLength == $1.destinationNetworkPrefixLength
      }
  }

  func setSearchDomain(domain: String?) {
    guard let domain = domain else {
      self.matchDomains = [""]
      self.searchDomains = [""]
      return
    }

    self.matchDomains = ["", domain]
    self.searchDomains = [domain]
  }

  func setDummyMatchDomain() {
    self.matchDomains = ["firezone-fd0020211111"]
  }

  func clearDummyMatchDomain() {
    self.matchDomains = [""]

    self.matchDomains.append(contentsOf: self.searchDomains)
  }

  func apply(completionHandler: (@Sendable () -> Void)? = nil) {
    // We don't really know the connlib gateway IP address at this point, but just using 127.0.0.1 is okay
    // because the OS doesn't really need this IP address.
    // NEPacketTunnelNetworkSettings taking in tunnelRemoteAddress is probably a bad abstraction caused by
    // NEPacketTunnelNetworkSettings inheriting from NETunnelNetworkSettings.
    let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

    // Set tunnel addresses and routes
    let ipv4Settings = NEIPv4Settings(
      addresses: [tunnelAddressIPv4!], subnetMasks: ["255.255.255.255"])
    // This is a hack since macos routing table ignores, for full route, any prefix smaller than 120.
    // Without this, adding a full route, remove the previous default route and leaves the system with none,
    // completely breaking IPv6 on the user's system.
    let ipv6Settings = NEIPv6Settings(addresses: [tunnelAddressIPv6!], networkPrefixLengths: [120])
    let dnsSettings = NEDNSSettings(servers: dnsAddresses)
    ipv4Settings.includedRoutes = routes4
    ipv6Settings.includedRoutes = routes6
    dnsSettings.matchDomains = matchDomains
    dnsSettings.searchDomains = searchDomains
    dnsSettings.matchDomainsNoSearch = false
    tunnelNetworkSettings.ipv4Settings = ipv4Settings
    tunnelNetworkSettings.ipv6Settings = ipv6Settings
    tunnelNetworkSettings.dnsSettings = dnsSettings
    tunnelNetworkSettings.mtu = mtu

    packetTunnelProvider?.setTunnelNetworkSettings(tunnelNetworkSettings) { error in
      if let error = error {
        Log.error(error)
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

// Route convenience helpers.
extension NetworkSettings {
  struct Cidr {
    let address: String
    let prefix: Int

    var asNEIPv4Route: NEIPv4Route? {
      guard let subnetMask = IPv4SubnetMaskLookup.table[prefix] else {
        Log.warning("Invalid IPv4 prefix: \(prefix) for address: \(address)")
        return nil
      }
      return NEIPv4Route(destinationAddress: address, subnetMask: subnetMask)
    }

    var asNEIPv6Route: NEIPv6Route? {
      guard prefix >= 0 && prefix <= 128 else {
        Log.warning("Invalid IPv6 prefix: \(prefix) for address: \(address)")
        return nil
      }
      return NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: prefix))
    }
  }
}
