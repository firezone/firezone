//
//  Settings.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct Settings: Equatable {
  var authBaseURL: String
  var apiURL: String
  var logFilter: String

  var isValid: Bool {
    URL(string: authBaseURL) != nil
      && URL(string: apiURL) != nil
      && !logFilter.isEmpty
  }

  // Convert provider configuration (which may have empty fields if it was tampered with) to Settings
  static func fromProviderConfiguration(providerConfiguration: Dictionary<String, String>?) -> Settings {
    if let providerConfiguration = providerConfiguration {
      return Settings(
        authBaseURL: providerConfiguration[TunnelStoreKeys.authBaseURL] ?? Settings.defaultValue.authBaseURL,
        apiURL: providerConfiguration[TunnelStoreKeys.apiURL] ?? Settings.defaultValue.apiURL,
        logFilter: providerConfiguration[TunnelStoreKeys.logFilter] ?? Settings.defaultValue.logFilter
      )
    } else {
      return Settings.defaultValue
    }
  }

  // Used for initializing a new providerConfiguration from Settings
  func toProviderConfiguration() -> [String: Any] {
    return [
      "authBaseURL": authBaseURL,
      "apiURL": apiURL,
      "logFilter": logFilter
    ]
  }

  static let defaultValue: Settings = {
    // Note: To see what the connlibLogFilterString values mean, see:
    // https://docs.rs/tracing-subscriber/latest/tracing_subscriber/filter/struct.EnvFilter.html
    #if DEBUG
      Settings(
        authBaseURL: "https://app.firez.one",
        apiURL: "wss://api.firez.one",
        logFilter:
          "firezone_tunnel=trace,phoenix_channel=debug,connlib_shared=debug,connlib_client_shared=debug,str0m=info,debug"
      )
    #else
      Settings(
        authBaseURL: "https://app.firezone.dev",
        apiURL: "wss://api.firezone.dev",
        logFilter:
          "firezone_tunnel=info,connlib_shared=info,phoenix_channel=info,connlib_client_shared=info,boringtun=info,snownet=info,str0m=info,warn"
      )
    #endif
  }()
}

extension Settings: CustomStringConvertible {
  var description: String {
    "(\(authBaseURL), \(apiURL), \(logFilter)"
  }
}
