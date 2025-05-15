//
//  Settings.swift
//  © 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Settings represents the binding between our source-of-truth, Configuration, and user-configurable settings
//  available in the SettingsView.

import Foundation

class Settings {
  @Published var authURL: String
  @Published var apiURL: String
  @Published var logFilter: String
  @Published var accountSlug: String
  @Published var connectOnStart: Bool
  var isAuthURLOverridden = false
  var isApiURLOverridden = false
  var isLogFilterOverridden = false
  var isAccountSlugOverridden = false
  var isConnectOnStartOverridden = false

  private var configuration: Configuration

  init(from configuration: Configuration) {
    self.configuration = configuration
    self.authURL = configuration.authURL ?? Configuration.defaultAuthURL
    self.apiURL = configuration.apiURL ?? Configuration.defaultApiURL
    self.logFilter = configuration.logFilter ?? Configuration.defaultLogFilter
    self.accountSlug = configuration.accountSlug ?? Configuration.defaultAccountSlug
    self.connectOnStart = configuration.connectOnStart ?? Configuration.defaultConnectOnStart

    self.isAuthURLOverridden = configuration.isOverridden(Configuration.Keys.authURL)
    self.isApiURLOverridden = configuration.isOverridden(Configuration.Keys.apiURL)
    self.isLogFilterOverridden = configuration.isOverridden(Configuration.Keys.logFilter)
    self.isAccountSlugOverridden = configuration.isOverridden(Configuration.Keys.accountSlug)
    self.isConnectOnStartOverridden = configuration.isOverridden(Configuration.Keys.connectOnStart)
  }

  func areAllFieldsOverridden() -> Bool {
    return (isAuthURLOverridden &&
            isApiURLOverridden &&
            isLogFilterOverridden &&
            isAccountSlugOverridden &&
            isConnectOnStartOverridden)
  }

  func isValid() -> Bool {
    guard let apiURL = URL(string: apiURL),
          apiURL.host != nil,
          ["wss", "ws"].contains(apiURL.scheme),
          apiURL.pathComponents.isEmpty
    else {
      return false
    }

    guard let authURL = URL(string: authURL),
          authURL.host != nil,
          ["http", "https"].contains(authURL.scheme),
          authURL.pathComponents.isEmpty
    else {
      return false
    }

    guard !logFilter.isEmpty
    else {
      return false
    }

    return true
  }

  func isDefault() -> Bool {
    return (authURL == Configuration.defaultAuthURL &&
            apiURL == Configuration.defaultApiURL &&
            logFilter == Configuration.defaultLogFilter &&
            accountSlug == Configuration.defaultAccountSlug &&
            connectOnStart == Configuration.defaultConnectOnStart)
  }

  func isSaved() -> Bool {
    return (
      authURL == configuration.authURL &&
      apiURL == configuration.apiURL &&
      logFilter == configuration.logFilter &&
      accountSlug == configuration.accountSlug &&
      connectOnStart == configuration.connectOnStart)
  }

  func reset() {
    self.authURL = Configuration.defaultAuthURL
    self.apiURL = Configuration.defaultApiURL
    self.logFilter = Configuration.defaultLogFilter
    self.accountSlug = Configuration.defaultAccountSlug
    self.connectOnStart = Configuration.defaultConnectOnStart
  }
}
