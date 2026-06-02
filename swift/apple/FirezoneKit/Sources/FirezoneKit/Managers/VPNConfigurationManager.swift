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

// MARK: - Protocols

@MainActor
public protocol TunnelProviderManager: AnyObject {
  var isEnabled: Bool { get set }
  var localizedDescription: String? { get set }
  var protocolConfiguration: NEVPNProtocol? { get set }
  /// The tunnel session backing this manager, if its connection is a provider
  /// session. Mockable counterpart of the concrete, un-mockable `connection`.
  var tunnelSession: (any TunnelSessionProtocol)? { get }

  func saveToPreferences() async throws
  func loadFromPreferences() async throws
}

@MainActor
public protocol TunnelProviderManagerFactory {
  func loadAllFromPreferences() async throws -> [any TunnelProviderManager]
  func createManager() -> any TunnelProviderManager
}

// MARK: - NetworkExtension Conformances

extension NETunnelProviderManager: TunnelProviderManager {
  public var tunnelSession: (any TunnelSessionProtocol)? {
    connection as? NETunnelProviderSession
  }
}

@MainActor
public final class NETunnelProviderManagerFactory: TunnelProviderManagerFactory {
  public init() {}

  public func loadAllFromPreferences() async throws -> [any TunnelProviderManager] {
    try await NETunnelProviderManager.loadAllFromPreferences()
  }

  public func createManager() -> any TunnelProviderManager {
    NETunnelProviderManager()
  }
}

// MARK: - VPNConfigurationManager

enum VPNConfigurationManagerError: Error {
  case managerNotInitialized
  case savedProtocolConfigurationIsInvalid

  var localizedDescription: String {
    switch self {
    case .managerNotInitialized:
      return "NETunnelProviderManager is not yet initialized. Race condition?"
    case .savedProtocolConfigurationIsInvalid:
      return "Saved protocol configuration is invalid. Check types?"
    }
  }
}

// NEVPNManager callbacks are documented to arrive on main thread;
// we isolate to @MainActor to align with this design.
@MainActor
public final class VPNConfigurationManager {
  let manager: any TunnelProviderManager

  // App cannot run without bundle identifier - force unwrap is safe
  // swiftlint:disable:next force_unwrapping
  public static let bundleIdentifier: String = "\(Bundle.main.bundleIdentifier!).network-extension"
  static let bundleDescription = "Firezone"

  // Initialize and save a new VPN configuration in system Preferences
  init(manager: any TunnelProviderManager) async throws {
    let protocolConfiguration = NETunnelProviderProtocol()

    // Seed with defaults (and any forced overrides) but don't mark migrated;
    // the migrator runs separately and is responsible for flipping the flag.
    protocolConfiguration.providerConfiguration =
      Configuration().toProviderConfiguration(markUserDefaultsMigrated: false)
    protocolConfiguration.providerBundleIdentifier = VPNConfigurationManager.bundleIdentifier
    protocolConfiguration.serverAddress = "Firezone"  // can be any non-empty string
    manager.localizedDescription = VPNConfigurationManager.bundleDescription
    manager.protocolConfiguration = protocolConfiguration

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()

    self.manager = manager
  }

  init(from manager: any TunnelProviderManager) {
    self.manager = manager
  }

  static func load(using factory: TunnelProviderManagerFactory) async throws
    -> VPNConfigurationManager?
  {
    // loadAllFromPreferences() returns list of VPN configurations created by our main app's bundle ID.
    // Since our bundle ID can change (by us), find the one that's current and ignore the others.
    let managers = try await factory.loadAllFromPreferences()

    for manager in managers where manager.localizedDescription == bundleDescription {
      return VPNConfigurationManager(from: manager)
    }

    return nil
  }

  // If another VPN is activated on the system, ours becomes disabled. This is provided so that we may call it before
  // each start attempt in order to reactivate our configuration.
  func enable() async throws {
    manager.isEnabled = true
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }

  func session() -> (any TunnelSessionProtocol)? {
    return manager.tunnelSession
  }

  func loadConfiguration(into configuration: Configuration, userDefaults: UserDefaults) async throws
  {
    try await ConfigurationMigrator.migrateUserDefaultsIfNeeded(
      userDefaults: userDefaults,
      vpnConfigurationManager: self
    )

    // Pick up stored config and refresh cached forced overrides if MDM changed
    // since the last GUI launch. When the migrator just ran this is a no-op.
    let stored = try providerConfiguration()
    configuration.loadProviderConfiguration(stored)

    let refreshed = configuration.toProviderConfiguration()
    if stored != refreshed {
      try await save(providerConfiguration: refreshed)
    }
  }

  func save(
    configuration: Configuration,
    markUserDefaultsMigrated: Bool = true
  ) async throws {
    try await save(
      providerConfiguration: configuration.toProviderConfiguration(
        markUserDefaultsMigrated: markUserDefaultsMigrated
      )
    )
  }

  func providerConfiguration() throws -> [String: String] {
    guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol
    else {
      throw VPNConfigurationManagerError.savedProtocolConfigurationIsInvalid
    }

    guard let rawProviderConfiguration = protocolConfiguration.providerConfiguration else {
      return [:]
    }

    guard let providerConfiguration = rawProviderConfiguration as? [String: String] else {
      throw VPNConfigurationManagerError.savedProtocolConfigurationIsInvalid
    }

    return providerConfiguration
  }

  func save(providerConfiguration newProviderConfiguration: [String: String]) async throws {
    guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol
    else {
      throw VPNConfigurationManagerError.savedProtocolConfigurationIsInvalid
    }

    let providerConfiguration: [String: String]
    if let rawProviderConfiguration = protocolConfiguration.providerConfiguration {
      guard let typedProviderConfiguration = rawProviderConfiguration as? [String: String] else {
        throw VPNConfigurationManagerError.savedProtocolConfigurationIsInvalid
      }
      providerConfiguration = typedProviderConfiguration
    } else {
      providerConfiguration = [:]
    }

    if providerConfiguration == newProviderConfiguration
      && protocolConfiguration.serverAddress == "Firezone"
    {
      return
    }

    protocolConfiguration.providerConfiguration = newProviderConfiguration
    protocolConfiguration.serverAddress = "Firezone"
    manager.protocolConfiguration = protocolConfiguration

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }
}
