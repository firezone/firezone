//
//  NetworkSettingsTests.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("NetworkSettings Tests")
struct NetworkSettingsTests {

  // MARK: - TUN Config Updates

  @Test("DNS resources remembered until TUN config applied")
  func dnsResourcesRememberedUntilTunConfig() async throws {
    var settings = NetworkSettings()

    // Update DNS resources before TUN config (should not emit)
    let result1 = settings.updateDnsResources(newDnsResources: [
      "dns1.example.com", "dns2.example.com",
    ])
    #expect(result1 == nil, "Should not emit settings without tunnel addresses")

    // Configure TUN
    let result2 = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )
    #expect(result2 != nil, "Should emit settings after TUN config")

    // Update DNS resources again with same values (should not emit because unchanged)
    let result3 = settings.updateDnsResources(newDnsResources: [
      "dns1.example.com", "dns2.example.com",
    ])
    #expect(result3 == nil, "Should not emit settings when DNS resources unchanged")

    // Update DNS resources with different values (should emit)
    let result4 = settings.updateDnsResources(newDnsResources: ["dns3.example.com"])
    #expect(result4 != nil, "Should emit settings when DNS resources changed")
  }

  @Test("First TUN config update should emit settings")
  func firstTunConfigUpdate() async throws {
    var settings = NetworkSettings()

    let payload = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )
    let result = payload?.build()

    #expect(result?.ipv4Settings?.addresses.first == "10.0.0.1")
    #expect(result?.ipv6Settings?.addresses.first == "fd00::1")
    #expect(result?.dnsSettings?.servers == ["1.1.1.1"])
    #expect(result?.dnsSettings?.searchDomains == [""])
    #expect(result?.dnsSettings?.matchDomains == [""])
    #expect(result?.dnsSettings?.matchDomainsNoSearch == false)
  }

  @Test("Sets DNS servers without DNS resources")
  func setsDnsServersWithoutResources() async throws {
    var settings = NetworkSettings()

    _ = settings.updateDnsResources(newDnsResources: [])
    let payload = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )
    let result = payload?.build()

    #expect(result?.dnsSettings?.servers == ["1.1.1.1"])
  }

  @Test("Sets DNS servers without DNS resources")
  func setDnsConfigWithoutServers() async throws {
    var settings = NetworkSettings()

    let payload = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: [],
      searchDomain: "example.com",
      routes4: [],
      routes6: []
    )
    let result = payload?.build()

    #expect(result?.dnsSettings?.searchDomains == ["example.com"])
    #expect(result?.dnsSettings?.matchDomains == ["", "example.com"])
    #expect(result?.dnsSettings?.matchDomainsNoSearch == false)
  }

  @Test("Updating to same TUN config should not emit settings")
  func sameTunConfigNoUpdate() async throws {
    var settings = NetworkSettings()

    // First update
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1", "8.8.8.8"],
      searchDomain: "example.com",
      routes4: [],
      routes6: []
    )

    // Second update with identical values
    let result = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1", "8.8.8.8"],
      searchDomain: "example.com",
      routes4: [],
      routes6: []
    )

    #expect(result == nil, "Identical TUN config should not emit settings")
  }

  @Test("Updating TUN config field should emit settings")
  func tunConfigFieldUpdate() async throws {
    var settings = NetworkSettings()

    // First update
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    // Second update with different IPv4
    let payload = settings.updateTunInterface(
      ipv4: "10.0.0.2",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )
    let result = payload?.build()

    #expect(result?.ipv4Settings?.addresses.first == "10.0.0.2")
  }

  @Test("DNS address change should emit settings")
  func dnsAddressChange() async throws {
    var settings = NetworkSettings()

    // First update
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    // Second update with different DNS
    let payload = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["8.8.8.8"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )
    let result = payload?.build()

    #expect(result?.dnsSettings?.servers == ["8.8.8.8"])
  }

  @Test("Route change should emit settings")
  func routeChange() async throws {
    var settings = NetworkSettings()

    let route1 = NetworkSettings.Cidr(address: "192.168.1.0", prefix: 24)

    // First update
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [route1],
      routes6: []
    )

    let route2 = NetworkSettings.Cidr(address: "192.168.2.0", prefix: 24)

    // Second update with additional route
    let payload = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [route1, route2],
      routes6: []
    )
    let result = payload?.build()

    #expect(result?.ipv4Settings?.includedRoutes?.count == 2)
  }

  // MARK: - DNS Resources Updates After TUN Config

  @Test("Same DNS resource list should not emit settings")
  func sameDnsResourcesNoUpdate() async throws {
    var settings = NetworkSettings()

    // Configure TUN first
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    // First DNS resources update
    _ = settings.updateDnsResources(newDnsResources: ["example.com"])

    // Second DNS resources update with same list
    let result = settings.updateDnsResources(newDnsResources: ["example.com"])

    #expect(result == nil, "Identical DNS resource list should not emit settings")
  }

  // MARK: - Dummy Match Domain Tests

  @Test("Set dummy match domain")
  func setDummyMatchDomain() async throws {
    var settings = NetworkSettings()

    // Configure TUN first
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: "example.com",
      routes4: [],
      routes6: []
    )

    // Set dummy match domain
    let payload = settings.setDummyMatchDomain()
    let result = payload?.build()

    #expect(result?.dnsSettings?.matchDomains == ["firezone-fd0020211111"])
    #expect(result?.dnsSettings?.searchDomains == ["example.com"])
  }

  @Test("Clear dummy match domain restores original")
  func clearDummyMatchDomain() async throws {
    var settings = NetworkSettings()

    // Configure TUN with search domain
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: "example.com",
      routes4: [],
      routes6: []
    )

    // Set dummy
    _ = settings.setDummyMatchDomain()

    // Clear dummy
    let payload = settings.clearDummyMatchDomain()
    let result = payload?.build()

    #expect(result?.dnsSettings?.matchDomains == ["", "example.com"])
    #expect(result?.dnsSettings?.searchDomains == ["example.com"])
  }

  @Test("Clear dummy match domain without search domain")
  func clearDummyMatchDomainNoSearchDomain() async throws {
    var settings = NetworkSettings()

    // Configure TUN without search domain
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    // Set dummy
    _ = settings.setDummyMatchDomain()

    // Clear dummy
    let payload = settings.clearDummyMatchDomain()
    let result = payload?.build()

    #expect(result?.dnsSettings?.matchDomains == [""])
    #expect(result?.dnsSettings?.searchDomains == [""])
  }

  // MARK: - Order Independence Tests

  @Test("DNS address order matters")
  func dnsAddressOrderIndependence() async throws {
    var settings = NetworkSettings()

    // First update with DNS in one order
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["8.8.8.8", "1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    // Second update with same DNS in different order should emit settings
    let payload = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1", "8.8.8.8"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )
    let result = payload?.build()

    #expect(result?.dnsSettings?.servers == ["1.1.1.1", "8.8.8.8"])
  }

  @Test("Route order should not matter")
  func routeOrderIndependence() async throws {
    var settings = NetworkSettings()

    let route1 = NetworkSettings.Cidr(address: "192.168.1.0", prefix: 24)
    let route2 = NetworkSettings.Cidr(address: "192.168.2.0", prefix: 24)

    // First update with routes in one order
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [route1, route2],
      routes6: []
    )

    // Second update with same routes in different order should not emit settings
    let result = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [route2, route1],
      routes6: []
    )

    #expect(result == nil, "Route order should not matter")
  }

  // MARK: - Cidr Route Validation Tests

  @Test("Valid IPv4 prefix returns route")
  func validIPv4PrefixReturnsRoute() {
    // Test boundary values
    let cidr0 = NetworkSettings.Cidr(address: "0.0.0.0", prefix: 0)
    let cidr24 = NetworkSettings.Cidr(address: "192.168.1.0", prefix: 24)
    let cidr32 = NetworkSettings.Cidr(address: "10.0.0.1", prefix: 32)

    #expect(cidr0.asNEIPv4Route != nil)
    #expect(cidr24.asNEIPv4Route != nil)
    #expect(cidr32.asNEIPv4Route != nil)
  }

  @Test("Invalid IPv4 prefix returns nil")
  func invalidIPv4PrefixReturnsNil() {
    let cidrNegative = NetworkSettings.Cidr(address: "192.168.1.0", prefix: -1)
    let cidr33 = NetworkSettings.Cidr(address: "192.168.1.0", prefix: 33)
    let cidr128 = NetworkSettings.Cidr(address: "192.168.1.0", prefix: 128)

    #expect(cidrNegative.asNEIPv4Route == nil, "Negative prefix should return nil")
    #expect(cidr33.asNEIPv4Route == nil, "Prefix > 32 should return nil for IPv4")
    #expect(cidr128.asNEIPv4Route == nil, "IPv6 prefix should return nil for IPv4 route")
  }

  @Test("Valid IPv6 prefix returns route")
  func validIPv6PrefixReturnsRoute() {
    // Test boundary values
    let cidr0 = NetworkSettings.Cidr(address: "::", prefix: 0)
    let cidr64 = NetworkSettings.Cidr(address: "fd00::", prefix: 64)
    let cidr128 = NetworkSettings.Cidr(address: "fd00::1", prefix: 128)

    #expect(cidr0.asNEIPv6Route != nil)
    #expect(cidr64.asNEIPv6Route != nil)
    #expect(cidr128.asNEIPv6Route != nil)
  }

  @Test("Invalid IPv6 prefix returns nil")
  func invalidIPv6PrefixReturnsNil() {
    let cidrNegative = NetworkSettings.Cidr(address: "fd00::", prefix: -1)
    let cidr129 = NetworkSettings.Cidr(address: "fd00::", prefix: 129)
    let cidr256 = NetworkSettings.Cidr(address: "fd00::", prefix: 256)

    #expect(cidrNegative.asNEIPv6Route == nil, "Negative prefix should return nil")
    #expect(cidr129.asNEIPv6Route == nil, "Prefix > 128 should return nil for IPv6")
    #expect(cidr256.asNEIPv6Route == nil, "Very large prefix should return nil")
  }

  // MARK: - Payload Encapsulation Tests

  @Test("Payload cannot be constructed directly - only via NetworkSettings methods")
  func payloadEncapsulation() {
    // Uncomment to verify fileprivate encapsulation (should fail to compile):
    // let _ = NetworkSettings.Payload(tunnelAddressIPv4: "", tunnelAddressIPv6: "", dnsServers: [], routes4: [], routes6: [], matchDomains: [], searchDomain: nil)

    // The only way to get a Payload is through NetworkSettings methods
    var settings = NetworkSettings()
    let payload = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )
    #expect(payload != nil, "Payload should only be obtainable via update methods")
  }

  @Test("Invalid routes are dropped during build")
  func invalidRoutesDroppedDuringBuild() {
    var settings = NetworkSettings()

    // Mix valid and invalid routes
    let validRoute = NetworkSettings.Cidr(address: "192.168.1.0", prefix: 24)
    let invalidRoute = NetworkSettings.Cidr(address: "10.0.0.0", prefix: 33)
    let validRoute6 = NetworkSettings.Cidr(address: "fd00::", prefix: 64)
    let invalidRoute6 = NetworkSettings.Cidr(address: "fd00::", prefix: 129)

    let payload = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsServers: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [validRoute, invalidRoute],
      routes6: [validRoute6, invalidRoute6]
    )
    let result = payload?.build()

    // Only valid routes should be present
    #expect(
      result?.ipv4Settings?.includedRoutes?.count == 1, "Invalid IPv4 route should be dropped")
    #expect(
      result?.ipv6Settings?.includedRoutes?.count == 1, "Invalid IPv6 route should be dropped")
  }
}
