//
//  NetworkSettings.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0

import Foundation
import NetworkExtension
import os.log

class NetworkSettings {

  // Unchanging values
  let tunnelAddressIPv4: String
  let tunnelAddressIPv6: String
  let dnsAddress: String

  // WireGuard has an 80-byte overhead.
  let tunnelOverheadBytes = NSNumber(80)

  // Modifiable values
  private(set) var routes: [String] = []
  private(set) var resourceDomains: [String] = []

  // To keep track of modifications
  private(set) var hasUnappliedChanges: Bool

  init(
    tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddress: String
  ) {
    self.tunnelAddressIPv4 = tunnelAddressIPv4
    self.tunnelAddressIPv6 = tunnelAddressIPv6
    self.dnsAddress = dnsAddress
    self.hasUnappliedChanges = true
  }

  func addRoute(_ route: String) {
    if !self.routes.contains(route) {
      self.routes.append(route)
      self.hasUnappliedChanges = true
    }
  }

  func removeRoute(_ route: String) {
    if self.routes.contains(route) {
      self.routes.removeAll(where: { $0 == route })
      self.hasUnappliedChanges = true
    }
  }

  func setResourceDomains(_ resourceDomains: [String]) {
    let sortedResourceDomains = resourceDomains.sorted()
    if self.resourceDomains != sortedResourceDomains {
      self.resourceDomains = sortedResourceDomains
    }
  }

  func apply(
    on packetTunnelProvider: NEPacketTunnelProvider, logger: Logger,
    completionHandler: ((Error?) -> Void)?
  ) {

    guard self.hasUnappliedChanges else {
      logger.error("NetworkSettings.apply: No changes to apply")
      completionHandler?(nil)
      return
    }

    logger.log("NetworkSettings.apply: Applying network settings")

    var tunnelIPv4Routes: [NEIPv4Route] = []
    var tunnelIPv6Routes: [NEIPv6Route] = []

    for route in routes {
      let components = route.split(separator: "/")
      guard components.count == 2 else {
        logger.error("NetworkSettings.apply: Ignoring invalid route '\(route, privacy: .public)'")
        continue
      }
      let address = String(components[0])
      let networkPrefixLengthString = String(components[1])
      if let groupSeparator = address.first(where: { $0 == "." || $0 == ":" }) {
        if groupSeparator == "." {  // IPv4 address
          if IPv4Address(address) == nil {
            logger.error(
              "NetworkSettings.apply: Ignoring invalid IPv4 address '\(address, privacy: .public)'")
            continue
          }
          let validNetworkPrefixLength = Self.validNetworkPrefixLength(
            fromString: networkPrefixLengthString, maximumValue: 32)
          let ipv4SubnetMask = Self.ipv4SubnetMask(networkPrefixLength: validNetworkPrefixLength)
          logger.log(
            """
            NetworkSettings.apply:
              Adding IPv4 route: \(address, privacy: .public) (subnet mask: \(ipv4SubnetMask, privacy: .public)
            """)
          tunnelIPv4Routes.append(
            NEIPv4Route(destinationAddress: address, subnetMask: ipv4SubnetMask))
        }
        if groupSeparator == ":" {  // IPv6 address
          if IPv6Address(address) == nil {
            logger.error(
              "NetworkSettings.apply: Ignoring invalid IPv6 address '\(address, privacy: .public)'")
            continue
          }
          let validNetworkPrefixLength = Self.validNetworkPrefixLength(
            fromString: networkPrefixLengthString, maximumValue: 128)
          logger.log(
            """
            NetworkSettings.apply:
              Adding IPv6 route: \(address, privacy: .public) (prefix length: \(validNetworkPrefixLength, privacy: .public)
            """)

          tunnelIPv6Routes.append(
            NEIPv6Route(
              destinationAddress: address,
              networkPrefixLength: NSNumber(integerLiteral: validNetworkPrefixLength)))
        }
      } else {
        logger.error("NetworkSettings.apply: Ignoring invalid route '\(route, privacy: .public)'")
      }
    }

    // We don't really know the connlib gateway IP address at this point, but just using 127.0.0.1 is okay
    // because the OS doesn't really need this IP address.
    // NEPacketTunnelNetworkSettings taking in tunnelRemoteAddress is probably a bad abstraction caused by
    // NEPacketTunnelNetworkSettings inheriting from NETunnelNetworkSettings.

    let tunnelNetworkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

    let ipv4Settings = NEIPv4Settings(
      addresses: [tunnelAddressIPv4], subnetMasks: ["255.255.255.255"])
    ipv4Settings.includedRoutes = tunnelIPv4Routes
    tunnelNetworkSettings.ipv4Settings = ipv4Settings

    let ipv6Settings = NEIPv6Settings(addresses: [tunnelAddressIPv6], networkPrefixLengths: [128])
    ipv6Settings.includedRoutes = tunnelIPv6Routes
    tunnelNetworkSettings.ipv6Settings = ipv6Settings

    let dnsSettings = NEDNSSettings(servers: [dnsAddress])
    // Intercept all DNS queries; SplitDNS will be handled by connlib
    dnsSettings.matchDomains = [""]
    tunnelNetworkSettings.dnsSettings = dnsSettings
    tunnelNetworkSettings.tunnelOverheadBytes = tunnelOverheadBytes

    self.hasUnappliedChanges = false
    logger.log("Attempting to set network settings")
    packetTunnelProvider.setTunnelNetworkSettings(tunnelNetworkSettings) { error in
      if let error = error {
        logger.error("NetworkSettings.apply: Error: \(error, privacy: .public)")
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

extension NetworkSettings {
  private static func validNetworkPrefixLength(fromString string: String, maximumValue: Int) -> Int
  {
    guard let networkPrefixLength = Int(string) else { return 0 }
    if networkPrefixLength < 0 { return 0 }
    if networkPrefixLength > maximumValue { return maximumValue }
    return networkPrefixLength
  }

  private static func ipv4SubnetMask(networkPrefixLength: Int) -> String {
    precondition(networkPrefixLength >= 0 && networkPrefixLength <= 32)
    let mask: UInt32 = 0xFFFF_FFFF
    let maxPrefixLength = 32
    let octets = 4

    let subnetMask = mask & (mask << (maxPrefixLength - networkPrefixLength))
    var parts: [String] = []
    for idx in 0...(octets - 1) {
      let part = String(UInt32(0x0000_00FF) & (subnetMask >> ((octets - 1 - idx) * 8)), radix: 10)
      parts.append(part)
    }

    return parts.joined(separator: ".")
  }
}
