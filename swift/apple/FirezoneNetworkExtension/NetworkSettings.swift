import Foundation
import NetworkExtension

/// Sendable network settings data.
///
/// This struct holds the data needed to configure tunnel network settings.
/// The actual NEPacketTunnelNetworkSettings construction happens in PacketTunnelProvider.
struct NetworkSettings: Sendable {
  let tunnelAddressIPv4: String
  let tunnelAddressIPv6: String
  let dnsAddresses: [String]
  let routes4: [Cidr]
  let routes6: [Cidr]
  let matchDomains: [String]
  let searchDomains: [String]
  let mtu: Int

  struct Cidr: Sendable {
    let address: String
    let prefix: Int
  }

  /// Create network settings from tunnel interface update event.
  static func from(
    ipv4: String,
    ipv6: String,
    dns: [String],
    searchDomain: String?,
    routes4: [Cidr],
    routes6: [Cidr]
  ) -> NetworkSettings {
    NetworkSettings(
      tunnelAddressIPv4: ipv4,
      tunnelAddressIPv6: ipv6,
      dnsAddresses: dns,
      routes4: routes4,
      routes6: routes6,
      matchDomains: searchDomain.map { ["", $0] } ?? [""],
      searchDomains: searchDomain.map { [$0] } ?? [],
      mtu: 1280
    )
  }

  /// Create a copy with dummy match domain (for iOS DNS resolver workaround).
  func withDummyMatchDomain() -> NetworkSettings {
    NetworkSettings(
      tunnelAddressIPv4: tunnelAddressIPv4,
      tunnelAddressIPv6: tunnelAddressIPv6,
      dnsAddresses: dnsAddresses,
      routes4: routes4,
      routes6: routes6,
      matchDomains: ["firezone-fd0020211111"],
      searchDomains: searchDomains,
      mtu: mtu
    )
  }

  /// Build NEPacketTunnelNetworkSettings from this data.
  func buildNESettings() -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

    let ipv4Settings = NEIPv4Settings(
      addresses: [tunnelAddressIPv4],
      subnetMasks: ["255.255.255.255"]
    )
    let ipv6Settings = NEIPv6Settings(
      addresses: [tunnelAddressIPv6],
      networkPrefixLengths: [120]
    )
    let dnsSettings = NEDNSSettings(servers: dnsAddresses)

    ipv4Settings.includedRoutes = routes4.compactMap { $0.asNEIPv4Route }
    ipv6Settings.includedRoutes = routes6.compactMap { $0.asNEIPv6Route }
    dnsSettings.matchDomains = matchDomains
    dnsSettings.searchDomains = searchDomains
    dnsSettings.matchDomainsNoSearch = false

    settings.ipv4Settings = ipv4Settings
    settings.ipv6Settings = ipv6Settings
    settings.dnsSettings = dnsSettings
    settings.mtu = NSNumber(value: mtu)

    return settings
  }
}

extension NetworkSettings.Cidr {
  var asNEIPv4Route: NEIPv4Route? {
    guard let subnetMask = IPv4SubnetMaskLookup.table[prefix] else {
      return nil
    }
    return NEIPv4Route(destinationAddress: address, subnetMask: subnetMask)
  }

  var asNEIPv6Route: NEIPv6Route? {
    guard prefix >= 0 && prefix <= 128 else {
      return nil
    }
    return NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: prefix))
  }
}

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
