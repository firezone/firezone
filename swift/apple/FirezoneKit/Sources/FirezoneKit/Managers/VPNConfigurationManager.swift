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

public class VPNConfigurationManager {
  enum Error: Swift.Error {
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

  public enum Keys {
    static let actorName = "actorName"
    static let authBaseURL = "authBaseURL"
    static let apiURL = "apiURL"
    public static let accountSlug = "accountSlug"
    public static let logFilter = "logFilter"
    public static let internetResourceEnabled = "internetResourceEnabled"
  }

  // Persists our tunnel settings
  var manager: NETunnelProviderManager?

  public static let bundleIdentifier: String = "\(Bundle.main.bundleIdentifier!).network-extension"
  static let bundleDescription = "Firezone"

  // Initialize and save a new VPN configuration in system Preferences
  static func create() async throws -> NETunnelProviderManager {
    let protocolConfiguration = NETunnelProviderProtocol()
    let manager = NETunnelProviderManager()
    let settings = Settings.defaultValue

    protocolConfiguration.providerConfiguration = settings.toProviderConfiguration()
    protocolConfiguration.providerBundleIdentifier = VPNConfigurationManager.bundleIdentifier
    protocolConfiguration.serverAddress = settings.apiURL
    manager.localizedDescription = bundleDescription
    manager.protocolConfiguration = protocolConfiguration

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()

    return manager
  }

  static func loadFromPreferences() async throws -> NETunnelProviderManager? {
    // loadAllFromPreferences() returns list of VPN configurations created by our main app's bundle ID.
    // Since our bundle ID can change (by us), find the one that's current and ignore the others.
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()

    Log.log("\(#function): \(managers.count) tunnel managers found")
    for manager in managers where manager.localizedDescription == bundleDescription {
      return manager
    }

    return nil
  }

  func actorName() throws -> String? {
    guard let manager
    else {
      throw Error.managerNotInitialized
    }

    guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
          let providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
    else {
      throw Error.savedProtocolConfigurationIsInvalid
    }

    return providerConfiguration[Keys.actorName]
  }

  func internetResourceEnabled() throws -> Bool? {
    guard let manager
    else {
      throw Error.managerNotInitialized
    }

    guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
          let providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
    else {
      throw Error.savedProtocolConfigurationIsInvalid
    }

    // TODO: Store Bool directly in VPN Configuration
    if providerConfiguration[Keys.internetResourceEnabled] == "true" {
      return true
    }

    if providerConfiguration[Keys.internetResourceEnabled] == "false" {
      return false
    }

    return nil
  }

  func save(authResponse: AuthResponse) async throws {
    guard let manager
    else {
      throw Error.managerNotInitialized
    }

    guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
          var providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
    else {
      throw Error.savedProtocolConfigurationIsInvalid
    }

    providerConfiguration[Keys.actorName] = authResponse.actorName
    providerConfiguration[Keys.accountSlug] = authResponse.accountSlug

    // Configure our Telemetry environment, closing if we're definitely not running against Firezone infrastructure.
    Telemetry.accountSlug = providerConfiguration[Keys.accountSlug]

    protocolConfiguration.providerConfiguration = providerConfiguration
    manager.protocolConfiguration = protocolConfiguration

    // Always set this to true when starting the tunnel in case our tunnel was disabled by the system.
    manager.isEnabled = true

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }

  func save(settings: Settings) async throws {
    guard let manager
    else {
      throw Error.managerNotInitialized
    }

    guard let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
          let providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
    else {
      throw Error.savedProtocolConfigurationIsInvalid
    }

    var newProviderConfiguration = settings.toProviderConfiguration()

    // Don't clobber existing actorName
    newProviderConfiguration[Keys.actorName] = providerConfiguration[Keys.actorName]

    protocolConfiguration.providerConfiguration = newProviderConfiguration
    protocolConfiguration.serverAddress = settings.apiURL
    manager.protocolConfiguration = protocolConfiguration

    manager.isEnabled = true

    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()

    // Reconfigure our Telemetry environment in case it changed
    Telemetry.setEnvironmentOrClose(settings.apiURL)
  }
}
