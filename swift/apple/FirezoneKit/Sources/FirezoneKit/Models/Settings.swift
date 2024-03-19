//
//  Settings.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct AdvancedSettings: Equatable {
  var authBaseURLString: String {
    didSet { if oldValue != authBaseURLString { isSavedToDisk = false } }
  }
  var apiURLString: String {
    didSet { if oldValue != apiURLString { isSavedToDisk = false } }
  }
  var connlibLogFilterString: String {
    didSet { if oldValue != connlibLogFilterString { isSavedToDisk = false } }
  }

  var isSavedToDisk = true

  var isValid: Bool {
    URL(string: authBaseURLString) != nil
      && URL(string: apiURLString) != nil
      && !connlibLogFilterString.isEmpty
  }

  static let defaultValue: AdvancedSettings = {
    // Note: To see what the connlibLogFilterString values mean, see:
    // https://docs.rs/tracing-subscriber/latest/tracing_subscriber/filter/struct.EnvFilter.html
    #if DEBUG
      AdvancedSettings(
        authBaseURLString: "https://app.firez.one",
        apiURLString: "wss://api.firez.one",
        connlibLogFilterString:
          "firezone_tunnel=trace,phoenix_channel=debug,connlib_shared=debug,connlib_client_shared=debug,str0m=info,debug"
      )
    #else
      AdvancedSettings(
        authBaseURLString: "https://app.firezone.dev",
        apiURLString: "wss://api.firezone.dev",
        connlibLogFilterString:
          "firezone_tunnel=info,connlib_shared=info,phoenix_channel=info,connlib_client_shared=info,boringtun=info,snownet=info,str0m=info,warn"
      )
    #endif
  }()
}

extension AdvancedSettings: CustomStringConvertible {
  var description: String {
    "(\(authBaseURLString), \(apiURLString), \(connlibLogFilterString))"
  }
}
