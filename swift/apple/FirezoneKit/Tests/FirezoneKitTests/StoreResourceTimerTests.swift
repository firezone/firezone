//
//  StoreResourceTimerTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("Store Resource Timer Lifecycle Tests")
struct StoreResourceTimerTests {

  @Test("Timer starts on connected status - resource fetching begins")
  @MainActor
  func timerStartsOnConnected() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()

    // Return valid data so fetches succeed
    let resources = [makeResource(id: "1", name: "Test Resource")]
    mockController.fetchResourcesResponse = try encodeResources(resources)

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Verify no fetches yet
    #expect(mockController.fetchResourcesCallCount == 0)

    // Act: Simulate VPN connecting then connected
    try await mockController.simulateStatusChange(.connected)

    // beginUpdatingResources fires immediately, so we should see at least one call
    // Wait a small amount for the immediate call to complete
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    // Assert: At least one fetch has occurred (immediate call on connect)
    #expect(mockController.fetchResourcesCallCount >= 1)

    // Wait for timer to fire at least once more (timer interval is 1 second)
    let initialCount = mockController.fetchResourcesCallCount
    try await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1 seconds

    // Assert: Timer has fired additional times
    #expect(mockController.fetchResourcesCallCount > initialCount)

    withExtendedLifetime(store) {}
  }

  @Test("Timer stops on disconnected status - resource fetching stops")
  @MainActor
  func timerStopsOnDisconnected() async throws {
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

    // Act: Start connected (timer begins)
    try await mockController.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms for immediate fetch

    let countAfterConnect = mockController.fetchResourcesCallCount
    #expect(countAfterConnect >= 1)

    // Act: Disconnect (timer should stop)
    try await mockController.simulateStatusChange(.disconnected)

    // Record count immediately after disconnect
    let countAfterDisconnect = mockController.fetchResourcesCallCount

    // Wait for what would have been timer intervals
    try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds

    // Assert: No additional fetches occurred after disconnect
    #expect(mockController.fetchResourcesCallCount == countAfterDisconnect)

    withExtendedLifetime(store) {}
  }

  @Test("Timer stops on connecting status - resource fetching stops during reconnection")
  @MainActor
  func timerStopsOnConnecting() async throws {
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

    // Act: Start connected (timer begins)
    try await mockController.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms for immediate fetch

    let countAfterConnect = mockController.fetchResourcesCallCount
    #expect(countAfterConnect >= 1)

    // Act: Transition to connecting (simulates reconnection, timer should stop)
    try await mockController.simulateStatusChange(.connecting)

    // Record count immediately after status change
    let countAfterConnecting = mockController.fetchResourcesCallCount

    // Wait for what would have been timer intervals
    try await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds

    // Assert: No additional fetches occurred during connecting state
    #expect(mockController.fetchResourcesCallCount == countAfterConnecting)

    withExtendedLifetime(store) {}
  }

  @Test("No duplicate timers when connected status sent twice")
  @MainActor
  func noDuplicateTimersOnDoubleConnected() async throws {
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

    // Act: Send .connected twice in a row (system can do this occasionally)
    try await mockController.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    try await mockController.simulateStatusChange(.connected)  // Second connected

    // Wait for the immediate calls to complete
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    // Record call count after both connected events
    let countAfterDoubleConnect = mockController.fetchResourcesCallCount

    // The guard in beginUpdatingResources prevents duplicate timers.
    // First .connected: timer starts, immediate fetch happens
    // Second .connected: guard returns early, no new timer or immediate fetch
    // So we expect exactly 1 immediate fetch, not 2
    #expect(countAfterDoubleConnect == 1)

    // Wait for timer to fire once
    try await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1 seconds

    // Assert: Only one timer is running, call count increased by ~1
    // With duplicate timers, count would increase by ~2 per second
    let countAfterOneSecond = mockController.fetchResourcesCallCount
    let callsInInterval = countAfterOneSecond - countAfterDoubleConnect

    // Expect roughly 1 additional call (timer fires every 1s)
    // Allow for some timing variance but should be close to 1, not 2
    #expect(callsInInterval >= 1)
    #expect(callsInInterval <= 2)  // Not 2+ which would indicate duplicate timers

    withExtendedLifetime(store) {}
  }

  @Test("Timer restarts after disconnect then reconnect")
  @MainActor
  func timerRestartsAfterReconnect() async throws {
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

    // Act: Connect
    try await mockController.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    let countAfterFirstConnect = mockController.fetchResourcesCallCount
    #expect(countAfterFirstConnect >= 1)

    // Act: Disconnect
    try await mockController.simulateStatusChange(.disconnected)
    let countAfterDisconnect = mockController.fetchResourcesCallCount

    // Wait and verify no fetches during disconnect
    try await Task.sleep(nanoseconds: 500_000_000)  // 500ms
    #expect(mockController.fetchResourcesCallCount == countAfterDisconnect)

    // Act: Reconnect
    try await mockController.simulateStatusChange(.connected)
    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

    // Assert: Fetching has resumed (new immediate fetch on reconnect)
    #expect(mockController.fetchResourcesCallCount > countAfterDisconnect)

    // Verify timer continues to fire
    let countAfterReconnect = mockController.fetchResourcesCallCount
    try await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1 seconds
    #expect(mockController.fetchResourcesCallCount > countAfterReconnect)

    withExtendedLifetime(store) {}
  }
}
