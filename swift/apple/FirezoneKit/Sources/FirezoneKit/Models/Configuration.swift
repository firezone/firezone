//
//  Configuration.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public struct Configuration: Codable {
  private enum BaseKeys {
    private static let authURL = "authURL"
    private static let apiURL = "apiURL"
    private static let logFilter = "logFilter"
    private static let accountSlug = "accountSlug"
    private static let internetResourceEnabled = "internetResourceEnabled"
  }

  public enum Keys {
    public static let authURL = userKeyPrefix + BaseKeys.authURL
    public static let apiURL = userKeyPrefix + BaseKeys.apiURL
    public static let logFilter = userKeyPrefix + BaseKeys.logFilter
    public static let actorName = userKeyPrefix + BaseKeys.actorName
    public static let accountSlug = userKeyPrefix + BaseKeys.accountSlug
    public static let internetResourceEnabled = userKeyPrefix + BaseKeys.internetResourceEnabled
    public static let firezoneId = userKeyPrefix + BaseKeys.firezoneId
  }

  private static let userKeyPrefix = "dev.firezone.configuration."

  private var userDict: [String: Any?]
  private var managedDict: [String: Any?]

  // User configuration only

  private(set) var actorName: String? { userDict[Keys.actorName] as? String }

  private(set) var firezoneId: String? { userDict[Keys.firezoneId] as? String }

  // User and managed keys

  private(set) var authURL: URL? {
    if let val = managedDict[BaseKeys.authURL] as? URL {
      return val
    }

    return userDict[Keys.authURL] as? URL
  }

  private(set) var apiURL: URL? {
    if let val = managedDict[BaseKeys.apiURL] as? URL {
      return val
    }

    return userDict[Keys.apiURL] as? URL
  }

  private(set) var logFilter: String? {
    if let val = managedDict[BaseKeys.logFilter] as? String {
      return val
    }

    return userDict[Keys.logFilter] as? String
  }

  private(set) var accountSlug: String? {
    if let val = managedDict[BaseKeys.accountSlug] as? String {
      return val
    }

    return userDict[Keys.accountSlug] as? String
  }

  private(set) var internetResourceEnabled: Bool? {
    if let val = managedDict[BaseKeys.internetResourceEnabled] as? Bool {
      return val
    }

    return userDict[Keys.internetResourceEnabled] as? Bool
  }

  public init(userDict: [String: Any?], managedDict: [String: Any?]) {
    userDict = userDict
    managedDict = managedDict
  }

  func isOverridden(key: String) -> Bool {
    return managedDict[key] != nil
  }

  #if DEBUG
    public static let defaultAuthURL = URL(string: "https://app.firez.one")!
    public static let defaultApiURL = URL(string: "wss://api.firez.one")!
    public static let defaultLogFilter = "debug"
  #else
    public static let defaultAuthURL = URL(string: "https://app.firezone.dev")!
    public static let defaultApiURL = URL(string: "wss://api.firezone.dev")!
    public static let defaultLogFilter = "info"
  #endif
}
