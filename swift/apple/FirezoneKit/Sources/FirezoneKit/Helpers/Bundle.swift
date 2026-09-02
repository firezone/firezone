//
//  Bundle.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// How the tunnel provider ships, which is what separates the two macOS builds.
public enum TunnelProviderKind: String, Sendable {
  /// Bundled inside the app. It shares the app's group container, runs as the user
  /// and only exists while the tunnel does. Every iOS build works this way, and a
  /// Mac App Store build has to.
  case appExtension = "app-extension"

  /// Installed into the system by the app. It runs as root, outside the app's
  /// container, and stays reachable while the tunnel is down. Only the standalone
  /// macOS build ships one.
  case systemExtension = "system-extension"
}

public enum BundleHelper {
  static func isAppStore() -> Bool {
    if let receiptURL = Bundle.main.appStoreReceiptURL,
      FileManager.default.fileExists(atPath: receiptURL.path)
    {
      return true
    }

    return false
  }

  /// How this build's tunnel provider ships.
  ///
  /// Both the app and the provider declare it, so either process can ask. A bundle
  /// without the key predates the split or is a test bundle, and macOS shipped a
  /// system extension then.
  public static var tunnelProviderKind: TunnelProviderKind {
    guard let raw = Bundle.main.object(forInfoDictionaryKey: "TunnelProviderKind") as? String,
      let kind = TunnelProviderKind(rawValue: raw)
    else {
      #if os(macOS)
        return .systemExtension
      #else
        return .appExtension
      #endif
    }

    return kind
  }

  /// Whether telemetry was switched off when this bundle was built. Apple builds
  /// default to no telemetry; official release scripts explicitly opt in.
  static var noTelemetry: Bool {
    Bundle.main.object(forInfoDictionaryKey: "NoTelemetry") as? String == "true"
  }

  static var gitSha: String {
    guard let gitSha = Bundle.main.object(forInfoDictionaryKey: "GitSha") as? String,
      !gitSha.isEmpty
    else { return "unknown" }

    return String(gitSha.prefix(8))
  }

  /// The app group the app shares with its extensions, or `nil` when the bundle's
  /// Info.plist declares no `AppGroupIdentifier`, which is every process except the app
  /// and its extensions (a test, most obviously).
  static var appGroupIdIfPresent: String? {
    Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
  }

  public static var appGroupId: String {
    guard let appGroupId = appGroupIdIfPresent else {
      fatalError("AppGroupIdentifier missing in app's Info.plist")
    }
    return appGroupId
  }
}
