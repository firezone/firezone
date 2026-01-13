//
//  StoreConnectionTests.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("Store Connection Recovery Tests")
struct StoreConnectionTests {

  // Each test gets a unique UserDefaults suite for isolation
  private func makeTestDefaults() -> UserDefaults {
    let suiteName = "dev.firezone.firezone.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("Watchdog restarts tunnel when stuck in connecting state")
  @MainActor
  func watchdogRestartsTunnel() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC
    )

    // Use short timeout for test (100ms instead of 10s)
    store.setWatchdogTimeout(100_000_000)

    // Act: Simulate getting stuck in .connecting
    try await mockController.simulateStatusChange(.connecting)

    // Wait for watchdog to fire: 100ms watchdog + 500ms callback delay + 200ms margin
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Tunnel was restarted
    #expect(mockController.mockSession.stopCallCount == 1)
    #expect(mockController.startCallCount == 1)
  }

  @Test("No restart if connection succeeds before timeout")
  @MainActor
  func noRestartIfConnected() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC
    )
    store.setWatchdogTimeout(200_000_000)  // 200ms

    // Act: Start connecting, then succeed before timeout
    try await mockController.simulateStatusChange(.connecting)
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms - before timeout
    try await mockController.simulateStatusChange(.connected)

    // Wait past the original timeout
    try await Task.sleep(nanoseconds: 300_000_000)

    // Assert: No restart occurred
    #expect(mockController.mockSession.stopCallCount == 0)
    #expect(mockController.startCallCount == 0)
  }

  @Test("Watchdog cancelled on disconnect")
  @MainActor
  func watchdogCancelledOnDisconnect() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC
    )
    store.setWatchdogTimeout(200_000_000)  // 200ms

    // Act: Start connecting, then disconnect before timeout
    try await mockController.simulateStatusChange(.connecting)
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    try await mockController.simulateStatusChange(.disconnected)

    // Wait past the original timeout
    try await Task.sleep(nanoseconds: 300_000_000)

    // Assert: No restart occurred (watchdog was cancelled)
    #expect(mockController.mockSession.stopCallCount == 0)
    #expect(mockController.startCallCount == 0)
  }
}
