//
//  Configuration.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  App configuration facade.
//
//  All user-editable settings live in the VPN provider configuration so only the
//  host app and provider can write to them. UserDefaults is used only for MDM:
//  read-only managed values (hideResourceList, supportURL, …) and forced
//  overrides of tunnel keys, both deployed via .mobileconfig profiles. Forced
//  overrides are also cached in providerConfiguration under a "forced." prefix
//  so the network extension can apply them after restart without the GUI.

import Combine
import Foundation

public enum ConfigurationDefaults {
  #if DEBUG
    public static let authURL = "https://app.firez.one"
    public static let apiURL = "wss://api.firez.one"
    public static let logFilter = "debug"
  #else
    public static let authURL = "https://app.firezone.dev"
    public static let apiURL = "wss://api.firezone.dev"
    public static let logFilter = "info"
  #endif

  public static let accountSlug = ""
  public static let actorName = "Unknown user"
  public static let supportURL = "https://www.firezone.dev/support"
  public static let connectOnStart = false
  public static let startOnLogin = false
  public static let disableUpdateCheck = false
  public static let internetResourceEnabled = false
}

@MainActor
public class Configuration: ObservableObject {
  static let shared = Configuration()

  // Forced overrides are cached in providerConfiguration as "forced.<key>".
  nonisolated public static let forcedPrefix = "forced."
  nonisolated public static func forcedKey(for key: String) -> String {
    "\(forcedPrefix)\(key)"
  }

  public enum Keys {
    public static let authURL = "authURL"
    public static let apiURL = "apiURL"
    public static let logFilter = "logFilter"
    public static let accountSlug = "accountSlug"
    public static let actorName = "actorName"
    public static let internetResourceEnabled = "internetResourceEnabled"
    public static let hideAdminPortalMenuItem = "hideAdminPortalMenuItem"
    public static let hideResourceList = "hideResourceList"
    public static let connectOnStart = "connectOnStart"
    public static let startOnLogin = "startOnLogin"
    public static let disableUpdateCheck = "disableUpdateCheck"
    public static let supportURL = "supportURL"
    public static let userDefaultsMigrated = "userDefaultsMigrated"
  }

  // Each entry describes a key persisted to providerConfiguration. The getters
  // additionally honor an MDM forced value (UserDefaults.objectIsForced) for the
  // is*Forced properties below, regardless of whether the key is forwarded to
  // the network extension.
  struct ProviderEntry: Sendable {
    let key: String
    let defaultString: String
    let isBool: Bool
  }

  nonisolated static let providerEntries: [ProviderEntry] = [
    ProviderEntry(key: Keys.authURL, defaultString: ConfigurationDefaults.authURL, isBool: false),
    ProviderEntry(key: Keys.apiURL, defaultString: ConfigurationDefaults.apiURL, isBool: false),
    ProviderEntry(
      key: Keys.logFilter, defaultString: ConfigurationDefaults.logFilter, isBool: false),
    ProviderEntry(
      key: Keys.accountSlug, defaultString: ConfigurationDefaults.accountSlug, isBool: false),
    ProviderEntry(
      key: Keys.actorName, defaultString: ConfigurationDefaults.actorName, isBool: false),
    ProviderEntry(
      key: Keys.connectOnStart, defaultString: string(ConfigurationDefaults.connectOnStart),
      isBool: true),
    ProviderEntry(
      key: Keys.startOnLogin, defaultString: string(ConfigurationDefaults.startOnLogin),
      isBool: true),
    ProviderEntry(
      key: Keys.internetResourceEnabled,
      defaultString: string(ConfigurationDefaults.internetResourceEnabled), isBool: true),
  ]

  // Subset of provider entries whose MDM forced values are cached in
  // providerConfiguration as "forced.<key>" so the network extension can apply
  // them at tunnel start without having to contact the GUI.
  nonisolated static let forwardedForcedKeys: Set<String> = [
    Keys.apiURL, Keys.logFilter, Keys.accountSlug,
  ]

  private var cancellables = Set<AnyCancellable>()
  private let internetResourceEnabledSubject = PassthroughSubject<Bool, Never>()

  private(set) var publishedInternetResourceEnabled = false
  private(set) var publishedHideAdminPortalMenuItem = false
  private(set) var publishedHideResourceList = false

  var internetResourceEnabledPublisher: AnyPublisher<Bool, Never> {
    internetResourceEnabledSubject.eraseToAnyPublisher()
  }

  var isAuthURLForced: Bool { defaults.objectIsForced(forKey: Keys.authURL) }
  var isApiURLForced: Bool { defaults.objectIsForced(forKey: Keys.apiURL) }
  var isLogFilterForced: Bool { defaults.objectIsForced(forKey: Keys.logFilter) }
  var isAccountSlugForced: Bool { defaults.objectIsForced(forKey: Keys.accountSlug) }
  var isConnectOnStartForced: Bool { defaults.objectIsForced(forKey: Keys.connectOnStart) }
  var isStartOnLoginForced: Bool { defaults.objectIsForced(forKey: Keys.startOnLogin) }

