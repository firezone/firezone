//
//  Settings.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

struct AccountSettings {
  var accountId: String = "" {
    didSet { if oldValue != accountId { isSavedToDisk = false } }
  }

  var isSavedToDisk = true

  var isValid: Bool {
    !accountId.isEmpty
      && accountId.unicodeScalars.allSatisfy { Self.teamIdAllowedCharacterSet.contains($0) }
  }

  static let teamIdAllowedCharacterSet: CharacterSet = {
    var pathAllowed = CharacterSet.urlPathAllowed
    pathAllowed.remove("/")
    return pathAllowed
  }()
}

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
    #if DEBUG
      AdvancedSettings(
        authBaseURLString: "https://app.firez.one/",
        apiURLString: "wss://api.firez.one/",
        connlibLogFilterString:
          "connlib_client_apple=debug,firezone_tunnel=trace,connlib_shared=debug,connlib_client_shared=debug,warn"
      )
    #else
      AdvancedSettings(
        authBaseURLString: "https://app.firezone.dev/",
        apiURLString: "wss://api.firezone.dev/",
        connlibLogFilterString:
          "connlib_client_apple=info,firezone_tunnel=info,connlib_shared=info,connlib_client_shared=info,warn"
      )
    #endif
  }()
}
