//
//  ConfigurationTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import NetworkExtension
import Testing

@testable import FirezoneKit

private final class ForcedUserDefaults: UserDefaults {
  let domainName: String
  private let forcedKeys: Set<String>
  private let forcedValues: [String: Any]

  init?(forcedKeys: Set<String>, forcedValues: [String: Any] = [:]) {
    let domainName = "dev.firezone.firezone.tests.\(UUID().uuidString)"
    self.domainName = domainName
    self.forcedKeys = forcedKeys
    self.forcedValues = forcedValues

    super.init(suiteName: domainName)
    removePersistentDomain(forName: domainName)
  }

  override func objectIsForced(forKey defaultName: String) -> Bool {
    forcedKeys.contains(defaultName)
  }

  override func object(forKey defaultName: String) -> Any? {
    forcedValues[defaultName] ?? super.object(forKey: defaultName)
  }

  override func string(forKey defaultName: String) -> String? {
    forcedValues[defaultName] as? String ?? super.string(forKey: defaultName)
  }

  override func bool(forKey defaultName: String) -> Bool {
    forcedValues[defaultName] as? Bool ?? super.bool(forKey: defaultName)
  }
}

@MainActor
private final class MockTunnelProviderManager: TunnelProviderManager {
  var isEnabled = true
  var localizedDescription: String?
  var protocolConfiguration: NEVPNProtocol?
  let connection: NEVPNConnection = NETunnelProviderManager().connection
  var saveCount = 0
  var loadCount = 0

  func saveToPreferences() async throws {
    saveCount += 1
  }

  func loadFromPreferences() async throws {
    loadCount += 1
  }
}

@Suite("Configuration Tests")
struct ConfigurationTests {

  // MARK: - Default Values

  @Test("Returns default values when provider configuration is empty")
  @MainActor
  func defaultValues() async {
    let defaults = UserDefaults.makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    #expect(config.authURL == ConfigurationDefaults.authURL)
    #expect(config.apiURL == ConfigurationDefaults.apiURL)
    #expect(config.logFilter == ConfigurationDefaults.logFilter)
    #expect(config.accountSlug == ConfigurationDefaults.accountSlug)
    #expect(config.actorName == ConfigurationDefaults.actorName)
    #expect(config.supportURL == ConfigurationDefaults.supportURL)
    #expect(config.connectOnStart == ConfigurationDefaults.connectOnStart)
    #expect(config.startOnLogin == ConfigurationDefaults.startOnLogin)
    #expect(config.disableUpdateCheck == ConfigurationDefaults.disableUpdateCheck)
    #expect(config.internetResourceEnabled == false)
    #expect(config.hideAdminPortalMenuItem == false)
    #expect(config.hideResourceList == false)
  }

  @Test("String defaults use fallback when key is missing")
  @MainActor
  func stringDefaultsFallback() async {
    let defaults = UserDefaults.makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    // Verify the fallback logic works - string(forKey:) returns nil, so ?? kicks in
    // These assertions verify the actual values, not just self-comparison
    #expect(config.authURL.starts(with: "https://app.fire"))
    #expect(config.apiURL.starts(with: "wss://api.fire"))
    #expect(config.supportURL == "https://www.firezone.dev/support")
    #expect(config.accountSlug.isEmpty)

    // Confirm nothing was written to UserDefaults (defaults are computed, not stored)
    #expect(defaults.string(forKey: "authURL") == nil)
    #expect(defaults.string(forKey: "apiURL") == nil)
    #expect(defaults.string(forKey: "supportURL") == nil)
  }

  // MARK: - Read/Write Properties