  var authURL: String {
    get { effectiveString(Keys.authURL, default: ConfigurationDefaults.authURL) }
    set { setProviderValue(newValue, forKey: Keys.authURL) }
  }
  var apiURL: String {
    get { effectiveString(Keys.apiURL, default: ConfigurationDefaults.apiURL) }
    set { setProviderValue(newValue, forKey: Keys.apiURL) }
  }
  var logFilter: String {
    get { effectiveString(Keys.logFilter, default: ConfigurationDefaults.logFilter) }
    set { setProviderValue(newValue, forKey: Keys.logFilter) }
  }
  var accountSlug: String {
    get { effectiveString(Keys.accountSlug, default: ConfigurationDefaults.accountSlug) }
    set { setProviderValue(newValue, forKey: Keys.accountSlug) }
  }
  var actorName: String {
    get { providerString(Keys.actorName, default: ConfigurationDefaults.actorName) }
    set { setProviderValue(newValue, forKey: Keys.actorName) }
  }
  var connectOnStart: Bool {
    get { effectiveBool(Keys.connectOnStart, default: ConfigurationDefaults.connectOnStart) }
    set { setProviderValue(newValue, forKey: Keys.connectOnStart) }
  }
  var startOnLogin: Bool {
    get { effectiveBool(Keys.startOnLogin, default: ConfigurationDefaults.startOnLogin) }
    set { setProviderValue(newValue, forKey: Keys.startOnLogin) }
  }
  var internetResourceEnabled: Bool {
    get {
      providerBool(
        Keys.internetResourceEnabled, default: ConfigurationDefaults.internetResourceEnabled)
    }
    set { setProviderValue(newValue, forKey: Keys.internetResourceEnabled) }
  }

  var hideAdminPortalMenuItem: Bool { managedBool(Keys.hideAdminPortalMenuItem) }
  var hideResourceList: Bool { managedBool(Keys.hideResourceList) }
  var disableUpdateCheck: Bool { managedBool(Keys.disableUpdateCheck) }
  var supportURL: String {
    defaults.string(forKey: Keys.supportURL) ?? ConfigurationDefaults.supportURL
  }

  private var defaults: UserDefaults
  private var providerConfiguration: [String: String]

  // swiftlint:disable:next no_userdefaults_standard - DI entry point
  init(userDefaults: UserDefaults = UserDefaults.standard) {
    defaults = userDefaults
    providerConfiguration = [:]

    self.publishedInternetResourceEnabled = internetResourceEnabled
    self.publishedHideAdminPortalMenuItem = hideAdminPortalMenuItem
    self.publishedHideResourceList = hideResourceList

    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.handleConfigurationChanged() }
      .store(in: &cancellables)
  }

  func loadProviderConfiguration(_ providerConfiguration: [String: String]) {
    guard self.providerConfiguration != providerConfiguration else { return }
    self.providerConfiguration = providerConfiguration
    handleConfigurationChanged()
  }

  func toProviderConfiguration(markUserDefaultsMigrated: Bool = true) -> [String: String] {
    var result: [String: String] = [:]

    for entry in Self.providerEntries {
      result[entry.key] = providerConfiguration[entry.key] ?? entry.defaultString
    }

    // Cache MDM forced overrides so the network extension can apply them without the GUI.
    for (key, value) in forcedConfiguration() {
      result[Self.forcedKey(for: key)] = value
    }

    if markUserDefaultsMigrated {
      result[Keys.userDefaultsMigrated] = "true"
    }

    return result
  }

  func forcedConfiguration() -> [String: String] {
    var result: [String: String] = [:]
    for entry in Self.providerEntries where Self.forwardedForcedKeys.contains(entry.key) {
      guard defaults.objectIsForced(forKey: entry.key) else { continue }
      if entry.isBool {
        result[entry.key] = Self.string(defaults.bool(forKey: entry.key))
      } else if let value = defaults.string(forKey: entry.key) {
        result[entry.key] = value
      }
    }
    return result
  }

  private func effectiveString(_ key: String, default defaultValue: String) -> String {
    if defaults.objectIsForced(forKey: key), let value = defaults.string(forKey: key) {
      return value
    }
    return providerString(key, default: defaultValue)
  }

  private func providerString(_ key: String, default defaultValue: String) -> String {
    providerConfiguration[key] ?? defaultValue
  }

  private func effectiveBool(_ key: String, default defaultValue: Bool) -> Bool {
    if defaults.objectIsForced(forKey: key) { return defaults.bool(forKey: key) }
    return providerBool(key, default: defaultValue)
  }

  private func providerBool(_ key: String, default defaultValue: Bool) -> Bool {
    Self.bool(providerConfiguration[key], default: defaultValue)
  }

  private func managedBool(_ key: String) -> Bool {
    guard defaults.object(forKey: key) != nil else { return false }
    return defaults.bool(forKey: key)
  }

  func setProviderValue(_ value: String, forKey key: String) {
    guard providerConfiguration[key] != value else { return }
    providerConfiguration[key] = value
    handleConfigurationChanged()
  }

  func setProviderValue(_ value: Bool, forKey key: String) {
    setProviderValue(Self.string(value), forKey: key)
  }

  private func handleConfigurationChanged() {
    let previousInternetResourceEnabled = publishedInternetResourceEnabled

    publishedInternetResourceEnabled = internetResourceEnabled
    publishedHideAdminPortalMenuItem = hideAdminPortalMenuItem
    publishedHideResourceList = hideResourceList

    objectWillChange.send()

    if previousInternetResourceEnabled != publishedInternetResourceEnabled {
      internetResourceEnabledSubject.send(publishedInternetResourceEnabled)
    }
  }

  nonisolated public static func bool(_ value: String?, default defaultValue: Bool) -> Bool {
    switch value {
    case "true": return true
    case "false": return false
    default: return defaultValue
    }
  }

  nonisolated static func string(_ value: Bool) -> String { value ? "true" : "false" }
}

extension Dictionary where Key == String, Value == String {
  /// Returns the forced override for `key` if present, else the plain value.
  public func effectiveValue(forKey key: String) -> String? {
    self[Configuration.forcedKey(for: key)] ?? self[key]
  }
}
