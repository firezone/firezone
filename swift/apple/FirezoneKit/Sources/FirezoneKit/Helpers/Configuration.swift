//
//  Configuration.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public class Configuration {
  public static var shared: Configuration = .init()

  public enum Keys {
    static let favoriteResourceIDs = "dev.firezone.config.favoriteResourceIDs"
    static let actorName = "dev.firezone.config.actorName"
    static let authURL = "dev.firezone.config.authURL"
    static let apiURL = "dev.firezone.config.apiURL"
    static let logFilter = "dev.firezone.config.logFilter"
    static let accountSlug = "dev.firezone.config.accountSlug"
    static let internetResourceEnabled = "dev.firezone.config.internetResourceEnabled"
  }

  // We expose all configuration getters to return Optionals so that any consumers of this class may distinguish
  // between a key that's unset vs set.
  public var favoriteResourceIDs: [String]? {
    get { userDefaults.stringArray(forKey: Keys.favoriteResourceIDs) }
    set { userDefaults.set(newValue, forKey: Keys.favoriteResourceIDs) }
  }

  public var actorName: String? {
    get { userDefaults.string(forKey: Keys.actorName) }
    set { userDefaults.set(newValue, forKey: Keys.actorName) }
  }

  public var authURL: URL? {
    get { userDefaults.url(forKey: Keys.authURL) }
    set { userDefaults.set(newValue, forKey: Keys.authURL) }
  }

  public var apiURL: URL? {
    get { userDefaults.url(forKey: Keys.apiURL) }
    set { userDefaults.set(newValue, forKey: Keys.apiURL) }
  }

  public var logFilter: String? {
    get { userDefaults.string(forKey: Keys.logFilter) }
    set { userDefaults.set(newValue, forKey: Keys.logFilter) }
  }

  public var accountSlug: String? {
    get { userDefaults.string(forKey: Keys.accountSlug) }
    set { userDefaults.set(newValue, forKey: Keys.accountSlug) }
  }

  public var internetResourceEnabled: Bool? {
    get { userDefaults.bool(forKey: Keys.internetResourceEnabled) }
    set { userDefaults.set(newValue, forKey: Keys.internetResourceEnabled) }
  }

  // Use these to provide default values at the call site if needed
#if DEBUG
  public static let defaultAuthURL = URL(string: "https://app.firez.one")!
  public static let defaultApiURL = URL(string: "wss://api.firez.one")!
  public static let defaultLogFilter = "debug"
#else
  private let defaultAuthURL = URL(string: "https://app.firezone.dev")!
  private let defaultApiURL = URL(string: "wss://api.firezone.dev")!
  private let defaultLogFilter = "info"
#endif

  private var userDefaults: UserDefaults

  public init(_ userDefaults: UserDefaults? = nil) {
    guard let defaults = userDefaults ?? UserDefaults(suiteName: BundleHelper.appGroupId)
    else {
      fatalError("Could not initialize configuration")
    }

    self.userDefaults = defaults
  }
}
