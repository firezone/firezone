//
//  StoreResourceFetchTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("Store Resource Fetch Tests")
struct StoreResourceFetchTests {

  // MARK: - Basic Fetch Tests

  @Test("Immediate success populates resources")
  @MainActor
  func immediateSuccessPopulatesResources() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()

    // Return valid data immediately on first call
    let resources = [makeResource(id: "res-1", name: "My Resource")]
    mockController.fetchResourcesResponse = try encodeResources(resources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Act: Trigger resource fetch
    try await store.fetchResources()

    // Assert: Only one call made
    #expect(mockController.fetchResourcesCallCount == 1)

    // Assert: State is now loaded with the resources
    if case .loaded(let loadedResources) = store.resourceList {
      #expect(loadedResources.count == 1)
      #expect(loadedResources[0].id == "res-1")
      #expect(loadedResources[0].name == "My Resource")
    } else {
      Issue.record("Expected state to be .loaded after successful fetch")
    }
  }

  // MARK: - Hash-Based Optimization Tests

  @Test("First fetch populates resources from loading to loaded")
  @MainActor
  func firstFetchPopulatesResources() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()

    let resources = [
      makeResource(id: "1", name: "Resource One", address: "one.example.com"),
      makeResource(id: "2", name: "Resource Two", address: "two.example.com"),
    ]
    mockController.fetchResourcesResponse = try encodeResources(resources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Assert initial state is loading
    if case .loading = store.resourceList {
      // Expected
    } else {
      Issue.record("Expected resourceList to be .loading initially")
    }

    // Act: Trigger resource fetch
    try await store.fetchResources()

    // Assert: Resources are now loaded
    if case .loaded(let loadedResources) = store.resourceList {
      #expect(loadedResources.count == 2)
      #expect(loadedResources[0].id == "1")
      #expect(loadedResources[0].name == "Resource One")
      #expect(loadedResources[1].id == "2")
      #expect(loadedResources[1].name == "Resource Two")
    } else {
      Issue.record("Expected resourceList to be .loaded after fetch")
    }
  }

  @Test("Unchanged resources return nil via hash comparison")
  @MainActor
  func unchangedResourcesReturnNil() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    // Enable realistic hash behavior - mock compares hashes like the real tunnel provider
    mockController.simulateHashBehavior = true

    let resources = [makeResource(id: "1", name: "Original Resource")]
    mockController.fetchResourcesResponse = try encodeResources(resources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // First fetch: Store sends empty hash, mock returns data (hashes differ)
    try await store.fetchResources()
    #expect(mockController.fetchResourcesCallCount == 1)

    // Verify resources loaded
    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 1)
      #expect(loaded[0].name == "Original Resource")
    } else {
      Issue.record("Expected .loaded after first fetch")
    }

    // Second fetch: Store sends hash of current data, mock returns nil (hashes match)
    // This tests the REAL hash comparison behavior
    try await store.fetchResources()
    #expect(mockController.fetchResourcesCallCount == 2)

    // Resources should still be .loaded with same data (nil response = no changes)
    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 1)
      #expect(loaded[0].name == "Original Resource")
    } else {
      Issue.record("Expected resourceList to remain .loaded")
    }
  }

  @Test("Changed resources detected via hash comparison")
  @MainActor
  func changedResourcesDetectedViaHash() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    // Enable realistic hash behavior
    mockController.simulateHashBehavior = true

    let initialResources = [makeResource(id: "1", name: "Initial Resource")]
    mockController.fetchResourcesResponse = try encodeResources(initialResources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // First fetch - data returned (hashes differ since Store starts with empty hash)
    try await store.fetchResources()

    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 1)
      #expect(loaded[0].name == "Initial Resource")
    } else {
      Issue.record("Expected .loaded after first fetch")
    }

    // Change the server-side data (simulates resources changing on the tunnel provider)
    let updatedResources = [
      makeResource(id: "1", name: "Updated Resource"),
      makeResource(id: "2", name: "New Resource"),
    ]
    mockController.fetchResourcesResponse = try encodeResources(updatedResources)

    // Act: Fetch again - new data returned because hash of new data differs from Store's hash
    try await store.fetchResources()

    // Assert: Resources were updated (hash comparison detected change)
    #expect(mockController.fetchResourcesCallCount == 2)

    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 2)
      #expect(loaded[0].name == "Updated Resource")
      #expect(loaded[1].name == "New Resource")
    } else {
      Issue.record("Expected resourceList to be updated")
    }
  }

  @Test("Resources reset on VPN disconnect")
  @MainActor
  func resourcesResetOnDisconnect() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()

    let resources = [makeResource(id: "1", name: "Test Resource")]
    mockController.fetchResourcesResponse = try encodeResources(resources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // First fetch to populate resources
    try await store.fetchResources()

    // Verify loaded
    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 1)
    } else {
      Issue.record("Expected .loaded after fetch")
    }

    let fetchCountBeforeDisconnect = mockController.fetchResourcesCallCount

    // Act: Simulate VPN disconnecting
    try await mockController.simulateStatusChange(.disconnected)

    // Assert: Resources reset to loading state
    if case .loading = store.resourceList {
      // Expected - resources are reset to loading
    } else {
      Issue.record("Expected resourceList to be .loading after disconnect")
    }

    // The hash should also be reset, so a subsequent fetch should
    // populate resources fresh (not be treated as "unchanged")
    mockController.fetchResourcesResponse = try encodeResources(resources)

    // Simulate reconnect and fetch
    try await mockController.simulateStatusChange(.connected)
    try await store.fetchResources()

    // Verify resources loaded again (hash was reset, so data is accepted)
    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 1)
    } else {
      Issue.record("Expected .loaded after reconnect and fetch")
    }

    // Confirm fetch was called (hash reset allowed new data)
    #expect(mockController.fetchResourcesCallCount > fetchCountBeforeDisconnect)
  }
}
