//
//  Settings.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct Settings: Codable, Hashable {
  #if DEBUG
    var authBaseURL: URL = URL(string: "https://app.firez.one")!
    var apiURL: URL = URL(string: "wss://api.firez.one")!
    var logFilter: String =
      "connlib_client_apple=debug,firezone_tunnel=trace,connlib_shared=debug,connlib_client_shared=debug,warn"
  #else
    var authBaseURL: URL = URL(string: "https://app.firezone.dev")!
    var apiURL: URL = URL(string: "wss://api.firezone.dev")!
    var logFilter: String =
      "connlib_client_apple=info,firezone_tunnel=info,connlib_shared=info,connlib_client_shared=info,warn"
  #endif
  var accountId: String = ""
}
