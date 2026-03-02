//
//  VPNConfigurationManagerTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("VPNConfigurationManager Tests")
struct VPNConfigurationManagerTests {

  @Test("legacyConfiguration returns config when providerConfiguration has valid [String: String]")
  func legacyConfigurationReturnsValidConfig() {
    let proto = NETunnelProviderProtocol()
    proto.providerConfiguration = [
      "accountSlug": "test-account",
      "authURL": "https://app.firezone.dev",
    ]

    let result = VPNConfigurationManager.legacyConfiguration(protocolConfiguration: proto)

    #expect(result == ["accountSlug": "test-account", "authURL": "https://app.firezone.dev"])
  }

  @Test("legacyConfiguration returns nil when protocolConfiguration is nil")
  func legacyConfigurationNilProtocol() {
    let result = VPNConfigurationManager.legacyConfiguration(protocolConfiguration: nil)

    #expect(result == nil)
  }

  @Test("legacyConfiguration returns nil when providerConfiguration is nil")
  func legacyConfigurationNilProvider() {
    let proto = NETunnelProviderProtocol()
    proto.providerConfiguration = nil

    let result = VPNConfigurationManager.legacyConfiguration(protocolConfiguration: proto)

    #expect(result == nil)
  }

  @Test("legacyConfiguration returns nil when providerConfiguration has wrong value type")
  func legacyConfigurationWrongType() {
    let proto = NETunnelProviderProtocol()
    proto.providerConfiguration = ["key": 42]

    let result = VPNConfigurationManager.legacyConfiguration(protocolConfiguration: proto)

    #expect(result == nil)
  }
}
