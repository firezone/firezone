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

  @Test("save/init round-trips with the given key")
  func roundTripsWithGivenKey() throws {
    let defaults = makeTestDefaults()
    let version = try SemanticVersion("1.2.3")

      version.save(to: defaults, forKey: "myKey")

      let loaded = SemanticVersion(from: defaults, forKey: "myKey")
      #expect(loaded == version)
    }

  @Test("Different keys store independent values")
  func differentKeysAreIndependent() throws {
    let defaults = makeTestDefaults()
    let versionA = try SemanticVersion("1.0.0")
    let versionB = try SemanticVersion("2.0.0")

      versionA.save(to: defaults, forKey: "keyA")
      versionB.save(to: defaults, forKey: "keyB")

      #expect(SemanticVersion(from: defaults, forKey: "keyA") == versionA)
      #expect(SemanticVersion(from: defaults, forKey: "keyB") == versionB)
    }

  @Test("Returns nil for missing key")
  func returnsNilForMissingKey() {
    let defaults = makeTestDefaults()

      #expect(SemanticVersion(from: defaults, forKey: "nonexistent") == nil)
    }
  }

#endif
