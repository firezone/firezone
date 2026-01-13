//
//  StoreResourceFetchTests.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("Store Resource Fetch Tests")
struct StoreResourceFetchTests {

  // Each test gets a unique UserDefaults suite for isolation
  private func makeTestDefaults() -> UserDefaults {
    let suiteName = "dev.firezone.firezone.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private let encoder = PropertyListEncoder()

  /// Creates a test Resource with default values for non-essential fields.
  private func makeResource(
    id: String = UUID().uuidString,
    name: String = "Test Resource",
    address: String? = "test.example.com",
    type: ResourceType = .dns
  ) -> Resource {
    Resource(
      id: id,
      name: name,
      address: address,
      addressDescription: nil,
      status: .online,
      sites: [],
      type: type
    )
  }

  /// Encodes resources to PropertyList data.
  private func encode(_ resources: [Resource]) throws -> Data {
    try encoder.encode(resources)
  }

  @Test("Retries resource fetch when adapter returns nil while loading")
  @MainActor
  func retriesOnNilWhileLoading() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()

    // IPC returns nil (adapter not ready)
    mockIPC.fetchResourcesResponse = nil

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: RetryPolicy(maxAttempts: 5, baseDelayMs: 10)  // Fast for tests
    )

    // Act: Trigger a resource fetch directly
    try await store.testFetchResources()

