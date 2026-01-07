//
//  ConfigurationTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import Testing

@testable import FirezoneKit

@Suite("Configuration Tests")
struct ConfigurationTests {

  // Use a unique suite name for test isolation
  private static let testSuiteName = "dev.firezone.firezone.tests.\(UUID().uuidString)"

  private func makeTestDefaults() -> UserDefaults {
    let defaults = UserDefaults(suiteName: Self.testSuiteName)!
    // Clear any existing values
    defaults.removePersistentDomain(forName: Self.testSuiteName)
    return defaults
  }

  // MARK: - Default Values

  @Test("Returns default values when UserDefaults is empty")
  @MainActor
  func defaultValues() async {
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    #expect(config.authURL == Configuration.defaultAuthURL)
    #expect(config.apiURL == Configuration.defaultApiURL)
    #expect(config.logFilter == Configuration.defaultLogFilter)
    #expect(config.accountSlug == Configuration.defaultAccountSlug)
    #expect(config.supportURL == Configuration.defaultSupportURL)
    #expect(config.connectOnStart == Configuration.defaultConnectOnStart)
    #expect(config.startOnLogin == Configuration.defaultStartOnLogin)
    #expect(config.disableUpdateCheck == Configuration.defaultDisableUpdateCheck)
    #expect(config.internetResourceEnabled == false)
    #expect(config.hideAdminPortalMenuItem == false)
    #expect(config.hideResourceList == false)
  }

  @Test("String defaults use fallback when key is missing")
  @MainActor
  func stringDefaultsFallback() async {
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    // Verify the fallback logic works - string(forKey:) returns nil, so ?? kicks in
    // These assertions verify the actual values, not just self-comparison
    #expect(config.authURL.starts(with: "https://app.fire"))
    #expect(config.apiURL.starts(with: "wss://api.fire"))
    #expect(config.supportURL == "https://firezone.dev/support")
    #expect(config.accountSlug == "")

    // Confirm nothing was written to UserDefaults (defaults are computed, not stored)
    #expect(defaults.string(forKey: "authURL") == nil)
    #expect(defaults.string(forKey: "apiURL") == nil)
    #expect(defaults.string(forKey: "supportURL") == nil)
  }

  // MARK: - Read/Write Properties

  @Test("String properties persist to UserDefaults")
  @MainActor
  func stringPropertiesPersist() async {
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    config.authURL = "https://custom.auth.url"
    config.apiURL = "wss://custom.api.url"
    config.logFilter = "trace"
    config.accountSlug = "test-slug"
    config.supportURL = "https://custom.support.url"

    #expect(config.authURL == "https://custom.auth.url")
    #expect(config.apiURL == "wss://custom.api.url")
    #expect(config.logFilter == "trace")
    #expect(config.accountSlug == "test-slug")
    #expect(config.supportURL == "https://custom.support.url")

    // Verify values are actually in UserDefaults
    #expect(defaults.string(forKey: "authURL") == "https://custom.auth.url")
    #expect(defaults.string(forKey: "apiURL") == "wss://custom.api.url")
    #expect(defaults.string(forKey: "logFilter") == "trace")
    #expect(defaults.string(forKey: "accountSlug") == "test-slug")
    #expect(defaults.string(forKey: "supportURL") == "https://custom.support.url")
  }

  @Test("Boolean properties persist to UserDefaults")
  @MainActor
  func booleanPropertiesPersist() async {
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    config.connectOnStart = true
    config.startOnLogin = true
    config.disableUpdateCheck = true
    config.internetResourceEnabled = true
    config.hideAdminPortalMenuItem = true
    config.hideResourceList = true

    #expect(config.connectOnStart == true)
    #expect(config.startOnLogin == true)
    #expect(config.disableUpdateCheck == true)
    #expect(config.internetResourceEnabled == true)
    #expect(config.hideAdminPortalMenuItem == true)
    #expect(config.hideResourceList == true)

    // Verify values are actually in UserDefaults
    #expect(defaults.bool(forKey: "connectOnStart") == true)
    #expect(defaults.bool(forKey: "startOnLogin") == true)
    #expect(defaults.bool(forKey: "disableUpdateCheck") == true)
    #expect(defaults.bool(forKey: "internetResourceEnabled") == true)
    #expect(defaults.bool(forKey: "hideAdminPortalMenuItem") == true)
    #expect(defaults.bool(forKey: "hideResourceList") == true)
  }

  // MARK: - TunnelConfiguration

  @Test("toTunnelConfiguration returns correct values")
  @MainActor
  func tunnelConfiguration() async {
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    config.apiURL = "wss://test.api"
    config.accountSlug = "test-account"
    config.logFilter = "warn"
    config.internetResourceEnabled = true

    let tunnelConfig = config.toTunnelConfiguration()

    #expect(tunnelConfig.apiURL == "wss://test.api")
    #expect(tunnelConfig.accountSlug == "test-account")
    #expect(tunnelConfig.logFilter == "warn")
    #expect(tunnelConfig.internetResourceEnabled == true)
  }

