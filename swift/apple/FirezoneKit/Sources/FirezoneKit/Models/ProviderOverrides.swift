//
//  ProviderOverrides.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Settings a headless client writes into the VPN profile before starting the tunnel,
/// because the network extension reads its configuration from there.
///
/// The profile is shared with the GUI, so `nil` means "leave whatever is stored".
/// Anything else would let a bare `firezone-cli` wipe settings the user configured in
/// the app just by not mentioning them.
public struct ProviderOverrides: Sendable {
  public var apiURL: String?
  public var accountSlug: String?
  public var logFilter: String?
  // swiftlint:disable:next discouraged_optional_boolean - nil means "leave as stored"
  public var internetResourceEnabled: Bool?

  public init(
    apiURL: String? = nil,
    accountSlug: String? = nil,
    logFilter: String? = nil,
    // swiftlint:disable:next discouraged_optional_boolean - nil means "leave as stored"
    internetResourceEnabled: Bool? = nil
  ) {
    self.apiURL = apiURL
    self.accountSlug = accountSlug
    self.logFilter = logFilter
    self.internetResourceEnabled = internetResourceEnabled
  }

  @MainActor
  func apply(to configuration: Configuration) {
    if let apiURL { configuration.apiURL = apiURL }
    if let accountSlug { configuration.accountSlug = accountSlug }
    if let logFilter { configuration.logFilter = logFilter }
    if let internetResourceEnabled {
      configuration.internetResourceEnabled = internetResourceEnabled
    }
  }
}
