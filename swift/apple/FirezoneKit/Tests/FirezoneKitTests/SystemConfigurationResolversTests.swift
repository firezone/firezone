//
//  SystemConfigurationResolversTests.swift
//  (c) 2024-2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Network
import Testing

@testable import FirezoneKit

@Suite("SystemConfigurationResolvers Tests")
struct SystemConfigurationResolversTests {

  // MARK: - Basic Tests

  @Test("Can instantiate SystemConfigurationResolvers")
  func canInstantiate() async throws {
    // Just verify instantiation doesn't crash
    _ = try SystemConfigurationResolvers()
  }

  @Test("Returns empty array for nil interface name")
  func returnsEmptyForNilInterface() async throws {
    let resolvers = try SystemConfigurationResolvers()
    let result = resolvers.getDefaultDNSServers(interfaceName: nil)
    #expect(result.isEmpty)
  }

  @Test("Returns empty array for non-existent interface")
  func returnsEmptyForNonExistentInterface() async throws {
    let resolvers = try SystemConfigurationResolvers()
    let result = resolvers.getDefaultDNSServers(interfaceName: "nonexistent99")
    #expect(result.isEmpty)
  }

  @Test("Returns empty array for empty interface name")
  func returnsEmptyForEmptyInterface() async throws {
    let resolvers = try SystemConfigurationResolvers()
    let result = resolvers.getDefaultDNSServers(interfaceName: "")
    #expect(result.isEmpty)
  }

  // MARK: - Scoped Resolvers (dlsym) Tests

  @Test("Scoped resolvers returns empty for nil interface")
  func scopedResolversReturnsEmptyForNil() async throws {
    let resolvers = try SystemConfigurationResolvers()
    let result = resolvers.getDefaultDNSServersViaScopedResolvers(interfaceName: nil)
    #expect(result.isEmpty)
  }

  @Test("Scoped resolvers returns empty for non-existent interface")
  func scopedResolversReturnsEmptyForNonExistent() async throws {
    let resolvers = try SystemConfigurationResolvers()
    let result = resolvers.getDefaultDNSServersViaScopedResolvers(interfaceName: "nonexistent99")
    #expect(result.isEmpty)
  }

  @Test("Scoped resolvers can query real interface")
  func scopedResolversCanQueryRealInterface() async throws {
    let resolvers = try SystemConfigurationResolvers()

    // en0 is typically the primary interface on macOS
    // This test verifies the dlsym/dns_configuration_copy path works without crashing
    let result = resolvers.getDefaultDNSServersViaScopedResolvers(interfaceName: "en0")

    // Verify each result is a valid IP address
    for server in result {
      let isValidIPv4 = IPv4Address(server) != nil
      let isValidIPv6 = IPv6Address(server) != nil
      #expect(isValidIPv4 || isValidIPv6, "'\(server)' should be a valid IPv4 or IPv6 address")
    }
  }

  @Test("Scoped resolvers multiple calls return consistent results")
  func scopedResolversMultipleCallsConsistent() async throws {
    let resolvers = try SystemConfigurationResolvers()

    let result1 = resolvers.getDefaultDNSServersViaScopedResolvers(interfaceName: "en0")
    let result2 = resolvers.getDefaultDNSServersViaScopedResolvers(interfaceName: "en0")

    #expect(result1 == result2)
  }

  @Test("Scoped resolvers different instances return same results")
  func scopedResolversDifferentInstancesSameResults() async throws {
    let resolvers1 = try SystemConfigurationResolvers()
    let resolvers2 = try SystemConfigurationResolvers()

    let result1 = resolvers1.getDefaultDNSServersViaScopedResolvers(interfaceName: "en0")
    let result2 = resolvers2.getDefaultDNSServersViaScopedResolvers(interfaceName: "en0")

    #expect(result1 == result2)
  }

  #if os(macOS)
    // MARK: - SystemConfiguration (macOS) Tests

    @Test("SystemConfiguration returns empty for nil interface")
    func sysConfigReturnsEmptyForNil() async throws {
      let resolvers = try SystemConfigurationResolvers()
      let result = resolvers.getDefaultDNSServersViaSystemConfiguration(interfaceName: nil)
      #expect(result.isEmpty)
    }

    @Test("SystemConfiguration returns empty for non-existent interface")
    func sysConfigReturnsEmptyForNonExistent() async throws {
      let resolvers = try SystemConfigurationResolvers()
      let result = resolvers.getDefaultDNSServersViaSystemConfiguration(
        interfaceName: "nonexistent99")
      #expect(result.isEmpty)
    }

    @Test("SystemConfiguration can query real interface")
    func sysConfigCanQueryRealInterface() async throws {
      let resolvers = try SystemConfigurationResolvers()

      // en0 is typically the primary interface on macOS
      let result = resolvers.getDefaultDNSServersViaSystemConfiguration(interfaceName: "en0")

      // Verify each result is a valid IP address
      for server in result {
        let isValidIPv4 = IPv4Address(server) != nil
        let isValidIPv6 = IPv6Address(server) != nil
        #expect(isValidIPv4 || isValidIPv6, "'\(server)' should be a valid IPv4 or IPv6 address")
      }
    }

    @Test("SystemConfiguration multiple calls return consistent results")
    func sysConfigMultipleCallsConsistent() async throws {
      let resolvers = try SystemConfigurationResolvers()

      let result1 = resolvers.getDefaultDNSServersViaSystemConfiguration(interfaceName: "en0")
      let result2 = resolvers.getDefaultDNSServersViaSystemConfiguration(interfaceName: "en0")

      #expect(result1 == result2)
    }

    @Test("Both implementations return results for active interface")
    func bothImplementationsReturnResults() async throws {
      let resolvers = try SystemConfigurationResolvers()

      // Both should return arrays (possibly empty if en0 has no DNS configured)
      // but importantly, neither should crash
      let scopedResult = resolvers.getDefaultDNSServersViaScopedResolvers(interfaceName: "en0")
      let sysConfigResult = resolvers.getDefaultDNSServersViaSystemConfiguration(
        interfaceName: "en0")

      // Verify both return valid IP addresses if non-empty
      for server in scopedResult {
        let isValidIPv4 = IPv4Address(server) != nil
        let isValidIPv6 = IPv6Address(server) != nil
        #expect(isValidIPv4 || isValidIPv6, "'\(server)' should be a valid IPv4 or IPv6 address")
      }
      for server in sysConfigResult {
        let isValidIPv4 = IPv4Address(server) != nil
        let isValidIPv6 = IPv6Address(server) != nil
        #expect(isValidIPv4 || isValidIPv6, "'\(server)' should be a valid IPv4 or IPv6 address")
      }
    }
  #endif
}
