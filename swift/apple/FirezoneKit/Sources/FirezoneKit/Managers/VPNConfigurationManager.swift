//
//  VPNConfigurationManager.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//
//  Abstracts the nitty gritty of loading and saving to our
//  VPN configuration in system preferences.

import Foundation
import NetworkExtension

enum VPNConfigurationManagerError: Error {
  case managerNotInitialized

  var localizedDescription: String {
    switch self {
    case .managerNotInitialized:
      return "NETunnelProviderManager is not yet initialized. Race condition?"
    }
  }
}

public class VPNConfigurationManager {
  // Persists our tunnel settings
  let manager: NETunnelProviderManager

  public static let bundleIdentifier: String = "\(Bundle.main.bundleIdentifier!).network-extension"
  static let bundleDescription = "Firezone"

  // Initialize and save a new VPN configuration in system Preferences
  init() async throws {
    let protocolConfiguration = NETunnelProviderProtocol()
    let manager = NETunnelProviderManager()

    protocolConfiguration.providerBundleIdentifier = VPNConfigurationManager.bundleIdentifier
    protocolConfiguration.serverAddress = "127.0.0.1" // can be anything
    manager.localizedDescription = VPNConfigurationManager.bundleDescription
    manager.protocolConfiguration = protocolConfiguration

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()

    self.manager = manager
  }

  init(from manager: NETunnelProviderManager) {
    self.manager = manager
  }

  static func load() async throws -> VPNConfigurationManager? {
    // loadAllFromPreferences() returns list of VPN configurations created by our main app's bundle ID.
    // Since our bundle ID can change (by us), find the one that's current and ignore the others.
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()

    for manager in managers where manager.localizedDescription == bundleDescription {
      let ours = VPNConfigurationManager(from: manager)
      try await ours.migrateConfigurationIfNeeded()
      return ours
    }

    return nil
  }

  // If another VPN is activated on the system, ours becomes disabled. This is provided so that we may call it before
  // each start attempt in order to reactivate our configuration.
  func enableConfiguration() async throws {
    manager.isEnabled = true
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }

  func session() -> NETunnelProviderSession? {
    return manager.connection as? NETunnelProviderSession
  }

  // Firezone 1.4.14 and below stored some app configuration in the VPN provider configuration fields. This has since
  // been moved to a dedicated UserDefaults-backed persistent store.
  func migrateConfigurationIfNeeded() async throws {
    guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
          let providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
    else { return }

    var migrated = false

    if let apiURLString = providerConfiguration["apiURL"],
       let apiURL = URL(string: apiURLString),
       apiURL.host != nil,
       ["wss", "ws"].contains(apiURL.scheme) {
      Configuration.shared.apiURL = apiURL
      migrated = true
    }

    if let authURLString = providerConfiguration["authBaseURL"],
       let authURL = URL(string: authURLString),
       authURL.host != nil,
       ["https", "http"].contains(authURL.scheme) {
      Configuration.shared.authURL = authURL
      migrated = true
    }

    if let actorName = providerConfiguration["actorName"] {
      Configuration.shared.actorName = actorName
      migrated = true
    }

    if let accountSlug = providerConfiguration["accountSlug"] {
      Configuration.shared.accountSlug = accountSlug
      migrated = true
    }

    if let logFilter = providerConfiguration["logFilter"],
       !logFilter.isEmpty {
      Configuration.shared.logFilter = logFilter
      migrated = true
    }

    if let internetResourceEnabled = providerConfiguration["internetResourceEnabled"],
       ["false", "true"].contains(internetResourceEnabled) {
      Configuration.shared.internetResourceEnabled = internetResourceEnabled == "true"
      migrated = true
    }

    if !migrated { return }

    // Remove fields to prevent confusion if the user sees these in System Settings and wonders why they're stale.
    protocolConfiguration.providerConfiguration = nil
    manager.protocolConfiguration = protocolConfiguration
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }
}
