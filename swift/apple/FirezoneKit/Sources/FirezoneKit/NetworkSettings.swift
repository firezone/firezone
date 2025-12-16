//
//  NetworkSettings.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0

import Foundation
import NetworkExtension
import os.log

public struct NetworkSettings {
  private var tunnelAddressIPv4: String?
  private var tunnelAddressIPv6: String?
  private var dnsServers: [String] = []
  private var routes4: [NEIPv4Route] = []
  private var routes6: [NEIPv6Route] = []
  private var dnsResources: [String] = []
  private var matchDomains: [String] = [""]
  private var searchDomain: String?

  public init() {}

  // MARK: - Field-by-field comparison helpers

  private static func compareRoutes4(_ lhs: [NEIPv4Route], _ rhs: [NEIPv4Route]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy {
      $0.destinationAddress == $1.destinationAddress
        && $0.destinationSubnetMask == $1.destinationSubnetMask
    }
  }

  private static func compareRoutes6(_ lhs: [NEIPv6Route], _ rhs: [NEIPv6Route]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy {
      $0.destinationAddress == $1.destinationAddress
        && $0.destinationNetworkPrefixLength == $1.destinationNetworkPrefixLength
    }
  }

  // MARK: - Mutable update functions

  /// Update tunnel interface configuration
  /// Returns NEPacketTunnelNetworkSettings if settings changed, nil if unchanged or build fails
  public mutating func updateTunInterface(
    ipv4: String?,
    ipv6: String?,
    dnsServers: [String],
    searchDomain: String?,
    routes4: [NEIPv4Route],
    routes6: [NEIPv6Route]
  ) -> NEPacketTunnelNetworkSettings? {
    // Store old values for comparison
    let oldIPv4 = self.tunnelAddressIPv4
    let oldIPv6 = self.tunnelAddressIPv6
    let olddnsServers = self.dnsServers
    let oldMatchDomains = self.matchDomains
    let oldSearchDomain = self.searchDomain
    let oldRoutes4 = self.routes4
    let oldRoutes6 = self.routes6

    // Update values
    self.tunnelAddressIPv4 = ipv4
    self.tunnelAddressIPv6 = ipv6
    self.dnsServers = dnsServers
    self.searchDomain = searchDomain
    if let searchDomain = searchDomain {
      self.matchDomains = ["", searchDomain]
    } else {
      self.matchDomains = [""]
    }
    self.routes4 = routes4.sorted {
      ($0.destinationAddress, $0.destinationSubnetMask) < (
        $1.destinationAddress, $1.destinationSubnetMask
      )
    }
    self.routes6 = routes6.sorted {
      ($0.destinationAddress, $0.destinationNetworkPrefixLength.intValue)
        < ($1.destinationAddress, $1.destinationNetworkPrefixLength.intValue)
    }

    // Check if anything actually changed
    let hasChanges =
      oldIPv4 != self.tunnelAddressIPv4
      || oldIPv6 != self.tunnelAddressIPv6
      || olddnsServers != self.dnsServers
      || oldMatchDomains != self.matchDomains
      || oldSearchDomain != self.searchDomain
      || !NetworkSettings.compareRoutes4(oldRoutes4, self.routes4)
      || !NetworkSettings.compareRoutes6(oldRoutes6, self.routes6)

    if !hasChanges {
      return nil
    }

    return buildNetworkSettings()
  }

  /// Update DNS resource addresses
  /// Used to trigger network settings apply when DNS resources change,
  /// which flushes the DNS cache so new DNS resources are immediately resolvable
  /// Returns NEPacketTunnelNetworkSettings if settings changed, nil if unchanged or build fails
  public mutating func updateDnsResources(newDnsResources: [String])
    -> NEPacketTunnelNetworkSettings?
  {
    let oldDnsResources = self.dnsResources
    self.dnsResources = newDnsResources.sorted()

    let hasChanges = oldDnsResources != self.dnsResources

    if !hasChanges {
      return nil
    }

    return buildNetworkSettings()
  }

  public mutating func setDummyMatchDomain() -> NEPacketTunnelNetworkSettings? {
    self.matchDomains = ["firezone-fd0020211111"]
    return buildNetworkSettings()
  }

  public mutating func clearDummyMatchDomain() -> NEPacketTunnelNetworkSettings? {
    if let searchDomain = self.searchDomain {
      self.matchDomains = ["", searchDomain]
    } else {
      self.matchDomains = [""]
    }
    return buildNetworkSettings()
  }

  // MARK: - NEPacketTunnelNetworkSettings Builder

  /// Build NEPacketTunnelNetworkSettings from current state
  private func buildNetworkSettings() -> NEPacketTunnelNetworkSettings? {
    // Validate we have required fields
    guard let tunnelAddressIPv4 = tunnelAddressIPv4,
      let tunnelAddressIPv6 = tunnelAddressIPv6
    else {
      Log.warning("Cannot build network settings: missing tunnel addresses")
      return nil
    }

    // Set tunnel addresses and routes
    let ipv4Settings = NEIPv4Settings(
      addresses: [tunnelAddressIPv4], subnetMasks: ["255.255.255.255"])
    ipv4Settings.includedRoutes = routes4

    // This is a hack since macos routing table ignores, for full route, any prefix smaller than 120.
    // Without this, adding a full route, remove the previous default route and leaves the system with none,
    // completely breaking IPv6 on the user's system.
    let ipv6Settings = NEIPv6Settings(
      addresses: [tunnelAddressIPv6], networkPrefixLengths: [120])
    ipv6Settings.includedRoutes = routes6

    let dnsSettings = NEDNSSettings(servers: dnsServers)
    dnsSettings.matchDomains = matchDomains
    dnsSettings.searchDomains = searchDomain.map { [$0] } ?? [""]
    dnsSettings.matchDomainsNoSearch = false

    // We don't really know the connlib gateway IP address at this point, but just using 127.0.0.1 is okay
    // because the OS doesn't really need this IP address.
    // NEPacketTunnelNetworkSettings taking in tunnelRemoteAddress is probably a bad abstraction caused by
    // NEPacketTunnelNetworkSettings inheriting from NETunnelNetworkSettings.
    let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

    tunnelNetworkSettings.ipv4Settings = ipv4Settings
    tunnelNetworkSettings.ipv6Settings = ipv6Settings
    tunnelNetworkSettings.dnsSettings = dnsSettings
    tunnelNetworkSettings.mtu = 1280

    return tunnelNetworkSettings
  }
}

// MARK: - IPv4 Subnet Mask Lookup

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

// MARK: - Route Convenience Helpers

extension NetworkSettings {
  public struct Cidr {
    public let address: String
    public let prefix: Int

    public init(address: String, prefix: Int) {
      self.address = address
      self.prefix = prefix
    }

    public var asNEIPv4Route: NEIPv4Route? {
      guard let subnetMask = IPv4SubnetMaskLookup.table[prefix] else {
        Log.warning("Invalid IPv4 prefix: \(prefix) for address: \(address)")
        return nil
      }
      return NEIPv4Route(destinationAddress: address, subnetMask: subnetMask)
    }

    public var asNEIPv6Route: NEIPv6Route? {
      guard prefix >= 0 && prefix <= 128 else {
        Log.warning("Invalid IPv6 prefix: \(prefix) for address: \(address)")
        return nil
      }
      return NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: prefix))
    }
  }
}
