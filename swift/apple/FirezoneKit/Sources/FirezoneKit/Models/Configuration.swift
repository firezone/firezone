//
//  Configuration.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public struct Configuration: Codable {
  var actorName: String?
  var authURL: URL?
  var apiURL: URL?
  var logFilter: String?
  var accountSlug: String?
  var firezoneId: String?
  var internetResourceEnabled: Bool?

  public init(from dict: [String: Any?]) {
    self.actorName = dict["actorName"] as? String
    self.authURL = dict["authURL"] as? URL
    self.apiURL = dict["apiURL"] as? URL
    self.logFilter = dict["logFilter"] as? String
    self.accountSlug = dict["accountSlug"] as? String
    self.firezoneId = dict["firezoneId"] as? String
    self.internetResourceEnabled = dict["internetResourceEnabled"] as? Bool
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
