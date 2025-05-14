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

    protocolConfiguration.providerConfiguration = nil
    protocolConfiguration.providerBundleIdentifier = VPNConfigurationManager.bundleIdentifier
    protocolConfiguration.serverAddress = "Firezone" // can be any non-empty string
    manager.localizedDescription = VPNConfigurationManager.bundleDescription
    manager.protocolConfiguration = protocolConfiguration

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()

    self.manager = manager
  }

  init(from manager: NETunnelProviderManager) {
    self.manager = manager
  }

  public static func legacyConfiguration(protocolConfiguration: NETunnelProviderProtocol?) -> [String: String]? {
    guard let protocolConfiguration = protocolConfiguration,
          let providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
    else {
      return nil
    }

    return providerConfiguration
  }

  static func load() async throws -> VPNConfigurationManager? {
    // loadAllFromPreferences() returns list of VPN configurations created by our main app's bundle ID.
    // Since our bundle ID can change (by us), find the one that's current and ignore the others.
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()

    for manager in managers where manager.localizedDescription == bundleDescription {
      return VPNConfigurationManager(from: manager)
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
  func maybeMigrateConfiguration() async throws {
    guard let legacyConfiguration = Self.legacyConfiguration(
      protocolConfiguration: manager.protocolConfiguration as? NETunnelProviderProtocol
    ),
          let session = session()
    else {
      return
    }

    let ipcClient = IPCClient(session: session)

    var migrated = false

    if let apiURL = legacyConfiguration["apiURL"] {
      try await ipcClient.setApiURL(apiURL)
      migrated = true
    }

    if let authURL = legacyConfiguration["authBaseURL"] {
      try await ipcClient.setAuthURL(authURL)
      migrated = true
    }

    if let actorName = legacyConfiguration["actorName"] {
      try await ipcClient.setActorName(actorName)
      migrated = true
    }

    if let accountSlug = legacyConfiguration["accountSlug"] {
      try await ipcClient.setAccountSlug(accountSlug)
      migrated = true
    }

    if let logFilter = legacyConfiguration["logFilter"],
       !logFilter.isEmpty {
      try await ipcClient.setLogFilter(logFilter)
      migrated = true
    }

    if let internetResourceEnabled = legacyConfiguration["internetResourceEnabled"],
       ["false", "true"].contains(internetResourceEnabled) {
      try await ipcClient.setInternetResourceEnabled(internetResourceEnabled == "true")
      migrated = true
    }

    if !migrated { return }

    // Remove fields to prevent confusion if the user sees these in System Settings and wonders why they're stale.
    if let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol {
      protocolConfiguration.providerConfiguration = nil
      protocolConfiguration.serverAddress = "Firezone"
      manager.protocolConfiguration = protocolConfiguration
      try await manager.saveToPreferences()
      try await manager.loadFromPreferences()
    }
  }
}
