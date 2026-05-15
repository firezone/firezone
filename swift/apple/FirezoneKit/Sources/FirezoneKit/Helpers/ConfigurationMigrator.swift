//
//  ConfigurationMigrator.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

@MainActor
enum ConfigurationMigrator {
  static func migrateUserDefaultsIfNeeded(
    userDefaults: UserDefaults,
    vpnConfigurationManager: VPNConfigurationManager,
    userDefaultsDomain: String? = Bundle.main.bundleIdentifier
  ) async throws {
    let providerConfiguration = try vpnConfigurationManager.providerConfiguration()

    guard providerConfiguration[Configuration.Keys.userDefaultsMigrated] != "true" else {
      return
    }

    let configuration = Configuration(userDefaults: userDefaults)
    configuration.loadProviderConfiguration(providerConfiguration)

    let userDomain =
      userDefaultsDomain.flatMap { userDefaults.persistentDomain(forName: $0) } ?? [:]

    for entry in Configuration.providerEntries {
      if entry.isBool, let value = userDomain[entry.key] as? Bool {
        configuration.setProviderValue(value, forKey: entry.key)
      } else if !entry.isBool,
        let value = userDomain[entry.key] as? String, !value.isEmpty
      {
        configuration.setProviderValue(value, forKey: entry.key)
      }
    }

    try await vpnConfigurationManager.save(configuration: configuration)
    removeLegacyUserDefaults(userDefaults, userDefaultsDomain: userDefaultsDomain)
  }

  private static func removeLegacyUserDefaults(
    _ userDefaults: UserDefaults,
    userDefaultsDomain: String?
  ) {
    let keys = Configuration.providerEntries.map(\.key)

    guard let userDefaultsDomain else {
      for key in keys {
        userDefaults.removeObject(forKey: key)
      }
      return
    }

    var userDomain = userDefaults.persistentDomain(forName: userDefaultsDomain) ?? [:]
    for key in keys {
      userDomain.removeValue(forKey: key)
    }
    userDefaults.setPersistentDomain(userDomain, forName: userDefaultsDomain)
  }
}
