//
//  CloudRegion.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// The Firezone Cloud deployment the app signs in to, or `custom` for any other URLs.
///
/// The URLs of a region are compiled in and never taken from the portal: the region decides which
/// portal the app talks to.
public enum CloudRegion: String, CaseIterable, Identifiable, Sendable {
  case us
  case eu
  case custom

  public var id: Self { self }

  /// The label of the setting that picks a region.
  public static let pickerTitle = "Authentication and control plane"

  public var title: String {
    switch self {
    case .us: return "Firezone Cloud US"
    case .eu: return "Firezone Cloud EU"
    case .custom: return "Custom"
    }
  }

  public var urls: (authURL: String, apiURL: String)? {
    switch self {
    case .us: return ("https://app.firezone.dev", "wss://api.firezone.dev")
    case .eu: return ("https://eu.app.firezone.dev", "wss://eu.api.firezone.dev")
    case .custom: return nil
    }
  }

  /// The region whose URLs are `authURL` and `apiURL`, or `custom`.
  public static func of(authURL: String, apiURL: String) -> CloudRegion {
    allCases.first { region in
      guard let urls = region.urls else { return false }
      return isSameURL(urls.authURL, authURL) && isSameURL(urls.apiURL, apiURL)
    } ?? .custom
  }

  // URLs are saved as typed, by the user or by an MDM profile, so `https://app.firezone.dev/` is
  // the US region too.
  private static func isSameURL(_ lhs: String, _ rhs: String) -> Bool {
    normalized(lhs) == normalized(rhs)
  }

  private static func normalized(_ url: String) -> String {
    var result = url.trimmingCharacters(in: .whitespacesAndNewlines)[...]
    while result.last == "/" { result = result.dropLast() }
    return result.lowercased()
  }
}
