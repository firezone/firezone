//
//  Configuration.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public class Configuration: Codable {

#if DEBUG
  public static let defaultAuthURL = URL(string: "https://app.firez.one")!
  public static let defaultApiURL = URL(string: "wss://api.firez.one")!
  public static let defaultLogFilter = "debug"
#else
  public static let defaultAuthURL = URL(string: "https://app.firezone.dev")!
  public static let defaultApiURL = URL(string: "wss://api.firezone.dev")!
  public static let defaultLogFilter = "info"
#endif

  public enum Keys {
    public static let authURL = "authURL"
    public static let apiURL = "apiURL"
    public static let logFilter = "logFilter"
    public static let actorName = "actorName"
    public static let accountSlug = "accountSlug"
    public static let internetResourceEnabled = "internetResourceEnabled"
    public static let firezoneId = "firezoneId"
  }

  public var authURL: URL?
  public var actorName: String?
  public var firezoneId: String?
  public var apiURL: URL?
  public var logFilter: String?
  public var accountSlug: String?
  public var internetResourceEnabled: Bool?

  private var overriddenKeys: Set<String> = []

  public init(userDict: [String: Any?], managedDict: [String: Any?]) {
    self.actorName = userDict[Keys.actorName] as? String
    self.firezoneId = userDict[Keys.firezoneId] as? String

    if let authURLString = managedDict[Keys.authURL] as? String,
       let authURL = URL(string: authURLString) {
      self.overriddenKeys.insert(Keys.authURL)
      self.authURL = authURL
    } else if let authURLString = userDict[Keys.authURL] as? String {
      self.authURL = URL(string: authURLString)
    }

    if let apiURLString = managedDict[Keys.apiURL] as? String,
       let apiURL = URL(string: apiURLString) {
      self.overriddenKeys.insert(Keys.apiURL)
      self.apiURL = apiURL
    } else if let apiURLString = userDict[Keys.apiURL] as? String {
      self.apiURL = URL(string: apiURLString)
    }

    if let logFilter = managedDict[Keys.logFilter] as? String {
      self.overriddenKeys.insert(Keys.logFilter)
      self.logFilter = logFilter
    } else {
      self.logFilter = userDict[Keys.logFilter] as? String
    }

    if let accountSlug = managedDict[Keys.accountSlug] as? String {
      self.overriddenKeys.insert(Keys.accountSlug)
      self.accountSlug = accountSlug
    } else {
      self.accountSlug = userDict[Keys.accountSlug] as? String
    }

    if let internetResourceEnabled = managedDict[Keys.internetResourceEnabled] as? Bool {
      self.overriddenKeys.insert(Keys.internetResourceEnabled)
      self.internetResourceEnabled = internetResourceEnabled
    } else {
      self.internetResourceEnabled = userDict[Keys.internetResourceEnabled] as? Bool
    }
  }

  func isOverridden(key: String) -> Bool {
    return overriddenKeys.contains(key)
  }
}
