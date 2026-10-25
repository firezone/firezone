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
  public var logFilter: String?
  // swiftlint:disable:next discouraged_optional_boolean - nil means "leave as stored"
  public var internetResourceEnabled: Bool?
  // swiftlint:disable:next discouraged_optional_collection - nil means "leave as stored"
  public var additionalHostCandidates: [String]?

  public init(
    logFilter: String? = nil,
    // swiftlint:disable:next discouraged_optional_boolean - nil means "leave as stored"
    internetResourceEnabled: Bool? = nil,
    // swiftlint:disable:next discouraged_optional_collection - nil means "leave as stored"
    additionalHostCandidates: [String]? = nil
  ) {
    self.logFilter = logFilter
    self.internetResourceEnabled = internetResourceEnabled
    self.additionalHostCandidates = additionalHostCandidates
  }

  @MainActor
  func apply(to configuration: Configuration) {
    if let logFilter { configuration.logFilter = logFilter }
    if let internetResourceEnabled {
      configuration.internetResourceEnabled = internetResourceEnabled
    }
    if let additionalHostCandidates {
      configuration.additionalHostCandidates = additionalHostCandidates
    }
  }
}

/// The parts of the stored configuration a headless sign-in link is built from.
public struct SignInSettings: Sendable {
  public let authURL: String
  public let accountSlug: String
}
