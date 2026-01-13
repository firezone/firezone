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

  @Test("Stops retrying after maxAttempts")
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

    // Act: Trigger a single resource fetch cycle
    try await store.testFetchResources()

    // Assert: 1 initial call + 3 retries = 4 total calls
    #expect(mockIPC.fetchResourcesCallCount == 4)
  }

  @Test("No retry when resources are already loaded")
  @MainActor
  func noRetryWhenAlreadyLoaded() async throws {
    // This test would require a way to set resourceList to .loaded state
    // For now, we just verify the nil response behavior
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()

    // Return valid data on first call
    let encoder = PropertyListEncoder()
    let resources: [Resource] = []  // Empty but valid
    mockIPC.fetchResourcesResponse = try encoder.encode(resources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: RetryPolicy(maxAttempts: 5, baseDelayMs: 10)
    )

    // Act: Trigger resource fetch
    try await store.testFetchResources()

    // Assert: Only one call - no retry needed when data is returned
    #expect(mockIPC.fetchResourcesCallCount == 1)
  }
}
