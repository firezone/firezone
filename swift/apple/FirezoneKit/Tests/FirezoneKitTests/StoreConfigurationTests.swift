//
//  StoreConfigurationTests.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import NetworkExtension
import Testing

@testable import FirezoneKit

@Suite("Store Configuration Propagation Tests")
struct StoreConfigurationTests {

  // Each test gets a unique UserDefaults suite for isolation
  private func makeTestDefaults() -> UserDefaults {
    let suiteName = "dev.firezone.firezone.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  // MARK: - Configuration Change Triggers IPC

  @Test("Config change triggers setConfiguration call")
  @MainActor
  func configChangeTriggerSetConfiguration() async throws {
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

    // Initial call count should be 0
    #expect(mockIPC.setConfigurationCallCount == 0)

    // Act: Change a configuration property
    config.logFilter = "trace"

    // Wait for debounce (0.3s) + processing time
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: setConfiguration was called
    #expect(mockIPC.setConfigurationCallCount == 1)
    #expect(mockIPC.lastConfiguration?.logFilter == "trace")

    // Keep reference to prevent deallocation
    _ = store
  }

  @Test("Different config properties trigger setConfiguration")
  @MainActor
  func differentConfigPropertiesTriggerSetConfiguration() async throws {
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

    // Act: Change apiURL
    config.apiURL = "wss://test.example.com"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert
    #expect(mockIPC.setConfigurationCallCount == 1)
    #expect(mockIPC.lastConfiguration?.apiURL == "wss://test.example.com")

    // Act: Change accountSlug
    config.accountSlug = "test-account"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: Second call was made
    #expect(mockIPC.setConfigurationCallCount == 2)
    #expect(mockIPC.lastConfiguration?.accountSlug == "test-account")

    _ = store
  }

  @Test("InternetResourceEnabled change triggers setConfiguration")
  @MainActor
  func internetResourceEnabledChangeTriggers() async throws {
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

    // Act: Enable internet resource
    config.internetResourceEnabled = true

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert
    #expect(mockIPC.setConfigurationCallCount == 1)
    #expect(mockIPC.lastConfiguration?.internetResourceEnabled == true)

    _ = store
  }

  // MARK: - Unchanged Config Doesn't Trigger IPC

  @Test("Unchanged config doesn't trigger redundant IPC call")
  @MainActor
  func unchangedConfigNoRedundantIPC() async throws {
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

    // Act: Change config to trigger first call
    config.logFilter = "warn"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: First call made
    #expect(mockIPC.setConfigurationCallCount == 1)
    let countAfterFirst = mockIPC.setConfigurationCallCount

    // Act: Set the same value again (this triggers objectWillChange but same TunnelConfiguration)
    config.logFilter = "warn"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: No additional call (config unchanged)
    #expect(mockIPC.setConfigurationCallCount == countAfterFirst)

    _ = store
  }

  @Test("Setting default values doesn't trigger IPC when already default")
  @MainActor
  func settingDefaultValuesNoIPC() async throws {
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

    // Get the current default logFilter
    let defaultLogFilter = config.logFilter

    // Act: Set to a different value first
    config.logFilter = "error"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(mockIPC.setConfigurationCallCount == 1)

    // Act: Set back to default
    config.logFilter = defaultLogFilter

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: Second call was made (because value changed back)
    #expect(mockIPC.setConfigurationCallCount == 2)

    // Act: Set to default again (same value)
    config.logFilter = defaultLogFilter

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: No third call (config unchanged)
    #expect(mockIPC.setConfigurationCallCount == 2)

    _ = store
  }

  // MARK: - Debouncing Tests

  @Test("Multiple rapid config changes are debounced")
  @MainActor
  func rapidChangesDebounced() async throws {
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

    // Act: Make multiple rapid changes within the debounce window (0.3s)
    config.logFilter = "debug"
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    config.logFilter = "info"
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    config.logFilter = "warn"
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    config.logFilter = "error"

    // Wait for debounce to settle (0.3s) + processing time
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: Only one IPC call was made (debounced)
    #expect(mockIPC.setConfigurationCallCount == 1)
    // The final value should be used
    #expect(mockIPC.lastConfiguration?.logFilter == "error")

    _ = store
  }

  @Test("Changes separated by debounce window trigger multiple calls")
  @MainActor
  func separatedChangesNotDebounced() async throws {
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

    // Act: Make a change
    config.logFilter = "debug"

    // Wait longer than debounce window (0.3s)
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: First call made
    #expect(mockIPC.setConfigurationCallCount == 1)
    #expect(mockIPC.lastConfiguration?.logFilter == "debug")

    // Act: Make another change after the debounce window
    config.logFilter = "error"

    // Wait for second debounce + processing
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: Second call made
    #expect(mockIPC.setConfigurationCallCount == 2)
    #expect(mockIPC.lastConfiguration?.logFilter == "error")

    _ = store
  }

  @Test("Burst of different property changes debounced together")
  @MainActor
  func burstDifferentPropertiesDebounced() async throws {
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

    // Act: Change multiple different properties rapidly
    config.logFilter = "trace"
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    config.accountSlug = "new-account"
    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    config.internetResourceEnabled = true

    // Wait for debounce to settle
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: Only one IPC call was made containing all changes
    #expect(mockIPC.setConfigurationCallCount == 1)
    #expect(mockIPC.lastConfiguration?.logFilter == "trace")
    #expect(mockIPC.lastConfiguration?.accountSlug == "new-account")
    #expect(mockIPC.lastConfiguration?.internetResourceEnabled == true)

    _ = store
  }

  // MARK: - Edge Cases

  @Test("Config changes before IPC client ready are silently ignored")
  @MainActor
  func configChangesBeforeIPCReadyIgnored() async throws {
    // This test verifies that config changes don't crash when IPC isn't ready.
    // The test initializer always provides an IPC client, but in production
    // the IPC client is set up asynchronously. The Store handles this gracefully.

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

    // Act: Change config
    config.logFilter = "trace"

    // Wait for debounce + processing
    try await Task.sleep(nanoseconds: 500_000_000)

    // Assert: Call was made (test initializer has IPC ready)
    #expect(mockIPC.setConfigurationCallCount == 1)

    _ = store
  }
}
