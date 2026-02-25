//
//  ScopedResolversTests.swift
//  (c) 2024-2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Network
import Testing

@testable import FirezoneKit

@Suite("ScopedResolvers Tests")
struct ScopedResolversTests {

  // MARK: - Basic Tests

  @Test("Returns empty array for nil interface name")
  func returnsEmptyForNilInterface() async throws {
    let result = ScopedResolvers.getDefaultDNSServers(interfaceName: nil)
    #expect(result.isEmpty)
  }

  @Test("Returns empty array for non-existent interface")
  func returnsEmptyForNonExistentInterface() async throws {
    let result = ScopedResolvers.getDefaultDNSServers(interfaceName: "nonexistent99")
    #expect(result.isEmpty)
  }

  @Test("Returns empty array for empty interface name")
  func returnsEmptyForEmptyInterface() async throws {
    let result = ScopedResolvers.getDefaultDNSServers(interfaceName: "")
    #expect(result.isEmpty)
  }

  // MARK: - Scoped Resolvers Tests

  @Test("Can query real interface")
  func canQueryRealInterface() async throws {
    // Use "en0" as a commonly used example interface name on Apple platforms
    // This test verifies the dlsym/dns_configuration_copy path works without crashing
    let result = ScopedResolvers.getDefaultDNSServers(interfaceName: "en0")

    // Verify each result is a valid IP address
    for server in result {
      let isValidIPv4 = IPv4Address(server) != nil
      let isValidIPv6 = IPv6Address(server) != nil
      #expect(isValidIPv4 || isValidIPv6, "'\(server)' should be a valid IPv4 or IPv6 address")
    }
  }

  @Test("Multiple calls return consistent results")
  func multipleCallsConsistent() async throws {
    let result1 = ScopedResolvers.getDefaultDNSServers(interfaceName: "en0")
    let result2 = ScopedResolvers.getDefaultDNSServers(interfaceName: "en0")

    #expect(result1 == result2)
  }
}
