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
  /// The identifier of the network extension this manager launches; production
  /// derives it from the app bundle, so a test can substitute a fixed one.
  var extensionBundleIdentifier: String { get }

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
  /// The identifier of the network extension the app ships, in one place for every
  /// caller that must name it.
  public static var extensionBundleIdentifier: String {
    // App cannot run without bundle identifier - force unwrap is safe
    // swiftlint:disable:next force_unwrapping
    "\(Bundle.main.bundleIdentifier!).network-extension"
  }

  public var tunnelSession: (any TunnelSessionProtocol)? {
    connection as? NETunnelProviderSession
  }

  public var extensionBundleIdentifier: String { Self.extensionBundleIdentifier }
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

  static let bundleDescription = "Firezone"

  init(from manager: any TunnelProviderManager) {
    self.manager = manager
  }

  // Create and save a new VPN configuration in system Preferences
  public static func create(using factory: TunnelProviderManagerFactory) async throws
    -> VPNConfigurationManager
  {
    let manager = factory.createManager()
    let protocolConfiguration = NETunnelProviderProtocol()

    // Seed with defaults (and any forced overrides) but don't mark migrated;
    // the migrator runs separately and is responsible for flipping the flag.
    protocolConfiguration.providerConfiguration =
      Configuration().toProviderConfiguration(markUserDefaultsMigrated: false)
    protocolConfiguration.providerBundleIdentifier = manager.extensionBundleIdentifier
    protocolConfiguration.serverAddress = "Firezone"  // can be any non-empty string
    manager.localizedDescription = VPNConfigurationManager.bundleDescription
    manager.protocolConfiguration = protocolConfiguration

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()

    return VPNConfigurationManager(from: manager)
  }

  public static func load(using factory: TunnelProviderManagerFactory) async throws
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
  //
  // Saving is skipped when it would change nothing. Writing the VPN preferences
  // invalidates every other process's copy of them, and the app has no way to notice
  // that happened, so a needless save from the headless client leaves the app talking
  // to a configuration the system has already replaced.
  public func enable() async throws {
    guard !manager.isEnabled else { return }

    manager.isEnabled = true
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }

  public func session() -> (any TunnelSessionProtocol)? {
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

  /// Merges `overrides` into the saved provider configuration, leaving every other
  /// stored setting as the GUI left it.
  ///
  /// The UserDefaults migration flag is preserved rather than set: only the GUI may
  /// claim the migration ran, or it would skip it and lose the user's settings.
  public func save(overrides: ProviderOverrides) async throws {
    let stored = try providerConfiguration()
    let configuration = Configuration()
    configuration.loadProviderConfiguration(stored)
    overrides.apply(to: configuration)

    try await save(
      configuration: configuration,
      markUserDefaultsMigrated: stored[Configuration.Keys.userDefaultsMigrated] == "true"
    )
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

  /// What a headless sign-in link is built from, honouring what the app stored and any
  /// MDM override, so it lands where the app's own sign-in would rather than at the
  /// public portal.
  public func signInSettings() throws -> SignInSettings {
    let configuration = Configuration()
    configuration.loadProviderConfiguration(try providerConfiguration())

    return SignInSettings(
      authURL: configuration.authURL,
      accountSlug: configuration.accountSlug
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
