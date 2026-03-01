//
//  FavoritesTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import Testing

@testable import FirezoneKit

@Suite("Favorites Tests")
struct FavoritesTests {

  // MARK: - Core Operations

  @Test("Starts empty when no prior data exists")
  func startsEmpty() {
    let defaults = makeTestDefaults()
    let favorites = Favorites(userDefaults: defaults)

    #expect(favorites.isEmpty())
  }

  @Test("Add makes resource ID contained")
  func addMakesContained() {
    let defaults = makeTestDefaults()
    let favorites = Favorites(userDefaults: defaults)

    favorites.add("resource-1")

    #expect(favorites.contains("resource-1"))
    #expect(!favorites.isEmpty())
  }

  @Test("Adding same ID twice is idempotent")
  func addIdempotent() {
    let defaults = makeTestDefaults()
    let favorites = Favorites(userDefaults: defaults)

    favorites.add("resource-1")
    favorites.add("resource-1")

    #expect(favorites.contains("resource-1"))
    // Remove once - should be gone (not still there from double-add)
    favorites.remove("resource-1")
    #expect(!favorites.contains("resource-1"))
  }

  @Test("Remove makes resource ID no longer contained")
  func removeWorks() {
    let defaults = makeTestDefaults()
    let favorites = Favorites(userDefaults: defaults)

    favorites.add("resource-1")
    favorites.remove("resource-1")

    #expect(!favorites.contains("resource-1"))
    #expect(favorites.isEmpty())
  }

  @Test("Reset clears all favorites")
  func resetClearsAll() {
    let defaults = makeTestDefaults()
    let favorites = Favorites(userDefaults: defaults)

    favorites.add("resource-1")
    favorites.add("resource-2")
    favorites.add("resource-3")
    favorites.reset()

    #expect(favorites.isEmpty())
    #expect(!favorites.contains("resource-1"))
    #expect(!favorites.contains("resource-2"))
    #expect(!favorites.contains("resource-3"))
  }

  // MARK: - Persistence

  @Test("Favorites persist across instances")
  func favoritesPersistedAcrossInstances() {
    let defaults = makeTestDefaults()

    // First instance adds favorites
    let favorites1 = Favorites(userDefaults: defaults)
    favorites1.add("resource-1")
    favorites1.add("resource-2")

    // Second instance should load them
    let favorites2 = Favorites(userDefaults: defaults)
    #expect(favorites2.contains("resource-1"))
    #expect(favorites2.contains("resource-2"))
  }

  // MARK: - ObservableObject Behavior

  @Test("Add triggers objectWillChange")
  @MainActor
  func addTriggersChange() async throws {
    let defaults = makeTestDefaults()
    let favorites = Favorites(userDefaults: defaults)

    await confirmation("objectWillChange fires on add") { confirm in
      let cancellable = favorites.objectWillChange.sink { _ in
        confirm()
      }

      favorites.add("resource-1")

      // Keep cancellable alive
      _ = cancellable
    }
  }

  // MARK: - Private Helpers

  /// Creates an isolated UserDefaults instance for each test.
  private func makeTestDefaults() -> UserDefaults {
    let suiteName = "dev.firezone.firezone.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Failed to create UserDefaults with suite: \(suiteName)")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

}
