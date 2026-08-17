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
  case managedConfigurationRepairDidNotPersist
  case managedConfigurationRepairLostIdentity
  case savedProtocolConfigurationIsInvalid

  var localizedDescription: String {
    switch self {
    case .managerNotInitialized:
      return "NETunnelProviderManager is not yet initialized. Race condition?"
    case .managedConfigurationRepairDidNotPersist:
      return "The system extension identifier could not be saved to the managed VPN configuration."
    case .managedConfigurationRepairLostIdentity:
      return "The managed VPN configuration lost its X.509 identity while it was being repaired."
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
  /// Whether NetworkExtension loaded this manager from a configuration profile.
  /// There is no public managed flag. Profile-backed managers may omit the provider
  /// bundle identifier, and an identity reference is only installed by MDM in our
  /// configuration because Firezone never writes one itself.
  public let isManaged: Bool

  // App cannot run without bundle identifier - force unwrap is safe
  // swiftlint:disable:next force_unwrapping
  public static let bundleIdentifier: String = "\(Bundle.main.bundleIdentifier!).network-extension"
  static let bundleDescription = "Firezone"

  // Initialize and save a new VPN configuration in system Preferences
  public init(manager: any TunnelProviderManager) async throws {
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
    self.isManaged = false
  }

  init(from manager: any TunnelProviderManager, isManaged: Bool = false) {
    self.manager = manager
    self.isManaged = isManaged
  }

  public static func load(using factory: TunnelProviderManagerFactory) async throws
    -> VPNConfigurationManager?
  {
    try await load(using: factory, providerBundleIdentifier: bundleIdentifier)
  }

  static func load(
    using factory: TunnelProviderManagerFactory,
    providerBundleIdentifier: String
  ) async throws -> VPNConfigurationManager? {
    // MDM is free to choose the user-visible description, so it cannot be used to
    // identify our configuration. The provider bundle identifier is the stable link
    // between both app-created and MDM-installed configurations and this extension.
    let managers = try await factory.loadAllFromPreferences()
    Log.debug("Loaded \(managers.count) tunnel provider configuration(s) from preferences")
    var matchingManagers:
      [(
        manager: any TunnelProviderManager,
        hasIdentityReference: Bool,
        isManaged: Bool
      )] = []

    for manager in managers {
      guard
        let protocolConfiguration =
          manager.protocolConfiguration as? NETunnelProviderProtocol
      else {
        Log.debug(
          "Ignoring tunnel provider configuration with an unexpected protocol type")
        continue
      }

      // For a configuration installed through com.apple.vpn.managed, macOS can
      // omit this property even though loadAllFromPreferences returned it for the
      // containing app identified by VPNSubType. App-created configurations always
      // set the provider identifier in our initializer above.
      if let configuredProviderBundleIdentifier =
        protocolConfiguration.providerBundleIdentifier,
        configuredProviderBundleIdentifier != providerBundleIdentifier
      {
        Log.debug(
          "Ignoring tunnel provider configuration for provider bundle identifier \(configuredProviderBundleIdentifier)"
        )
        continue
      }

      if protocolConfiguration.providerBundleIdentifier == nil {
        Log.debug(
          "Tunnel provider configuration does not expose a provider bundle identifier; accepting it because NetworkExtension associated it with this app"
        )
      }

      matchingManagers.append(
        (
          manager: manager,
          hasIdentityReference: protocolConfiguration.identityReference != nil,
          isManaged: protocolConfiguration.providerBundleIdentifier == nil
            || protocolConfiguration.identityReference != nil
        )
      )
    }

    guard !matchingManagers.isEmpty else {
      Log.info("No Firezone tunnel provider configuration was found")
      return nil
    }

    if matchingManagers.count > 1 {
      Log.warning(
        "Found \(matchingManagers.count) Firezone tunnel provider configurations; preferring one with an X.509 identity reference"
      )
    }

    let selected =
      matchingManagers.first(where: \.hasIdentityReference)
      ?? matchingManagers[0]
    Log.info(
      "Loaded Firezone tunnel provider configuration named \(selected.manager.localizedDescription ?? "<unnamed>"); managed: \(selected.isManaged); X.509 identity reference configured: \(selected.hasIdentityReference)"
    )
    return VPNConfigurationManager(
      from: selected.manager,
      isManaged: selected.isManaged
    )
  }

  /// Loads the current app-created or MDM-installed configuration before creating
  /// one. Callers use this even after presenting installation UI because an MDM
  /// profile may have arrived, or preferences may have changed, in the meantime.
  public static func loadOrCreate(using factory: TunnelProviderManagerFactory) async throws
    -> VPNConfigurationManager
  {
    try await loadOrCreate(using: factory, providerBundleIdentifier: bundleIdentifier)
  }

  static func loadOrCreate(
    using factory: TunnelProviderManagerFactory,
    providerBundleIdentifier: String
  ) async throws -> VPNConfigurationManager {
    if let existing = try await load(
      using: factory,
      providerBundleIdentifier: providerBundleIdentifier
    ) {
      return existing
    }

    Log.info("Creating a new Firezone tunnel provider configuration")
    return try await VPNConfigurationManager(manager: factory.createManager())
  }

  // If another VPN is activated on the system, ours becomes disabled. This is provided so that we may call it before
  // each start attempt in order to reactivate our configuration.
  //
  // Saving is skipped when it would change nothing. Writing the VPN preferences
  // invalidates every other process's copy of them, and the app has no way to notice
  // that happened, so a needless save from the headless client leaves the app talking
  // to a configuration the system has already replaced.
  public func enable() async throws {
    #if os(macOS)
      try await repairManagedSystemExtensionConfigurationIfNeeded()
    #endif

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
    // A generic com.apple.vpn.managed payload produced by some MDMs can associate
    // the configuration with this app through VPNSubType while omitting the
    // provider bundle identifier required to launch a macOS system extension.
    // Repair before Store attaches observers because saving and reloading the
    // manager can replace its effective tunnel session.
    #if os(macOS)
      try await repairManagedSystemExtensionConfigurationIfNeeded()
    #endif

    configuration.setVPNConfigurationManaged(isManaged)

    if isManaged {
      // A configuration profile is the source of truth. Do not migrate legacy
      // UserDefaults into it or normalize its VendorConfig back to preferences.
      configuration.loadProviderConfiguration(try providerConfiguration())
      Log.info("Loaded read-only configuration from the managed VPN profile")
      return
    }

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

  /// The persistent keychain reference installed on the VPN profile by MDM.
  public func identityReference() throws -> Data? {
    guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol
    else {
      throw VPNConfigurationManagerError.savedProtocolConfigurationIsInvalid
    }

    return protocolConfiguration.identityReference
  }

  #if os(macOS)
    /// Adds the system-extension link omitted by some MDM-generated VPN payloads.
    ///
    /// The MDM profile remains the source of truth for every other field. In
    /// particular, its identity reference is preserved rather than rediscovered
    /// through a broad keychain query, which could select the wrong certificate.
    @discardableResult
    func repairManagedSystemExtensionConfigurationIfNeeded(
      providerBundleIdentifier configuredProviderBundleIdentifier: String? = nil
    ) async throws -> Bool {
      guard isManaged else { return false }

      guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol
      else {
        throw VPNConfigurationManagerError.savedProtocolConfigurationIsInvalid
      }

      guard protocolConfiguration.providerBundleIdentifier == nil else { return false }

      guard let identityReference = protocolConfiguration.identityReference else {
        Log.warning(
          "Managed VPN configuration is missing both its provider bundle identifier and X.509 identity reference; leaving it unchanged"
        )
        return false
      }

      // Resolve this only once we know a repair is needed. Bundle.main has no
      // identifier when FirezoneKit is hosted by `swift test`.
      let providerBundleIdentifier =
        configuredProviderBundleIdentifier ?? VPNConfigurationManager.bundleIdentifier

      Log.warning(
        "Managed VPN configuration is missing the provider bundle identifier required for a system extension; repairing it with \(providerBundleIdentifier)"
      )

      protocolConfiguration.providerBundleIdentifier = providerBundleIdentifier
      manager.protocolConfiguration = protocolConfiguration

      do {
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
      } catch {
        Log.error(
          "Failed to repair the managed VPN configuration with the system extension identifier: \(error)"
        )
        throw error
      }

      guard
        let savedProtocolConfiguration =
          manager.protocolConfiguration as? NETunnelProviderProtocol,
        savedProtocolConfiguration.providerBundleIdentifier == providerBundleIdentifier
      else {
        Log.error(
          "The system extension identifier did not persist after reloading the managed VPN configuration"
        )
        throw VPNConfigurationManagerError.managedConfigurationRepairDidNotPersist
      }

      guard savedProtocolConfiguration.identityReference == identityReference else {
        Log.error(
          "The X.509 identity reference changed while repairing the managed VPN configuration"
        )
        throw VPNConfigurationManagerError.managedConfigurationRepairLostIdentity
      }

      Log.info(
        "Repaired and reloaded the managed VPN configuration with the Firezone system extension identifier; X.509 identity reference preserved"
      )
      return true
    }

  #endif

  func save(providerConfiguration newProviderConfiguration: [String: String]) async throws {
    guard !isManaged else {
      Log.warning("Skipping provider configuration write because the VPN profile is MDM-managed")
      return
    }

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
