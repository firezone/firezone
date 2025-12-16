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
  private var dnsAddresses: [String]?
  private var routes4: [NEIPv4Route]?
  private var routes6: [NEIPv6Route]?
  private var dnsResourceAddresses: [String]?
  private var matchDomains: [String]?
  private var searchDomains: [String]?

  // MARK: - Field-by-field comparison helpers

  private static func compareRoutes4(_ lhs: [NEIPv4Route]?, _ rhs: [NEIPv4Route]?) -> Bool {
    guard let lhs = lhs, let rhs = rhs else {
      return lhs == nil && rhs == nil
    }
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy {
      $0.destinationAddress == $1.destinationAddress
        && $0.destinationSubnetMask == $1.destinationSubnetMask
    }
  }

  private static func compareRoutes6(_ lhs: [NEIPv6Route]?, _ rhs: [NEIPv6Route]?) -> Bool {
    guard let lhs = lhs, let rhs = rhs else {
      return lhs == nil && rhs == nil
    }
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
    dnsAddresses: [String],
    searchDomain: String?,
    routes4: [NEIPv4Route],
    routes6: [NEIPv6Route]
  ) -> NEPacketTunnelNetworkSettings? {
    // Store old values for comparison
    let oldIPv4 = self.tunnelAddressIPv4
    let oldIPv6 = self.tunnelAddressIPv6
    let oldDnsAddresses = self.dnsAddresses
    let oldMatchDomains = self.matchDomains
    let oldSearchDomains = self.searchDomains
    let oldRoutes4 = self.routes4
    let oldRoutes6 = self.routes6

    // Update values
    self.tunnelAddressIPv4 = ipv4
    self.tunnelAddressIPv6 = ipv6
    let sortedDnsAddresses = dnsAddresses.sorted()
    self.dnsAddresses = sortedDnsAddresses

    // Set search domain
    let newMatchDomains: [String]
    let newSearchDomains: [String]
    if let searchDomain = searchDomain {
      newMatchDomains = ["", searchDomain]
      newSearchDomains = [searchDomain]
    } else {
      newMatchDomains = [""]
      newSearchDomains = [""]
    }
    self.matchDomains = newMatchDomains
    self.searchDomains = newSearchDomains

    // Sort routes for stable comparison
    let sortedRoutes4 = routes4.sorted {
      ($0.destinationAddress, $0.destinationSubnetMask) < (
        $1.destinationAddress, $1.destinationSubnetMask
      )
    }
    let sortedRoutes6 = routes6.sorted {
      ($0.destinationAddress, $0.destinationNetworkPrefixLength.intValue)
        < ($1.destinationAddress, $1.destinationNetworkPrefixLength.intValue)
    }
    self.routes4 = sortedRoutes4
    self.routes6 = sortedRoutes6

    // Check if anything actually changed
    let hasChanges =
      oldIPv4 != ipv4
      || oldIPv6 != ipv6
      || oldDnsAddresses != sortedDnsAddresses
      || oldMatchDomains != newMatchDomains
      || oldSearchDomains != newSearchDomains
      || !NetworkSettings.compareRoutes4(oldRoutes4, sortedRoutes4)
      || !NetworkSettings.compareRoutes6(oldRoutes6, sortedRoutes6)

    guard hasChanges else {
      return nil
    }

    return buildNetworkSettings()
  }

  /// Update DNS resource addresses
  /// Used to trigger network settings apply when DNS resources change,
  /// which flushes the DNS cache so new DNS resources are immediately resolvable
  /// Returns NEPacketTunnelNetworkSettings if settings changed, nil if unchanged or build fails
  public mutating func updateDnsResources(addresses: [String])
    -> NEPacketTunnelNetworkSettings?
  {
    // Store old value for comparison
    let oldDnsResourceAddresses = self.dnsResourceAddresses

    // Update value
    let newDnsResourceAddresses = addresses.sorted()
    self.dnsResourceAddresses = newDnsResourceAddresses

    // Check if anything actually changed
    guard oldDnsResourceAddresses != newDnsResourceAddresses else {
      return nil
    }

    return buildNetworkSettings()
  }

  public mutating func setDummyMatchDomain() -> NEPacketTunnelNetworkSettings? {
    self.matchDomains = ["firezone-fd0020211111"]
    return buildNetworkSettings()
  }

  public mutating func clearDummyMatchDomain() -> NEPacketTunnelNetworkSettings? {
    var newMatchDomains = [""]
    if let searchDomains = self.searchDomains {
      newMatchDomains.append(contentsOf: searchDomains)
    }
    self.matchDomains = newMatchDomains
    return buildNetworkSettings()
  }

  // MARK: - NEPacketTunnelNetworkSettings Builder

  /// Build NEPacketTunnelNetworkSettings from current state
  public func buildNetworkSettings() -> NEPacketTunnelNetworkSettings? {
    // Validate we have required fields
    guard let tunnelAddressIPv4 = tunnelAddressIPv4,
      let tunnelAddressIPv6 = tunnelAddressIPv6
    else {
      Log.warning("Cannot build network settings: missing tunnel addresses")
      return nil
    }

    // We don't really know the connlib gateway IP address at this point, but just using 127.0.0.1 is okay
    // because the OS doesn't really need this IP address.
    // NEPacketTunnelNetworkSettings taking in tunnelRemoteAddress is probably a bad abstraction caused by
    // NEPacketTunnelNetworkSettings inheriting from NETunnelNetworkSettings.
    let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

    // Set tunnel addresses and routes
    let ipv4Settings = NEIPv4Settings(
      addresses: [tunnelAddressIPv4], subnetMasks: ["255.255.255.255"])
    // This is a hack since macos routing table ignores, for full route, any prefix smaller than 120.
    // Without this, adding a full route, remove the previous default route and leaves the system with none,
    // completely breaking IPv6 on the user's system.
    let ipv6Settings = NEIPv6Settings(
      addresses: [tunnelAddressIPv6], networkPrefixLengths: [120])

    // Set routes if available
    if let routes4 = routes4 {
      ipv4Settings.includedRoutes = routes4
    }
    if let routes6 = routes6 {
      ipv6Settings.includedRoutes = routes6
    }

    tunnelNetworkSettings.ipv4Settings = ipv4Settings
    tunnelNetworkSettings.ipv6Settings = ipv6Settings

    // Set DNS settings if we have addresses
    if let dnsAddresses = dnsAddresses, !dnsAddresses.isEmpty {
      let dnsSettings = NEDNSSettings(servers: dnsAddresses)
      dnsSettings.matchDomains = matchDomains ?? [""]
      dnsSettings.searchDomains = searchDomains ?? [""]
      dnsSettings.matchDomainsNoSearch = false
      tunnelNetworkSettings.dnsSettings = dnsSettings
    }

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
