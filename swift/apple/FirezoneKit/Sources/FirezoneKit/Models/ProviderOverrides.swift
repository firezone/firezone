//
//  ProviderOverrides.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// The settings a headless client owns, written into the VPN profile before starting
/// the tunnel because the network extension reads its configuration from there.
///
/// Settings not listed here, such as the actor name or the GUI's start-up preferences,
/// keep whatever value the GUI stored.
public struct ProviderOverrides: Sendable {
  public var apiURL: String
  public var accountSlug: String
  public var logFilter: String
  public var internetResourceEnabled: Bool

  public init(
    apiURL: String,
    accountSlug: String,
    logFilter: String,
    internetResourceEnabled: Bool
  ) {
    self.apiURL = apiURL
    self.accountSlug = accountSlug
    self.logFilter = logFilter
    self.internetResourceEnabled = internetResourceEnabled
  }

  @MainActor
  func apply(to configuration: Configuration) {
    configuration.apiURL = apiURL
    configuration.accountSlug = accountSlug
    configuration.logFilter = logFilter
    configuration.internetResourceEnabled = internetResourceEnabled
  }
}
