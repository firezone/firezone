//
//  StoreResourceTimerTests.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("Store Resource Timer Lifecycle Tests")
struct StoreResourceTimerTests {

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

  @Test("Timer starts on connected status - resource fetching begins")
  @MainActor
  func timerStartsOnConnected() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()

    // Return valid data so fetches succeed
    let resources = [makeResource(id: "1", name: "Test Resource")]
    mockIPC.fetchResourcesResponse = try encode(resources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: .noRetry
    )

    // Verify no fetches yet
    #expect(mockIPC.fetchResourcesCallCount == 0)

    // Act: Simulate VPN connecting then connected
    try await mockController.simulateStatusChange(.connected)

    // beginUpdatingResources fires immediately, so we should see at least one call
    // Wait a small amount for the immediate call to complete
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    // Assert: At least one fetch has occurred (immediate call on connect)
    #expect(mockIPC.fetchResourcesCallCount >= 1)

    // Wait for timer to fire at least once more (timer interval is 1 second)
    let initialCount = mockIPC.fetchResourcesCallCount
    try await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1 seconds

    // Assert: Timer has fired additional times
    #expect(mockIPC.fetchResourcesCallCount > initialCount)
  }

  @Test("Timer stops on disconnected status - resource fetching stops")
  @MainActor
  func timerStopsOnDisconnected() async throws {
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

    // Act: Start connected (timer begins)
    try await mockController.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms for immediate fetch

    let countAfterConnect = mockIPC.fetchResourcesCallCount
    #expect(countAfterConnect >= 1)

    // Act: Disconnect (timer should stop)
    try await mockController.simulateStatusChange(.disconnected)

    // Record count immediately after disconnect
    let countAfterDisconnect = mockIPC.fetchResourcesCallCount

    // Wait for what would have been timer intervals
    try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds

    // Assert: No additional fetches occurred after disconnect
    #expect(mockIPC.fetchResourcesCallCount == countAfterDisconnect)
  }

  @Test("Timer stops on connecting status - resource fetching stops during reconnection")
  @MainActor
  func timerStopsOnConnecting() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()

    let resources = [makeResource(id: "1", name: "Test Resource")]
    mockIPC.fetchResourcesResponse = try encode(resources)

    // Disable watchdog to avoid restart interference
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      retryPolicy: .noRetry
    )
    store.setWatchdogTimeout(60_000_000_000)  // 60 seconds - won't fire during test

    // Act: Start connected (timer begins)
    try await mockController.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms for immediate fetch

    let countAfterConnect = mockIPC.fetchResourcesCallCount
    #expect(countAfterConnect >= 1)

    // Act: Transition to connecting (simulates reconnection, timer should stop)
    try await mockController.simulateStatusChange(.connecting)

    // Record count immediately after status change
    let countAfterConnecting = mockIPC.fetchResourcesCallCount

    // Wait for what would have been timer intervals
    try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds

    // Assert: No additional fetches occurred during connecting state
    #expect(mockIPC.fetchResourcesCallCount == countAfterConnecting)
  }

  @Test("No duplicate timers when connected status sent twice")
  @MainActor
  func noDuplicateTimersOnDoubleConnected() async throws {
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

    // Act: Send .connected twice in a row (system can do this occasionally)
    try await mockController.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    try await mockController.simulateStatusChange(.connected)  // Second connected

    // Wait for the immediate calls to complete
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    // Record call count after both connected events
    let countAfterDoubleConnect = mockIPC.fetchResourcesCallCount

    // The guard in beginUpdatingResources prevents duplicate timers.
    // First .connected: timer starts, immediate fetch happens
    // Second .connected: guard returns early, no new timer or immediate fetch
    // So we expect exactly 1 immediate fetch, not 2
    #expect(countAfterDoubleConnect == 1)

    // Wait for timer to fire once
    try await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1 seconds

    // Assert: Only one timer is running, call count increased by ~1
    // With duplicate timers, count would increase by ~2 per second
    let countAfterOneSecond = mockIPC.fetchResourcesCallCount
    let callsInInterval = countAfterOneSecond - countAfterDoubleConnect

    // Expect roughly 1 additional call (timer fires every 1s)
    // Allow for some timing variance but should be close to 1, not 2
    #expect(callsInInterval >= 1)
    #expect(callsInInterval <= 2)  // Not 2+ which would indicate duplicate timers
  }

  @Test("Timer restarts after disconnect then reconnect")
  @MainActor
  func timerRestartsAfterReconnect() async throws {
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

    // Act: Connect
    try await mockController.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    let countAfterFirstConnect = mockIPC.fetchResourcesCallCount
    #expect(countAfterFirstConnect >= 1)

    // Act: Disconnect
    try await mockController.simulateStatusChange(.disconnected)
    let countAfterDisconnect = mockIPC.fetchResourcesCallCount

    // Wait and verify no fetches during disconnect
    try await Task.sleep(nanoseconds: 500_000_000)  // 500ms
    #expect(mockIPC.fetchResourcesCallCount == countAfterDisconnect)

    // Act: Reconnect
    try await mockController.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    // Assert: Fetching has resumed (new immediate fetch on reconnect)
    #expect(mockIPC.fetchResourcesCallCount > countAfterDisconnect)

    // Verify timer continues to fire
    let countAfterReconnect = mockIPC.fetchResourcesCallCount
    try await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1 seconds
    #expect(mockIPC.fetchResourcesCallCount > countAfterReconnect)
  }
}
