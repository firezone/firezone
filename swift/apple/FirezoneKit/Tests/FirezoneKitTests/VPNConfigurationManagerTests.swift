//
//  VPNConfigurationManagerTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import NetworkExtension
import Testing

@testable import FirezoneKit

@MainActor
private final class StubTunnelProviderManager: TunnelProviderManager {
  var isEnabled = true
  var localizedDescription: String?
  var protocolConfiguration: NEVPNProtocol?
  var tunnelSession: (any TunnelSessionProtocol)? { nil }
  var saveCount = 0

  init(providerBundleIdentifier: String?, identityReference: Data? = nil) {
    let configuration = NETunnelProviderProtocol()
    configuration.providerBundleIdentifier = providerBundleIdentifier
    configuration.identityReference = identityReference
    configuration.providerConfiguration = ["accountSlug": "acme"]
    configuration.serverAddress = "Firezone"
    self.protocolConfiguration = configuration
  }

  func saveToPreferences() async throws {
    saveCount += 1
  }

  func loadFromPreferences() async throws {}
}

@MainActor
private final class StubFactory: TunnelProviderManagerFactory {
  let managers: [any TunnelProviderManager]

  init(_ managers: [any TunnelProviderManager]) {
    self.managers = managers
  }

  func loadAllFromPreferences() async throws -> [any TunnelProviderManager] { managers }
  func createManager() -> any TunnelProviderManager {
    StubTunnelProviderManager(providerBundleIdentifier: providerBundleIdentifier)
  }
}

private let providerBundleIdentifier = "dev.firezone.firezone.network-extension"

@Suite("VPNConfigurationManager Tests")
struct VPNConfigurationManagerTests {
  @Test("An app-created configuration is not managed")
  @MainActor
  func appCreatedConfigurationIsNotManaged() async throws {
    let factory = StubFactory([
      StubTunnelProviderManager(providerBundleIdentifier: providerBundleIdentifier)
    ])

    let manager = try #require(
      await VPNConfigurationManager.load(
        using: factory, providerBundleIdentifier: providerBundleIdentifier))

    #expect(!manager.isManaged)
    #expect(try manager.identityReference() == nil)
  }

  @Test("A configuration carrying a client certificate is managed")
  @MainActor
  func certificateConfigurationIsManaged() async throws {
    let reference = Data([1, 2, 3])
    let factory = StubFactory([
      StubTunnelProviderManager(
        providerBundleIdentifier: providerBundleIdentifier, identityReference: reference)
    ])

    let manager = try #require(
      await VPNConfigurationManager.load(
        using: factory, providerBundleIdentifier: providerBundleIdentifier))

    #expect(manager.isManaged)
    #expect(try manager.identityReference() == reference)
  }

  @Test("A profile without a provider bundle identifier is managed")
  @MainActor
  func profileWithoutProviderBundleIdentifierIsManaged() async throws {
    let factory = StubFactory([StubTunnelProviderManager(providerBundleIdentifier: nil)])

    let manager = try #require(
      await VPNConfigurationManager.load(
        using: factory, providerBundleIdentifier: providerBundleIdentifier))

    #expect(manager.isManaged)
  }

  @Test("Configurations for another extension are ignored")
  @MainActor
  func otherExtensionsAreIgnored() async throws {
    let factory = StubFactory([
      StubTunnelProviderManager(providerBundleIdentifier: "com.example.vpn.extension")
    ])

    let manager = try await VPNConfigurationManager.load(
      using: factory, providerBundleIdentifier: providerBundleIdentifier)

    #expect(manager == nil)
  }

  @Test("The configuration with a client certificate wins")
  @MainActor
  func certificateConfigurationIsPreferred() async throws {
    let reference = Data([4, 5, 6])
    let factory = StubFactory([
      StubTunnelProviderManager(providerBundleIdentifier: providerBundleIdentifier),
      StubTunnelProviderManager(
        providerBundleIdentifier: providerBundleIdentifier, identityReference: reference),
    ])

    let manager = try #require(
      await VPNConfigurationManager.load(
        using: factory, providerBundleIdentifier: providerBundleIdentifier))

    #expect(try manager.identityReference() == reference)
  }

  @Test("Settings are not written back to a managed profile")
  @MainActor
  func managedProfileIsNotWrittenTo() async throws {
    let stub = StubTunnelProviderManager(
      providerBundleIdentifier: providerBundleIdentifier, identityReference: Data([7]))
    let factory = StubFactory([stub])

    let manager = try #require(
      await VPNConfigurationManager.load(
        using: factory, providerBundleIdentifier: providerBundleIdentifier))

    try await manager.save(providerConfiguration: ["accountSlug": "other"])

    #expect(stub.saveCount == 0)
    #expect(
      (stub.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        as? [String: String] == ["accountSlug": "acme"])
  }

  @Test("A managed profile makes settings read-only")
  @MainActor
  func managedProfileForcesSettings() async throws {
    let defaults = UserDefaults.makeTestDefaults()
    let configuration = Configuration(userDefaults: defaults)
    let factory = StubFactory([
      StubTunnelProviderManager(
        providerBundleIdentifier: providerBundleIdentifier, identityReference: Data([8]))
    ])

    let manager = try #require(
      await VPNConfigurationManager.load(
        using: factory, providerBundleIdentifier: providerBundleIdentifier))
    try await manager.loadConfiguration(into: configuration, userDefaults: defaults)

    #expect(configuration.isVPNConfigurationManaged)
    #expect(configuration.isApiURLForced)
    #expect(configuration.isAccountSlugForced)
    #expect(configuration.accountSlug == "acme")
  }
}
