//
//  UserDefaults+Testing.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

extension UserDefaults {
  /// Creates an ephemeral `UserDefaults` instance backed by a unique suite name.
  ///
  /// Each call returns a fresh, isolated store suitable for testing.
  static func makeTestDefaults() -> UserDefaults {
    let suiteName = "dev.firezone.firezone.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Failed to create UserDefaults with suite: \(suiteName)")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
