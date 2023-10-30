//
//  Settings.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct AccountSettings {
  var accountId: String = ""
}

struct AdvancedSettings {
  var authBaseURLString: String
  var apiURLString: String
  var connlibLogFilterString: String

  static let defaultValue: AdvancedSettings = {
    #if DEBUG
      AdvancedSettings(
        authBaseURLString: "https://app.firez.one",
        apiURLString: "wss://api.firez.one",
        connlibLogFilterString:
          "connlib_client_apple=debug,firezone_tunnel=trace,connlib_shared=debug,connlib_client_shared=debug,warn"
      )
    #else
      AdvancedSettings(
        authBaseURLString: "https://app.firezone.dev",
        apiURLString: "wss://api.firezone.dev",
        connlibLogFilterString:
          "connlib_client_apple=info,firezone_tunnel=info,connlib_shared=info,connlib_client_shared=info,warn"
      )
    #endif
  }()
}
