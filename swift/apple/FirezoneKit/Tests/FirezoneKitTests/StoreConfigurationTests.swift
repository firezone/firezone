//
//  StoreConfigurationTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("Store Configuration Propagation Tests")
struct StoreConfigurationTests {

  // MARK: - Configuration Change Triggers IPC

  @Test("Config change triggers setConfiguration call")
  @MainActor
  func configChangeTriggerSetConfiguration() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Initial call count should be 0
    #expect(mockController.setConfigurationCallCount == 0)

    // Act: Change a configuration property
    config.logFilter = "trace"

    // Wait for debounce (0.3s) + processing time + scheduling overhead
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: setConfiguration was called
    #expect(mockController.setConfigurationCallCount == 1)
    #expect(mockController.lastConfiguration?.logFilter == "trace")

    withExtendedLifetime(store) {}
  }

  @Test("Different config properties trigger setConfiguration")
  @MainActor
  func differentConfigPropertiesTriggerSetConfiguration() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Act: Change apiURL
    config.apiURL = "wss://test.example.com"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert
    #expect(mockController.setConfigurationCallCount == 1)
    #expect(mockController.lastConfiguration?.apiURL == "wss://test.example.com")

    // Act: Change accountSlug
    config.accountSlug = "test-account"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Second call was made
    #expect(mockController.setConfigurationCallCount == 2)
    #expect(mockController.lastConfiguration?.accountSlug == "test-account")

    withExtendedLifetime(store) {}
  }

  @Test("InternetResourceEnabled change triggers setConfiguration")
  @MainActor
  func internetResourceEnabledChangeTriggers() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Act: Enable internet resource
    config.internetResourceEnabled = true

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert
    #expect(mockController.setConfigurationCallCount == 1)
    #expect(mockController.lastConfiguration?.internetResourceEnabled == true)

    withExtendedLifetime(store) {}
  }

  // MARK: - Unchanged Config Doesn't Trigger IPC

  @Test("Unchanged config doesn't trigger redundant IPC call")
  @MainActor
  func unchangedConfigNoRedundantIPC() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Act: Change config to trigger first call
    config.logFilter = "warn"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: First call made
    #expect(mockController.setConfigurationCallCount == 1)
    let countAfterFirst = mockController.setConfigurationCallCount

    // Act: Set the same value again (this triggers objectWillChange but same TunnelConfiguration)
    config.logFilter = "warn"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: No additional call (config unchanged)
    #expect(mockController.setConfigurationCallCount == countAfterFirst)

    withExtendedLifetime(store) {}
  }

  @Test("Setting default values doesn't trigger IPC when already default")
  @MainActor
  func settingDefaultValuesNoIPC() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Get the current default logFilter
    let defaultLogFilter = config.logFilter

    // Act: Set to a different value first
    config.logFilter = "error"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 800_000_000)
    #expect(mockController.setConfigurationCallCount == 1)

    // Act: Set back to default
    config.logFilter = defaultLogFilter

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Second call was made (because value changed back)
    #expect(mockController.setConfigurationCallCount == 2)

    // Act: Set to default again (same value)
    config.logFilter = defaultLogFilter

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: No third call (config unchanged)
    #expect(mockController.setConfigurationCallCount == 2)

    withExtendedLifetime(store) {}
  }

  // MARK: - Debouncing Tests

  @Test("Multiple rapid config changes are debounced")
  @MainActor
  func rapidChangesDebounced() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Act: Make multiple rapid changes within the debounce window (0.3s)
    config.logFilter = "debug"
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    config.logFilter = "info"
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    config.logFilter = "warn"
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    config.logFilter = "error"

    // Wait for debounce to settle (0.3s) + processing time
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Only one IPC call was made (debounced)
    #expect(mockController.setConfigurationCallCount == 1)
    // The final value should be used
    #expect(mockController.lastConfiguration?.logFilter == "error")

    withExtendedLifetime(store) {}
  }

  @Test("Changes separated by debounce window trigger multiple calls")
  @MainActor
  func separatedChangesNotDebounced() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Act: Make a change
    config.logFilter = "debug"

    // Wait longer than debounce window (0.3s)
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: First call made
    #expect(mockController.setConfigurationCallCount == 1)
    #expect(mockController.lastConfiguration?.logFilter == "debug")

    // Act: Make another change after the debounce window
    config.logFilter = "error"

    // Wait for second debounce + processing
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Second call made
    #expect(mockController.setConfigurationCallCount == 2)
    #expect(mockController.lastConfiguration?.logFilter == "error")

    withExtendedLifetime(store) {}
  }

  @Test("Burst of different property changes debounced together")
  @MainActor
  func burstDifferentPropertiesDebounced() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Act: Change multiple different properties rapidly
    config.logFilter = "trace"
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    config.accountSlug = "new-account"
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    config.internetResourceEnabled = true

    // Wait for debounce to settle
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Only one IPC call was made containing all changes
    #expect(mockController.setConfigurationCallCount == 1)
    #expect(mockController.lastConfiguration?.logFilter == "trace")
    #expect(mockController.lastConfiguration?.accountSlug == "new-account")
    #expect(mockController.lastConfiguration?.internetResourceEnabled == true)

    withExtendedLifetime(store) {}
  }

  // MARK: - Edge Cases

  @Test("Config changes when tunnel controller throws are silently ignored")
  @MainActor
  func configChangesWhenTunnelThrowsIgnored() async throws {
    // This test verifies that config changes don't crash when tunnel throws.
    // In production, setConfiguration can throw if the tunnel isn't ready yet.
    // The Store should handle this gracefully without crashing.

    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    // Simulate tunnel not ready by making setConfiguration throw
    mockController.setConfigurationError = TestError.simulatedFailure

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Act: Change config (should not crash despite setConfiguration throwing)
    config.logFilter = "trace"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Call was attempted but error was silently handled
    #expect(mockController.setConfigurationCallCount == 1)

    // The Store should still be functional - verify by making another change
    // after "fixing" the tunnel controller
    mockController.setConfigurationError = nil
    config.logFilter = "debug"

    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Second call succeeded
    #expect(mockController.setConfigurationCallCount == 2)
    #expect(mockController.lastConfiguration?.logFilter == "debug")

    withExtendedLifetime(store) {}
  }
}