  @Test("String properties persist to provider configuration")
  @MainActor
  func stringPropertiesPersist() async {
    let defaults = UserDefaults.makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    config.authURL = "https://custom.auth.url"
    config.apiURL = "wss://custom.api.url"
    config.logFilter = "trace"
    config.accountSlug = "test-slug"
    config.actorName = "Test User"

    #expect(config.authURL == "https://custom.auth.url")
    #expect(config.apiURL == "wss://custom.api.url")
    #expect(config.logFilter == "trace")
    #expect(config.accountSlug == "test-slug")
    #expect(config.actorName == "Test User")
    #expect(config.supportURL == ConfigurationDefaults.supportURL)

    let providerConfiguration = config.toProviderConfiguration()

    // User-editable connection settings are no longer written to UserDefaults.
    #expect(defaults.string(forKey: "authURL") == nil)
    #expect(defaults.string(forKey: "apiURL") == nil)
    #expect(defaults.string(forKey: "logFilter") == nil)
    #expect(defaults.string(forKey: "accountSlug") == nil)
    #expect(defaults.string(forKey: "actorName") == nil)
    #expect(providerConfiguration["authURL"] == "https://custom.auth.url")
    #expect(providerConfiguration["apiURL"] == "wss://custom.api.url")
    #expect(providerConfiguration["logFilter"] == "trace")
    #expect(providerConfiguration["accountSlug"] == "test-slug")
    #expect(providerConfiguration["actorName"] == "Test User")

    #expect(defaults.string(forKey: "supportURL") == nil)
  }

  @Test("Boolean properties persist to their configured stores")
  @MainActor
  func booleanPropertiesPersist() async {
    let defaults = UserDefaults.makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    config.connectOnStart = true
    config.startOnLogin = true
    config.internetResourceEnabled = true

    #expect(config.connectOnStart == true)
    #expect(config.startOnLogin == true)
    #expect(config.disableUpdateCheck == false)
    #expect(config.internetResourceEnabled == true)
    #expect(config.hideAdminPortalMenuItem == false)
    #expect(config.hideResourceList == false)

    let providerConfiguration = config.toProviderConfiguration()

    #expect(defaults.object(forKey: "connectOnStart") == nil)
    #expect(defaults.object(forKey: "startOnLogin") == nil)
    #expect(defaults.object(forKey: "internetResourceEnabled") == nil)
    #expect(providerConfiguration["connectOnStart"] == "true")
    #expect(providerConfiguration["startOnLogin"] == "true")
    #expect(providerConfiguration["internetResourceEnabled"] == "true")

    #expect(defaults.object(forKey: "disableUpdateCheck") == nil)
    #expect(defaults.object(forKey: "hideAdminPortalMenuItem") == nil)
    #expect(defaults.object(forKey: "hideResourceList") == nil)
  }

  @Test("MDM-only UserDefaults values are read from UserDefaults")
  @MainActor
  func mdmOnlyValuesReadFromUserDefaults() async {
    let defaults = UserDefaults.makeTestDefaults()

    defaults.set(true, forKey: "hideAdminPortalMenuItem")
    defaults.set(true, forKey: "hideResourceList")
    defaults.set(true, forKey: "disableUpdateCheck")
    defaults.set("https://custom.support.url", forKey: "supportURL")

    let config = Configuration(userDefaults: defaults)

    #expect(config.hideAdminPortalMenuItem == true)
    #expect(config.hideResourceList == true)
    #expect(config.disableUpdateCheck == true)
    #expect(config.supportURL == "https://custom.support.url")
  }

  @Test("Forced MDM values override effective configuration without changing base provider values")
  @MainActor
  func forcedValuesOverrideEffectiveConfigurationOnly() async throws {
    let defaults = try #require(
      ForcedUserDefaults(forcedKeys: [
        Configuration.Keys.apiURL
      ])
    )
    defaults.set("wss://mdm.api", forKey: Configuration.Keys.apiURL)

    let config = Configuration(userDefaults: defaults)
    config.loadProviderConfiguration([
      Configuration.Keys.apiURL: "wss://provider.api",
      Configuration.Keys.internetResourceEnabled: "false",
    ])

    #expect(config.apiURL == "wss://mdm.api")
    #expect(config.internetResourceEnabled == false)

