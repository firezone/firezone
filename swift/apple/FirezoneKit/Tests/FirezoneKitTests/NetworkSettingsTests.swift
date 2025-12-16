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

  // MARK: - DNS Resources Updated Before TUN Config

  @Test("DNS resources updated first should not emit settings")
  func dnsResourcesBeforeTunConfig() async throws {
    var settings = NetworkSettings()

    // Update DNS resources before TUN config
    let result = settings.updateDnsResources(addresses: [])

    #expect(result == nil, "Should not emit settings without tunnel addresses configured")
  }

  // MARK: - TUN Config Updates

  @Test("First TUN config update should emit settings")
  func firstTunConfigUpdate() async throws {
    var settings = NetworkSettings()

    let result = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    #expect(result?.ipv4Settings?.addresses.first == "10.0.0.1")
    #expect(result?.ipv6Settings?.addresses.first == "fd00::1")
  }

  @Test("Updating to same TUN config should not emit settings")
  func sameTunConfigNoUpdate() async throws {
    var settings = NetworkSettings()

    // First update
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["1.1.1.1", "8.8.8.8"],
      searchDomain: "example.com",
      routes4: [],
      routes6: []
    )

    // Second update with identical values
    let result = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["1.1.1.1", "8.8.8.8"],
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
      dnsAddresses: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    // Second update with different IPv4
    let result = settings.updateTunInterface(
      ipv4: "10.0.0.2",
      ipv6: "fd00::1",
      dnsAddresses: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    #expect(result?.ipv4Settings?.addresses.first == "10.0.0.2")
  }

  @Test("DNS address change should emit settings")
  func dnsAddressChange() async throws {
    var settings = NetworkSettings()

    // First update
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    // Second update with different DNS
    let result = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["8.8.8.8"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    #expect(result?.dnsSettings?.servers == ["8.8.8.8"])
  }

  @Test("Route change should emit settings")
  func routeChange() async throws {
    var settings = NetworkSettings()

    let route1 = NEIPv4Route(destinationAddress: "192.168.1.0", subnetMask: "255.255.255.0")

    // First update
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [route1],
      routes6: []
    )

    let route2 = NEIPv4Route(destinationAddress: "192.168.2.0", subnetMask: "255.255.255.0")

    // Second update with additional route
    let result = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [route1, route2],
      routes6: []
    )

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
      dnsAddresses: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    // First DNS resources update (empty list)
    _ = settings.updateDnsResources(addresses: [])

    // Second DNS resources update with same empty list
    let result = settings.updateDnsResources(addresses: [])

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
      dnsAddresses: ["1.1.1.1"],
      searchDomain: "example.com",
      routes4: [],
      routes6: []
    )

    // Set dummy match domain
    let result = settings.setDummyMatchDomain()

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
      dnsAddresses: ["1.1.1.1"],
      searchDomain: "example.com",
      routes4: [],
      routes6: []
    )

    // Set dummy
    _ = settings.setDummyMatchDomain()

    // Clear dummy
    let result = settings.clearDummyMatchDomain()

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
      dnsAddresses: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    // Set dummy
    _ = settings.setDummyMatchDomain()

    // Clear dummy
    let result = settings.clearDummyMatchDomain()

    #expect(result?.dnsSettings?.matchDomains == [""])
    #expect(result?.dnsSettings?.searchDomains == [])
  }

  // MARK: - Order Independence Tests

  @Test("DNS address order should not matter")
  func dnsAddressOrderIndependence() async throws {
    var settings = NetworkSettings()

    // First update with DNS in one order
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["8.8.8.8", "1.1.1.1"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    // Second update with same DNS in different order should not emit settings
    let result = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["1.1.1.1", "8.8.8.8"],
      searchDomain: nil,
      routes4: [],
      routes6: []
    )

    #expect(result == nil, "DNS address order should not matter")
  }

  @Test("Route order should not matter")
  func routeOrderIndependence() async throws {
    var settings = NetworkSettings()

    let route1 = NEIPv4Route(destinationAddress: "192.168.1.0", subnetMask: "255.255.255.0")
    let route2 = NEIPv4Route(destinationAddress: "192.168.2.0", subnetMask: "255.255.255.0")

    // First update with routes in one order
    _ = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [route1, route2],
      routes6: []
    )

    // Second update with same routes in different order should not emit settings
    let result = settings.updateTunInterface(
      ipv4: "10.0.0.1",
      ipv6: "fd00::1",
      dnsAddresses: ["1.1.1.1"],
      searchDomain: nil,
      routes4: [route2, route1],
      routes6: []
    )

    #expect(result == nil, "Route order should not matter")
  }
}
