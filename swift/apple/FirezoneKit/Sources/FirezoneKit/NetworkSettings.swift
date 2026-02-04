//
//  NetworkSettings.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0

import Foundation
import NetworkExtension
import os.log

public struct NetworkSettings: Equatable, Sendable {
  private var tunnelAddressIPv4: String?
  private var tunnelAddressIPv6: String?
  private var dnsServers: [String] = []
  private var routes4: [Cidr] = []
  private var routes6: [Cidr] = []
  private var dnsResources: [String] = []
  private var matchDomains: [String] = [""]
  private var searchDomain: String?

  public init() {}

  // MARK: - Payload

  /// A Sendable snapshot of network settings that can cross actor boundaries.
  ///
  /// This type exists to solve two conflicting requirements:
  /// 1. **Sendable safety**: We need to pass settings from the Adapter actor to PacketTunnelProvider
  ///    without using `@unchecked Sendable` on non-Sendable `NEPacketTunnelNetworkSettings`.
  /// 2. **Test invariant**: Settings should only be built when they actually change. Making
  ///    `buildNetworkSettings()` public would allow arbitrary calls, breaking this guarantee.
  ///
  /// The `fileprivate init` ensures only `NetworkSettings` update methods can create a `Payload`.
  /// Possession of a `Payload` proves you went through an update method that detected a change.
  /// The actual `NEPacketTunnelNetworkSettings` is built via `build()` on the receiving side.
  public struct Payload: Sendable {
    fileprivate let tunnelAddressIPv4: String
    fileprivate let tunnelAddressIPv6: String
    fileprivate let dnsServers: [String]
    fileprivate let routes4: [Cidr]
    fileprivate let routes6: [Cidr]
    fileprivate let matchDomains: [String]
    // All properties are fileprivate, so Swift synthesizes a fileprivate memberwise init.
    // This enforces that Payload can only be created within this file (via NetworkSettings methods).
    fileprivate let searchDomain: String?

    /// Build NEPacketTunnelNetworkSettings from this payload.
    public func build() -> NEPacketTunnelNetworkSettings {
      // Set tunnel addresses and routes
      let ipv4Settings = NEIPv4Settings(
        addresses: [tunnelAddressIPv4], subnetMasks: ["255.255.255.255"])
      let validRoutes4 = routes4.compactMap { $0.asNEIPv4Route }
      if validRoutes4.count != routes4.count {
        Log.warning("Dropped \(routes4.count - validRoutes4.count) invalid IPv4 routes")
      }
      ipv4Settings.includedRoutes = validRoutes4

      // This is a hack since macos routing table ignores, for full route, any prefix smaller than 120.
      // Without this, adding a full route, remove the previous default route and leaves the system with none,
      // completely breaking IPv6 on the user's system.
      let ipv6Settings = NEIPv6Settings(
        addresses: [tunnelAddressIPv6], networkPrefixLengths: [120])
      let validRoutes6 = routes6.compactMap { $0.asNEIPv6Route }
      if validRoutes6.count != routes6.count {
        Log.warning("Dropped \(routes6.count - validRoutes6.count) invalid IPv6 routes")
      }
      ipv6Settings.includedRoutes = validRoutes6

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

  // MARK: - Mutable update functions

  /// Update tunnel interface configuration
  /// Returns Payload if settings changed, nil if unchanged or missing required fields
  public mutating func updateTunInterface(
    ipv4: String?,
    ipv6: String?,
    dnsServers: [String],
    searchDomain: String?,
    routes4: [Cidr],
    routes6: [Cidr]
  ) -> Payload? {
    let oldSelf = self

    // Update values
    self.tunnelAddressIPv4 = ipv4
    self.tunnelAddressIPv6 = ipv6
    self.dnsServers = dnsServers
    self.searchDomain = searchDomain
    self.matchDomains = searchDomain.map { ["", $0] } ?? [""]
    self.routes4 = routes4.sorted { ($0.address, $0.prefix) < ($1.address, $1.prefix) }
    self.routes6 = routes6.sorted { ($0.address, $0.prefix) < ($1.address, $1.prefix) }

    // Check if anything actually changed
    if oldSelf == self {
      return nil
    }

    return makePayload()
  }

  /// Update DNS resource addresses
  /// Used to trigger network settings apply when DNS resources change,
  /// which flushes the DNS cache so new DNS resources are immediately resolvable
  /// Returns Payload if settings changed, nil if unchanged or missing required fields
  public mutating func updateDnsResources(newDnsResources: [String])
    -> Payload?
  {
    let oldSelf = self

    // Update values
    self.dnsResources = newDnsResources.sorted()

    // Check if anything actually changed
    if oldSelf == self {
      return nil
    }

    return makePayload()
  }

  // MARK: - Private Helpers

  /// Create a Payload from current state, if tunnel addresses are present.
  private func makePayload() -> Payload? {
    guard let tunnelAddressIPv4 = tunnelAddressIPv4,
      let tunnelAddressIPv6 = tunnelAddressIPv6
    else {
      Log.warning("Cannot build network settings: missing tunnel addresses")
      return nil
    }

    return Payload(
      tunnelAddressIPv4: tunnelAddressIPv4,
      tunnelAddressIPv6: tunnelAddressIPv6,
      dnsServers: dnsServers,
      routes4: routes4,
      routes6: routes6,
      matchDomains: matchDomains,
      searchDomain: searchDomain
    )
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
  public struct Cidr: Equatable, Sendable {
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
      // swiftlint:disable:next legacy_objc_type - NEIPv6Route API requires NSNumber
      return NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: prefix))
    }
  }
}