    let providerConfiguration = config.toProviderConfiguration()
    #expect(providerConfiguration[Configuration.Keys.apiURL] == "wss://provider.api")
    #expect(providerConfiguration[Configuration.Keys.internetResourceEnabled] == "false")
    #expect(
      providerConfiguration[Configuration.forcedKey(for: Configuration.Keys.apiURL)]
        == "wss://mdm.api")
    #expect(
      providerConfiguration[
        Configuration.forcedKey(for: Configuration.Keys.internetResourceEnabled)] == nil)
  }

  @Test("Forced configuration contains only MDM-forced tunnel settings")
  @MainActor
  func forcedConfigurationContainsOnlyForcedTunnelSettings() async throws {
    let defaults = try #require(
      ForcedUserDefaults(forcedKeys: [
        Configuration.Keys.apiURL,
        Configuration.Keys.logFilter,
        Configuration.Keys.authURL,
        Configuration.Keys.internetResourceEnabled,
      ])
    )
    defaults.set("wss://mdm.api", forKey: Configuration.Keys.apiURL)
    defaults.set("trace", forKey: Configuration.Keys.logFilter)
    defaults.set("https://mdm.auth", forKey: Configuration.Keys.authURL)
    defaults.set(true, forKey: Configuration.Keys.internetResourceEnabled)

    let config = Configuration(userDefaults: defaults)
    let forcedConfiguration = config.forcedConfiguration()

    #expect(forcedConfiguration[Configuration.Keys.apiURL] == "wss://mdm.api")
    #expect(forcedConfiguration[Configuration.Keys.logFilter] == "trace")
    #expect(forcedConfiguration[Configuration.Keys.authURL] == nil)
    #expect(forcedConfiguration[Configuration.Keys.internetResourceEnabled] == nil)

    let providerConfiguration = config.toProviderConfiguration()
    for (key, value) in forcedConfiguration {
      #expect(providerConfiguration[Configuration.forcedKey(for: key)] == value)
    }
    // Keys absent from forcedConfiguration must not appear under the forced prefix either.
    #expect(
      providerConfiguration[Configuration.forcedKey(for: Configuration.Keys.authURL)] == nil)
    #expect(
      providerConfiguration[
        Configuration.forcedKey(
          for: Configuration.Keys.internetResourceEnabled)] == nil)
  }

  @Test("Settings save skips forced MDM fields")
  @MainActor
  func settingsSaveSkipsForcedFields() async throws {
    let defaults = try #require(
      ForcedUserDefaults(forcedKeys: [
        Configuration.Keys.authURL
      ])
    )
    defaults.set("https://mdm.auth", forKey: Configuration.Keys.authURL)

    let config = Configuration(userDefaults: defaults)
    config.loadProviderConfiguration(
      [
        Configuration.Keys.authURL: "https://provider.auth",
        Configuration.Keys.apiURL: "wss://provider.api",
      ]
    )

    let viewModel = SettingsViewModel(configuration: config)
    viewModel.authURL = "https://attempted-user-change.auth"
    viewModel.apiURL = "wss://saved-user-change.api"

    try await viewModel.save()

    let providerConfiguration = config.toProviderConfiguration()
    #expect(providerConfiguration[Configuration.Keys.authURL] == "https://provider.auth")
    #expect(providerConfiguration[Configuration.Keys.apiURL] == "wss://saved-user-change.api")
  }

  // MARK: - Published Properties Initialization

  @Test("Published MDM-only properties initialize from UserDefaults")
  @MainActor
  func publishedPropertiesInitialized() async {
    let defaults = UserDefaults.makeTestDefaults()

    defaults.set(true, forKey: "hideAdminPortalMenuItem")
    defaults.set(true, forKey: "hideResourceList")

    let config = Configuration(userDefaults: defaults)
    config.loadProviderConfiguration(["internetResourceEnabled": "true"])

    #expect(config.publishedInternetResourceEnabled == true)
    #expect(config.publishedHideAdminPortalMenuItem == true)
    #expect(config.publishedHideResourceList == true)
  }

  // MARK: - Reactive Published Property Updates

  @Test("Published properties update when regular properties change")
  @MainActor
  func publishedPropertiesUpdateReactively() async {
    let defaults = UserDefaults.makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    // Initially false
    #expect(config.publishedInternetResourceEnabled == false)

    // Wait for the published property to update to the expected value
    await confirmation { confirm in
      let cancellable = config.internetResourceEnabledPublisher
        .sink { value in
          if value { confirm() }  // only confirm when true
        }

      config.internetResourceEnabled = true

      // Give async notification time to propagate
      try? await Task.sleep(for: .milliseconds(100))

      _ = cancellable
    }
  }

  @Test("Published MDM-only properties update from UserDefaults changes")
  @MainActor
  func publishedPropertiesUpdateFromExternalChanges() async {
    let defaults = UserDefaults.makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    #expect(config.publishedHideResourceList == false)

    defaults.set(true, forKey: "hideResourceList")

    // Give async notification time to propagate
    try? await Task.sleep(for: .milliseconds(100))

    #expect(config.publishedHideResourceList == true)
  }

  @Test("objectWillChange emits when properties change")
  @MainActor
  func objectWillChangeEmits() async {
    let defaults = UserDefaults.makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    // Wait for objectWillChange to emit and verify state changed correctly
    var confirmed = false
    await confirmation { confirm in
      let cancellable = config.objectWillChange.sink { [weak config] _ in
        // Verify the state is correct when objectWillChange fires (only confirm once)
        if !confirmed && config?.publishedInternetResourceEnabled == true {
          confirmed = true
          confirm()
        }
      }

      config.internetResourceEnabled = true

      // Give async notification time to propagate
      try? await Task.sleep(for: .milliseconds(100))

      _ = cancellable
    }
  }

  // MARK: - Reading Pre-existing Values

  @Test("ConfigurationMigrator migrates pre-existing UserDefaults values")
  @MainActor
  func readsPreExistingValues() async throws {
    let defaults = try #require(ForcedUserDefaults(forcedKeys: []))

    // Set values before creating Configuration
    defaults.set("https://preset.auth", forKey: Configuration.Keys.authURL)
    defaults.set("wss://preset.api", forKey: Configuration.Keys.apiURL)
    defaults.set("Preset User", forKey: Configuration.Keys.actorName)
    defaults.set(true, forKey: Configuration.Keys.connectOnStart)
    defaults.set(true, forKey: Configuration.Keys.internetResourceEnabled)

    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.providerConfiguration = [:]
    let tunnelProviderManager = MockTunnelProviderManager()
    tunnelProviderManager.protocolConfiguration = protocolConfiguration
    let vpnConfigurationManager = VPNConfigurationManager(from: tunnelProviderManager)

    try await ConfigurationMigrator.migrateUserDefaultsIfNeeded(
      userDefaults: defaults,
      vpnConfigurationManager: vpnConfigurationManager,
      userDefaultsDomain: defaults.domainName
    )

    let providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
    #expect(providerConfiguration?[Configuration.Keys.authURL] == "https://preset.auth")
    #expect(providerConfiguration?[Configuration.Keys.apiURL] == "wss://preset.api")
    #expect(providerConfiguration?[Configuration.Keys.logFilter] == ConfigurationDefaults.logFilter)
    #expect(
      providerConfiguration?[Configuration.Keys.accountSlug] == ConfigurationDefaults.accountSlug)
    #expect(providerConfiguration?[Configuration.Keys.actorName] == "Preset User")
    #expect(providerConfiguration?[Configuration.Keys.connectOnStart] == "true")
    #expect(providerConfiguration?[Configuration.Keys.startOnLogin] == "false")
    #expect(providerConfiguration?[Configuration.Keys.internetResourceEnabled] == "true")
    #expect(providerConfiguration?[Configuration.Keys.userDefaultsMigrated] == "true")
    #expect(defaults.object(forKey: Configuration.Keys.authURL) == nil)
    #expect(defaults.object(forKey: Configuration.Keys.apiURL) == nil)
    #expect(defaults.object(forKey: Configuration.Keys.logFilter) == nil)
    #expect(defaults.object(forKey: Configuration.Keys.accountSlug) == nil)
    #expect(defaults.object(forKey: Configuration.Keys.actorName) == nil)
    #expect(defaults.object(forKey: Configuration.Keys.connectOnStart) == nil)
    #expect(defaults.object(forKey: Configuration.Keys.startOnLogin) == nil)
    #expect(defaults.object(forKey: Configuration.Keys.internetResourceEnabled) == nil)
    #expect(tunnelProviderManager.saveCount == 1)
  }

  @Test("ConfigurationMigrator migrates user-domain values without copying MDM-only values")
  @MainActor
  func migratorMigratesUserDomainValuesWithoutCopyingMDMOnlyValues() async throws {
    let defaults = try #require(
      ForcedUserDefaults(
        forcedKeys: [
          Configuration.Keys.authURL,
          Configuration.Keys.apiURL,
          Configuration.Keys.connectOnStart,
          Configuration.Keys.hideAdminPortalMenuItem,
          Configuration.Keys.hideResourceList,
          Configuration.Keys.disableUpdateCheck,
          Configuration.Keys.supportURL,
        ],
        forcedValues: [
          Configuration.Keys.authURL: "https://forced.auth",
          Configuration.Keys.apiURL: "wss://forced.api",
          Configuration.Keys.connectOnStart: true,
          Configuration.Keys.hideAdminPortalMenuItem: true,
          Configuration.Keys.hideResourceList: true,
          Configuration.Keys.disableUpdateCheck: true,
          Configuration.Keys.supportURL: "https://forced.support",
        ]
      )
    )

    defaults.set("", forKey: Configuration.Keys.authURL)
    defaults.set("wss://user.api", forKey: Configuration.Keys.apiURL)
    defaults.set("trace", forKey: Configuration.Keys.logFilter)
    defaults.set("user-account", forKey: Configuration.Keys.accountSlug)
    defaults.set("Legacy User", forKey: Configuration.Keys.actorName)
    defaults.set(false, forKey: Configuration.Keys.connectOnStart)
    defaults.set(true, forKey: Configuration.Keys.startOnLogin)
    defaults.set(true, forKey: Configuration.Keys.internetResourceEnabled)
    defaults.set(true, forKey: Configuration.Keys.hideAdminPortalMenuItem)
    defaults.set(true, forKey: Configuration.Keys.hideResourceList)
    defaults.set(true, forKey: Configuration.Keys.disableUpdateCheck)
    defaults.set("https://support.example", forKey: Configuration.Keys.supportURL)

    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.providerConfiguration = [:]
    let tunnelProviderManager = MockTunnelProviderManager()
    tunnelProviderManager.protocolConfiguration = protocolConfiguration
    let vpnConfigurationManager = VPNConfigurationManager(from: tunnelProviderManager)

    try await ConfigurationMigrator.migrateUserDefaultsIfNeeded(
      userDefaults: defaults,
      vpnConfigurationManager: vpnConfigurationManager,
      userDefaultsDomain: defaults.domainName
    )

    let providerConfiguration = try #require(
      protocolConfiguration.providerConfiguration as? [String: String]
    )
    #expect(providerConfiguration[Configuration.Keys.authURL] == ConfigurationDefaults.authURL)
    #expect(providerConfiguration[Configuration.Keys.apiURL] == "wss://user.api")
    #expect(providerConfiguration[Configuration.Keys.logFilter] == "trace")
    #expect(providerConfiguration[Configuration.Keys.accountSlug] == "user-account")
    #expect(providerConfiguration[Configuration.Keys.actorName] == "Legacy User")
    #expect(providerConfiguration[Configuration.Keys.connectOnStart] == "false")
    #expect(providerConfiguration[Configuration.Keys.startOnLogin] == "true")
    #expect(providerConfiguration[Configuration.Keys.internetResourceEnabled] == "true")
    #expect(providerConfiguration[Configuration.Keys.hideAdminPortalMenuItem] == nil)
    #expect(providerConfiguration[Configuration.Keys.hideResourceList] == nil)
    #expect(providerConfiguration[Configuration.Keys.disableUpdateCheck] == nil)
    #expect(providerConfiguration[Configuration.Keys.supportURL] == nil)
    #expect(providerConfiguration[Configuration.Keys.userDefaultsMigrated] == "true")
    let userDomain = defaults.persistentDomain(forName: defaults.domainName) ?? [:]
    #expect(userDomain[Configuration.Keys.apiURL] == nil)
    #expect(userDomain[Configuration.Keys.logFilter] == nil)
    #expect(userDomain[Configuration.Keys.accountSlug] == nil)
    #expect(userDomain[Configuration.Keys.actorName] == nil)
    #expect(userDomain[Configuration.Keys.connectOnStart] == nil)
    #expect(userDomain[Configuration.Keys.startOnLogin] == nil)
    #expect(userDomain[Configuration.Keys.internetResourceEnabled] == nil)
    #expect(userDomain[Configuration.Keys.hideAdminPortalMenuItem] != nil)
    #expect(userDomain[Configuration.Keys.hideResourceList] != nil)
    #expect(userDomain[Configuration.Keys.disableUpdateCheck] != nil)
    #expect(userDomain[Configuration.Keys.supportURL] != nil)
    #expect(tunnelProviderManager.saveCount == 1)
  }

  @Test("ConfigurationMigrator does not persist forced MDM values")
  @MainActor
  func migratorDoesNotPersistForcedValues() async throws {
    let defaults = try #require(
      ForcedUserDefaults(forcedKeys: [
        Configuration.Keys.apiURL,
        Configuration.Keys.logFilter,
      ])
    )
    defaults.set("wss://forced.api", forKey: Configuration.Keys.apiURL)
    defaults.set("trace", forKey: Configuration.Keys.logFilter)

    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.providerConfiguration = [
      Configuration.Keys.apiURL: "wss://provider.api",
      Configuration.Keys.logFilter: "info",
      Configuration.Keys.userDefaultsMigrated: "true",
    ]
    let tunnelProviderManager = MockTunnelProviderManager()
    tunnelProviderManager.protocolConfiguration = protocolConfiguration
    let vpnConfigurationManager = VPNConfigurationManager(from: tunnelProviderManager)

    try await ConfigurationMigrator.migrateUserDefaultsIfNeeded(
      userDefaults: defaults,
      vpnConfigurationManager: vpnConfigurationManager
    )

    let providerConfiguration = try #require(
      protocolConfiguration.providerConfiguration as? [String: String]
    )
    #expect(providerConfiguration[Configuration.Keys.apiURL] == "wss://provider.api")
    #expect(providerConfiguration[Configuration.Keys.logFilter] == "info")
    #expect(tunnelProviderManager.saveCount == 0)
  }

  @Test("VPNConfigurationManager caches forced configuration on load")
  @MainActor
  func vpnConfigurationManagerCachesForcedConfigurationOnLoad() async throws {
    let defaults = try #require(
      ForcedUserDefaults(
        forcedKeys: [
          Configuration.Keys.apiURL,
          Configuration.Keys.logFilter,
        ],
        forcedValues: [
          Configuration.Keys.apiURL: "wss://forced.api",
          Configuration.Keys.logFilter: "trace",
        ]
      )
    )
    let configuration = Configuration(userDefaults: defaults)

    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.serverAddress = "Firezone"
    protocolConfiguration.providerConfiguration = [
      Configuration.Keys.authURL: "https://provider.auth",
      Configuration.Keys.apiURL: "wss://provider.api",
      Configuration.Keys.logFilter: "info",
      Configuration.Keys.accountSlug: "provider-account",
      Configuration.Keys.actorName: "Provider User",
      Configuration.Keys.connectOnStart: "false",
      Configuration.Keys.startOnLogin: "false",
      Configuration.Keys.internetResourceEnabled: "false",
      Configuration.Keys.userDefaultsMigrated: "true",
    ]
    let tunnelProviderManager = MockTunnelProviderManager()
    tunnelProviderManager.protocolConfiguration = protocolConfiguration
    let vpnConfigurationManager = VPNConfigurationManager(from: tunnelProviderManager)

    try await vpnConfigurationManager.loadConfiguration(
      into: configuration,
      userDefaults: defaults
    )

    let providerConfiguration = try #require(
      protocolConfiguration.providerConfiguration as? [String: String]
    )

    #expect(providerConfiguration[Configuration.Keys.apiURL] == "wss://provider.api")
    #expect(providerConfiguration[Configuration.Keys.logFilter] == "info")
    #expect(
      providerConfiguration[Configuration.forcedKey(for: Configuration.Keys.apiURL)]
        == "wss://forced.api")
    #expect(
      providerConfiguration[Configuration.forcedKey(for: Configuration.Keys.logFilter)]
        == "trace")
    #expect(tunnelProviderManager.saveCount == 1)
  }

  @Test("VPNConfigurationManager rejects wrong providerConfiguration value types")
  @MainActor
  func providerConfigurationRejectsWrongValueTypes() async throws {
    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.providerConfiguration = [
      Configuration.Keys.apiURL: 42
    ]
    let tunnelProviderManager = MockTunnelProviderManager()
    tunnelProviderManager.protocolConfiguration = protocolConfiguration
    let vpnConfigurationManager = VPNConfigurationManager(from: tunnelProviderManager)

    do {
      _ = try vpnConfigurationManager.providerConfiguration()
      Issue.record("Expected savedProtocolConfigurationIsInvalid")
    } catch VPNConfigurationManagerError.savedProtocolConfigurationIsInvalid {
      // Expected
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  // MARK: - Multiple Configuration Instances

  @Test("Provider configuration round trips between Configuration instances")
  @MainActor
  func providerConfigurationRoundTrip() async throws {
    let defaults = UserDefaults.makeTestDefaults()
    let config1 = Configuration(userDefaults: defaults)
    let config2 = Configuration(userDefaults: defaults)

    config1.authURL = "https://shared.url"
    config1.apiURL = "wss://shared.api"
    config1.actorName = "Shared User"
    config1.internetResourceEnabled = true
    let providerConfiguration = config1.toProviderConfiguration()

    config2.loadProviderConfiguration(providerConfiguration)

    #expect(config2.authURL == "https://shared.url")
    #expect(config2.apiURL == "wss://shared.api")
    #expect(config2.actorName == "Shared User")
    #expect(config2.internetResourceEnabled == true)
  }
}

// MARK: - ProviderMessage Codable Tests

@Suite("ProviderMessage Codable Tests")
struct ProviderMessageCodableTests {
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  private func roundTrip(_ message: ProviderMessage) throws -> ProviderMessage {
    let data = try encoder.encode(message)
    return try decoder.decode(ProviderMessage.self, from: data)
  }

  @Test("getEncodedFirezoneId round-trips through JSON")
  func getEncodedFirezoneIdRoundTrip() throws {
    let decoded = try roundTrip(.getEncodedFirezoneId)

    if case .getEncodedFirezoneId = decoded {
      // success
    } else {
      Issue.record("Expected .getEncodedFirezoneId, got \(decoded)")
    }
  }

  @Test("All valueless cases round-trip through JSON")
  func valuelessCasesRoundTrip() throws {
    let cases: [ProviderMessage] = [
      .signOut, .clearLogs, .getLogFolderSize, .exportLogs, .getEncodedFirezoneId,
    ]

    for message in cases {
      let decoded = try roundTrip(message)
      let originalData = try encoder.encode(message)
      let decodedData = try encoder.encode(decoded)
      #expect(originalData == decodedData, "Round-trip failed for \(message)")
    }
  }

  @Test("getState round-trips through JSON")
  func getStateRoundTrip() throws {
    let hash = Data([0x01, 0x02, 0x03])
    let decoded = try roundTrip(.getState(hash))

    if case .getState(let decodedHash) = decoded {
      #expect(decodedHash == hash)
    } else {
      Issue.record("Expected .getState, got \(decoded)")
    }
  }

  @Test("setInternetResourceEnabled round-trips through JSON")
  func setInternetResourceEnabledRoundTrip() throws {
    let decoded = try roundTrip(.setInternetResourceEnabled(true))

    if case .setInternetResourceEnabled(let enabled) = decoded {
      #expect(enabled == true)
    } else {
      Issue.record("Expected .setInternetResourceEnabled, got \(decoded)")
    }
  }
}