    // Assert: 1 initial call + up to maxAttempts retries = maxAttempts + 1 total calls
    #expect(mockIPC.fetchResourcesCallCount == 6)  // 1 + 5 retries
  }

  @Test("Stops retrying after maxAttempts and leaves state as loading")
  @MainActor
  func stopsAfterMaxAttempts() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()
    mockIPC.fetchResourcesResponse = nil  // Always nil

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: RetryPolicy(maxAttempts: 3, baseDelayMs: 5)
    )

    // Verify initial state is loading
    if case .loading = store.resourceList {
      // Expected
    } else {
      Issue.record("Expected initial state to be .loading")
    }

    // Act: Trigger a single resource fetch cycle
    try await store.testFetchResources()

    // Assert: 1 initial call + 3 retries = 4 total calls
    #expect(mockIPC.fetchResourcesCallCount == 4)

    // Assert: State remains as loading after all retries exhausted
    if case .loading = store.resourceList {
      // Expected - state stayed as loading since no data was ever returned
    } else {
      Issue.record("Expected state to remain .loading after exhausting retries")
    }
  }

  @Test("No retry when resources are already loaded and nil response received")
  @MainActor
  func noRetryWhenAlreadyLoaded() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()

    // First call returns valid data to transition to loaded state
    let resources = [makeResource(id: "test-1", name: "Test Resource")]
    let encodedResources = try encode(resources)

    // Sequence: first call returns data, subsequent calls return nil
    mockIPC.fetchResourcesSequence = [encodedResources, nil, nil, nil]

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: RetryPolicy(maxAttempts: 5, baseDelayMs: 5)
    )

    // Act: First fetch - should load resources
    try await store.testFetchResources()

    // Assert: State is now loaded
    if case .loaded(let loadedResources) = store.resourceList {
      #expect(loadedResources.count == 1)
      #expect(loadedResources[0].id == "test-1")
    } else {
      Issue.record("Expected state to be .loaded after first fetch")
    }

    // Record the call count after first successful fetch
    let callsAfterFirstFetch = mockIPC.fetchResourcesCallCount
    #expect(callsAfterFirstFetch == 1)

    // Act: Second fetch - returns nil but should NOT retry because state is .loaded
    try await store.testFetchResources()

    // Assert: Only 1 additional call (no retries) since state is .loaded
    #expect(mockIPC.fetchResourcesCallCount == callsAfterFirstFetch + 1)

    // Assert: State remains loaded with same resources
    if case .loaded(let loadedResources) = store.resourceList {
      #expect(loadedResources.count == 1)
      #expect(loadedResources[0].id == "test-1")
    } else {
      Issue.record("Expected state to remain .loaded")
    }
  }

  @Test("Immediate success on first try requires no retries")
  @MainActor
  func immediateSuccessNoRetries() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()

    // Return valid data immediately on first call
    let resources = [makeResource(id: "res-1", name: "My Resource")]
    mockIPC.fetchResourcesResponse = try encode(resources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: RetryPolicy(maxAttempts: 5, baseDelayMs: 10)  // Would retry if needed
    )

    // Act: Trigger resource fetch
    try await store.testFetchResources()

    // Assert: Only one call - no retry needed when data is returned on first try
    #expect(mockIPC.fetchResourcesCallCount == 1)

    // Assert: State is now loaded with the resources
    if case .loaded(let loadedResources) = store.resourceList {
      #expect(loadedResources.count == 1)
      #expect(loadedResources[0].id == "res-1")
      #expect(loadedResources[0].name == "My Resource")
    } else {
      Issue.record("Expected state to be .loaded after successful fetch")
    }
  }

  @Test("Retry succeeds after initial nil responses")
  @MainActor
  func retryEventuallySucceeds() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()

    // Sequence: 2 nils followed by valid data
    let resources = [makeResource(id: "delayed-resource", name: "Delayed Resource")]
    let encodedResources = try encode(resources)
    mockIPC.fetchResourcesSequence = [nil, nil, encodedResources]

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: RetryPolicy(maxAttempts: 5, baseDelayMs: 5)
    )

    // Act: Trigger resource fetch
    try await store.testFetchResources()

    // Assert: 3 calls total (2 nils + 1 success)
    #expect(mockIPC.fetchResourcesCallCount == 3)

    // Assert: State is now loaded
    if case .loaded(let loadedResources) = store.resourceList {
      #expect(loadedResources.count == 1)
      #expect(loadedResources[0].id == "delayed-resource")
    } else {
      Issue.record("Expected state to be .loaded after retry succeeded")
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
    let mockIPC = MockIPCClient()

    let resources = [
      makeResource(id: "1", name: "Resource One", address: "one.example.com"),
      makeResource(id: "2", name: "Resource Two", address: "two.example.com"),
    ]
    mockIPC.fetchResourcesResponse = try encode(resources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: .noRetry
    )

    // Assert initial state is loading
    if case .loading = store.resourceList {
      // Expected
    } else {
      Issue.record("Expected resourceList to be .loading initially")
    }

    // Act: Trigger resource fetch
    try await store.testFetchResources()

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

  @Test("Same data returns nil, no UI update occurs")
  @MainActor
  func sameDataReturnsNilNoUpdate() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()

    let resources = [makeResource(id: "1", name: "Original Resource")]
    let encodedData = try encode(resources)
    mockIPC.fetchResourcesResponse = encodedData

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: .noRetry
    )

    // First fetch to populate resources and set hash
    try await store.testFetchResources()
    #expect(mockIPC.fetchResourcesCallCount == 1)

    // Verify resources loaded
    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 1)
      #expect(loaded[0].name == "Original Resource")
    } else {
      Issue.record("Expected .loaded after first fetch")
    }

    // Simulate hash match: IPC returns nil because hash hasn't changed
    // (In production, the tunnel provider does this comparison)
    mockIPC.fetchResourcesResponse = nil

    // Act: Fetch again
    try await store.testFetchResources()

    // Assert: Call was made but resources unchanged
    #expect(mockIPC.fetchResourcesCallCount == 2)

    // Resources should still be .loaded with same data (not reset to .loading)
    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 1)
      #expect(loaded[0].name == "Original Resource")
    } else {
      Issue.record("Expected resourceList to remain .loaded")
    }
  }

  @Test("Different data updates resources")
  @MainActor
  func differentDataUpdatesResources() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()

    let initialResources = [makeResource(id: "1", name: "Initial Resource")]
    mockIPC.fetchResourcesResponse = try encode(initialResources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: .noRetry
    )

    // First fetch
    try await store.testFetchResources()

    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 1)
      #expect(loaded[0].name == "Initial Resource")
    } else {
      Issue.record("Expected .loaded after first fetch")
    }

    // Simulate new data with different content (different hash)
    let updatedResources = [
      makeResource(id: "1", name: "Updated Resource"),
      makeResource(id: "2", name: "New Resource"),
    ]
    mockIPC.fetchResourcesResponse = try encode(updatedResources)

    // Act: Fetch again with different data
    try await store.testFetchResources()

    // Assert: Resources were updated
    #expect(mockIPC.fetchResourcesCallCount == 2)

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
    let mockIPC = MockIPCClient()

    let resources = [makeResource(id: "1", name: "Test Resource")]
    mockIPC.fetchResourcesResponse = try encode(resources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: .noRetry
    )

    // First fetch to populate resources
    try await store.testFetchResources()

    // Verify loaded
    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 1)
    } else {
      Issue.record("Expected .loaded after fetch")
    }

    let fetchCountBeforeDisconnect = mockIPC.fetchResourcesCallCount

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
    mockIPC.fetchResourcesResponse = try encode(resources)

    // Simulate reconnect and fetch
    try await mockController.simulateStatusChange(.connected)
    try await store.testFetchResources()

    // Verify resources loaded again (hash was reset, so data is accepted)
    if case .loaded(let loaded) = store.resourceList {
      #expect(loaded.count == 1)
    } else {
      Issue.record("Expected .loaded after reconnect and fetch")
    }

    // Confirm fetch was called (hash reset allowed new data)
    #expect(mockIPC.fetchResourcesCallCount > fetchCountBeforeDisconnect)
  }
}
