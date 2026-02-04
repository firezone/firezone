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

  @Test("Can instantiate ScopedResolvers")
  func canInstantiate() async throws {
    // Just verify instantiation doesn't crash
    _ = ScopedResolvers()
  }

  @Test("Returns empty array for nil interface name")
  func returnsEmptyForNilInterface() async throws {
    let resolvers = ScopedResolvers()
    let result = resolvers.getDefaultDNSServers(interfaceName: nil)
    #expect(result.isEmpty)
  }

  @Test("Returns empty array for non-existent interface")
  func returnsEmptyForNonExistentInterface() async throws {
    let resolvers = ScopedResolvers()
    let result = resolvers.getDefaultDNSServers(interfaceName: "nonexistent99")
    #expect(result.isEmpty)
  }

  @Test("Returns empty array for empty interface name")
  func returnsEmptyForEmptyInterface() async throws {
    let resolvers = ScopedResolvers()
    let result = resolvers.getDefaultDNSServers(interfaceName: "")
    #expect(result.isEmpty)
  }

  // MARK: - Scoped Resolvers Tests

  @Test("Can query real interface")
  func canQueryRealInterface() async throws {
    let resolvers = ScopedResolvers()

    // Use "en0" as a commonly used example interface name on Apple platforms
    // This test verifies the dlsym/dns_configuration_copy path works without crashing
    let result = resolvers.getDefaultDNSServers(interfaceName: "en0")

    // Verify each result is a valid IP address
    for server in result {
      let isValidIPv4 = IPv4Address(server) != nil
      let isValidIPv6 = IPv6Address(server) != nil
      #expect(isValidIPv4 || isValidIPv6, "'\(server)' should be a valid IPv4 or IPv6 address")
    }
  }

  @Test("Multiple calls return consistent results")
  func multipleCallsConsistent() async throws {
    let resolvers = ScopedResolvers()

    let result1 = resolvers.getDefaultDNSServers(interfaceName: "en0")
    let result2 = resolvers.getDefaultDNSServers(interfaceName: "en0")

    #expect(result1 == result2)
  }

  @Test("Different instances return same results")
  func differentInstancesSameResults() async throws {
    let resolvers1 = ScopedResolvers()
    let resolvers2 = ScopedResolvers()

    let result1 = resolvers1.getDefaultDNSServers(interfaceName: "en0")
    let result2 = resolvers2.getDefaultDNSServers(interfaceName: "en0")

    #expect(result1 == result2)
  }
}
