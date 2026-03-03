//
//  SemanticVersionPersistenceTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)

  import Foundation
  import Testing

  @testable import FirezoneKit

  @Suite("SemanticVersion Persistence Tests")
  struct SemanticVersionPersistenceTests {

  private func makeTestDefaults() -> UserDefaults {
    let suiteName = "dev.firezone.firezone.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Failed to create UserDefaults with suite: \(suiteName)")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  // BUG: loadVersion ignores its `key` parameter and always reads from
  // `lastDismissedVersionKey`. This test documents that broken behaviour.
  @Test("setVersion/loadVersion round-trip is broken — loadVersion ignores key")
  func roundTripIsBroken() throws {
    let defaults = makeTestDefaults()
    let version = try SemanticVersion("1.2.3")

    setVersion(key: "myKey", version: version, userDefaults: defaults)

    // loadVersion should return `version` for "myKey", but it reads from the
    // wrong key internally, so it returns nil.
    let loaded = loadVersion(key: "myKey", userDefaults: defaults)
    #expect(loaded == nil, "loadVersion ignores its key and reads lastDismissedVersionKey")
  }

#endif