  @Test("TunnelConfiguration equality")
  func tunnelConfigurationEquality() {
    let config1 = TunnelConfiguration(
      apiURL: "wss://api",
      accountSlug: "slug",
      logFilter: "info",
      internetResourceEnabled: true
    )

    let config2 = TunnelConfiguration(
      apiURL: "wss://api",
      accountSlug: "slug",
      logFilter: "info",
      internetResourceEnabled: true
    )

    let config3 = TunnelConfiguration(
      apiURL: "wss://different",
      accountSlug: "slug",
      logFilter: "info",
      internetResourceEnabled: true
    )

    #expect(config1 == config2)
    #expect(config1 != config3)
  }

  // MARK: - Published Properties Initialization

  @Test("Published properties initialized from UserDefaults")
  @MainActor
  func publishedPropertiesInitialized() async {
    let defaults = makeTestDefaults()

    // Set values before creating Configuration
    defaults.set(true, forKey: "internetResourceEnabled")
    defaults.set(true, forKey: "hideAdminPortalMenuItem")
    defaults.set(true, forKey: "hideResourceList")

    let config = Configuration(userDefaults: defaults)

    // Published properties should be initialized from UserDefaults
    #expect(config.publishedInternetResourceEnabled == true)
    #expect(config.publishedHideAdminPortalMenuItem == true)
    #expect(config.publishedHideResourceList == true)
  }

  // MARK: - Reactive Published Property Updates

  @Test("Published properties update when regular properties change")
  @MainActor
  func publishedPropertiesUpdateReactively() async throws {
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    // Initially false
    #expect(config.publishedInternetResourceEnabled == false)

    // Trigger the change
    config.internetResourceEnabled = true

    // Poll for the update with timeout - the notification is async via Combine
    let deadline = Date().addingTimeInterval(1.0)
    while config.publishedInternetResourceEnabled == false && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(config.publishedInternetResourceEnabled == true)
  }

  @Test("Published properties update when UserDefaults changes externally")
  @MainActor
  func publishedPropertiesUpdateFromExternalChanges() async throws {
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    // Initially false
    #expect(config.publishedInternetResourceEnabled == false)

    // Simulate an external change (e.g., from MDM or another process)
    defaults.set(true, forKey: "internetResourceEnabled")

    // Wait for notification to propagate
    try await Task.sleep(for: .milliseconds(50))

    // Published property should reflect the external change
    #expect(config.publishedInternetResourceEnabled == true)
  }

  @Test("objectWillChange emits when properties change")
  @MainActor
  func objectWillChangeEmits() async throws {
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)

    var emissionCount = 0
    let cancellable = config.objectWillChange.sink { _ in
      emissionCount += 1
    }

    // Trigger a change
    config.internetResourceEnabled = true

    // Wait for notification to propagate
    try await Task.sleep(for: .milliseconds(50))

    #expect(emissionCount >= 1, "objectWillChange should have emitted at least once")

    // Keep cancellable alive until end of test
    _ = cancellable
  }

  // MARK: - Reading Pre-existing Values

  @Test("Configuration reads pre-existing UserDefaults values")
  @MainActor
  func readsPreExistingValues() async {
    let defaults = makeTestDefaults()

    // Set values before creating Configuration
    defaults.set("https://preset.auth", forKey: "authURL")
    defaults.set("wss://preset.api", forKey: "apiURL")
    defaults.set(true, forKey: "connectOnStart")
    defaults.set(true, forKey: "internetResourceEnabled")

    let config = Configuration(userDefaults: defaults)

    #expect(config.authURL == "https://preset.auth")
    #expect(config.apiURL == "wss://preset.api")
    #expect(config.connectOnStart == true)
    #expect(config.internetResourceEnabled == true)

    // Published properties should also reflect pre-existing values
    #expect(config.publishedInternetResourceEnabled == true)
  }

  // MARK: - Multiple Configuration Instances

  @Test("Multiple Configuration instances share same UserDefaults")
  @MainActor
  func sharedUserDefaults() async throws {
    let defaults = makeTestDefaults()
    let config1 = Configuration(userDefaults: defaults)
    let config2 = Configuration(userDefaults: defaults)

    config1.authURL = "https://shared.url"

    // config2 should see the same value (reading from same UserDefaults)
    #expect(config2.authURL == "https://shared.url")
  }
}

// MARK: - TunnelConfiguration Codable Tests

@Suite("TunnelConfiguration Codable Tests")
struct TunnelConfigurationCodableTests {

  @Test("TunnelConfiguration encodes and decodes correctly")
  func encodeDecode() throws {
    let original = TunnelConfiguration(
      apiURL: "wss://api.example.com",
      accountSlug: "my-account",
      logFilter: "debug",
      internetResourceEnabled: true
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TunnelConfiguration.self, from: data)

    #expect(decoded == original)
  }

  @Test("TunnelConfiguration decodes from JSON string")
  func decodeFromJSON() throws {
    let json = """
      {
        "apiURL": "wss://test.api",
        "accountSlug": "test-slug",
        "logFilter": "info",
        "internetResourceEnabled": false
      }
      """

    let decoder = JSONDecoder()
    let config = try decoder.decode(TunnelConfiguration.self, from: json.data(using: .utf8)!)

    #expect(config.apiURL == "wss://test.api")
    #expect(config.accountSlug == "test-slug")
    #expect(config.logFilter == "info")
    #expect(config.internetResourceEnabled == false)
  }
}
