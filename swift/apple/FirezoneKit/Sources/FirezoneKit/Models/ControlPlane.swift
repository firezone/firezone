//
//  ControlPlane.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// The control plane the app signs in to: a Firezone Cloud deployment, or `custom` for any other URLs.
///
/// The URLs of a Firezone Cloud control plane are compiled in and never taken from the control plane itself:
/// the choice decides which control plane the app talks to.
public enum ControlPlane: String, CaseIterable, Identifiable, Sendable {
  case cloudUs
  case cloudEu
  case custom

  public var id: Self { self }

  /// The label of the setting that picks a control plane.
  public static let pickerTitle = "Control plane"

  public var title: String {
    switch self {
    case .cloudUs: return "Firezone Cloud (US)"
    case .cloudEu: return "Firezone Cloud (EU)"
    case .custom: return "Custom"
    }
  }

  public var urls: (authURL: String, apiURL: String)? {
    switch self {
    case .cloudUs: return ("https://app.firezone.dev", "wss://api.firezone.dev")
    case .cloudEu: return ("https://eu.app.firezone.dev", "wss://eu.api.firezone.dev")
    case .custom: return nil
    }
  }

  /// The control plane whose URLs are `authURL` and `apiURL`, or `custom`.
  public static func of(authURL: String, apiURL: String) -> ControlPlane {
    allCases.first { controlPlane in
      guard let urls = controlPlane.urls else { return false }
      return isSameURL(urls.authURL, authURL) && isSameURL(urls.apiURL, apiURL)
    } ?? .custom
  }

  // URLs are saved as typed, by the user or by an MDM profile, so `https://app.firezone.dev/` is
  // Firezone Cloud (US) too.
  private static func isSameURL(_ lhs: String, _ rhs: String) -> Bool {
    normalized(lhs) == normalized(rhs)
  }

  private static func normalized(_ url: String) -> String {
    var result = url.trimmingCharacters(in: .whitespacesAndNewlines)[...]
    while result.last == "/" { result = result.dropLast() }
    return result.lowercased()
  }
}
