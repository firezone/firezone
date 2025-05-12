//
//  Configuration.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public struct Configuration: Codable {
  public enum Keys {
    public static let authURL = "dev.firezone.configuration.authURL"
    public static let apiURL = "dev.firezone.configuration.apiURL"
    public static let logFilter = "dev.firezone.configuration.logFilter"
    public static let actorName = "dev.firezone.configuration.actorName"
    public static let accountSlug = "dev.firezone.configuration.accountSlug"
    public static let internetResourceEnabled = "dev.firezone.configuration.internetResourceEnabled"
    public static let firezoneId = "dev.firezone.configuration.firezoneId"
  }

  var actorName: String?
  var authURL: URL?
  var apiURL: URL?
  var logFilter: String?
  var accountSlug: String?
  var firezoneId: String?
  var internetResourceEnabled: Bool?

  public init(from dict: [String: Any?]) {
    self.actorName = dict[Keys.actorName] as? String
    self.authURL = dict[Keys.authURL] as? URL
    self.apiURL = dict[Keys.apiURL] as? URL
    self.logFilter = dict[Keys.logFilter] as? String
    self.accountSlug = dict[Keys.accountSlug] as? String
    self.firezoneId = dict[Keys.firezoneId] as? String
    self.internetResourceEnabled = dict[Keys.internetResourceEnabled] as? Bool
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
