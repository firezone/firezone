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
    let fixture = makeMockStore()
    #expect(fixture.controller.setConfigurationCallCount == 0)

    // Act
    fixture.config.logFilter = "trace"
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert
    #expect(fixture.controller.setConfigurationCallCount == 1)
    #expect(fixture.controller.lastConfiguration?.logFilter == "trace")

    withExtendedLifetime(fixture.store) {}
  }

  @Test("Different config properties trigger setConfiguration")
  @MainActor
  func differentConfigPropertiesTriggerSetConfiguration() async throws {
    // Arrange
    let fixture = makeMockStore()

    // Act & Assert: Change apiURL
    fixture.config.apiURL = "wss://test.example.com"
    try await Task.sleep(nanoseconds: 800_000_000)

    #expect(fixture.controller.setConfigurationCallCount == 1)
    #expect(fixture.controller.lastConfiguration?.apiURL == "wss://test.example.com")

    // Act & Assert: Change accountSlug
    fixture.config.accountSlug = "test-account"
    try await Task.sleep(nanoseconds: 800_000_000)

    #expect(fixture.controller.setConfigurationCallCount == 2)
    #expect(fixture.controller.lastConfiguration?.accountSlug == "test-account")

    withExtendedLifetime(fixture.store) {}
  }

  @Test("InternetResourceEnabled change triggers setConfiguration")
  @MainActor
  func internetResourceEnabledChangeTriggers() async throws {
    // Arrange
    let fixture = makeMockStore()

    // Act
    fixture.config.internetResourceEnabled = true
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert
    #expect(fixture.controller.setConfigurationCallCount == 1)
    #expect(fixture.controller.lastConfiguration?.internetResourceEnabled == true)

    withExtendedLifetime(fixture.store) {}
  }

  // MARK: - Unchanged Config Doesn't Trigger IPC

  @Test("Unchanged config doesn't trigger redundant IPC call")
  @MainActor
  func unchangedConfigNoRedundantIPC() async throws {
    // Arrange
    let fixture = makeMockStore()

    // Act: First change
    fixture.config.logFilter = "warn"
    try await Task.sleep(nanoseconds: 800_000_000)
    #expect(fixture.controller.setConfigurationCallCount == 1)
    let countAfterFirst = fixture.controller.setConfigurationCallCount

    // Act: Set the same value again
    fixture.config.logFilter = "warn"
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: No additional call (config unchanged)
    #expect(fixture.controller.setConfigurationCallCount == countAfterFirst)

    withExtendedLifetime(fixture.store) {}
  }

  @Test("Setting default values doesn't trigger IPC when already default")
  @MainActor
  func settingDefaultValuesNoIPC() async throws {
    // Arrange
    let fixture = makeMockStore()
    let defaultLogFilter = fixture.config.logFilter

    // Act: Set to a different value first
    fixture.config.logFilter = "error"
    try await Task.sleep(nanoseconds: 800_000_000)
    #expect(fixture.controller.setConfigurationCallCount == 1)

    // Act: Set back to default
    fixture.config.logFilter = defaultLogFilter
    try await Task.sleep(nanoseconds: 800_000_000)
    #expect(fixture.controller.setConfigurationCallCount == 2)

    // Act: Set to default again (same value) - no new call
    fixture.config.logFilter = defaultLogFilter
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert
    #expect(fixture.controller.setConfigurationCallCount == 2)

    withExtendedLifetime(fixture.store) {}
  }

  // MARK: - Debouncing Tests

  @Test("Multiple rapid config changes are debounced")
  @MainActor
  func rapidChangesDebounced() async throws {
    // Arrange
    let fixture = makeMockStore()

    // Act: Make multiple rapid changes within the debounce window (0.3s)
    fixture.config.logFilter = "debug"
    try await Task.sleep(nanoseconds: 50_000_000)
    fixture.config.logFilter = "info"
    try await Task.sleep(nanoseconds: 50_000_000)
    fixture.config.logFilter = "warn"
    try await Task.sleep(nanoseconds: 50_000_000)
    fixture.config.logFilter = "error"

    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Only one IPC call was made (debounced), using final value
    #expect(fixture.controller.setConfigurationCallCount == 1)
    #expect(fixture.controller.lastConfiguration?.logFilter == "error")

    withExtendedLifetime(fixture.store) {}
  }

  @Test("Changes separated by debounce window trigger multiple calls")
  @MainActor
  func separatedChangesNotDebounced() async throws {
    // Arrange
    let fixture = makeMockStore()

    // Act & Assert: First change
    fixture.config.logFilter = "debug"
    try await Task.sleep(nanoseconds: 800_000_000)
    #expect(fixture.controller.setConfigurationCallCount == 1)
    #expect(fixture.controller.lastConfiguration?.logFilter == "debug")

    // Act & Assert: Second change after debounce window
    fixture.config.logFilter = "error"
    try await Task.sleep(nanoseconds: 800_000_000)
    #expect(fixture.controller.setConfigurationCallCount == 2)
    #expect(fixture.controller.lastConfiguration?.logFilter == "error")

    withExtendedLifetime(fixture.store) {}
  }

  @Test("Burst of different property changes debounced together")
  @MainActor
  func burstDifferentPropertiesDebounced() async throws {
    // Arrange
    let fixture = makeMockStore()

    // Act: Change multiple different properties rapidly
    fixture.config.logFilter = "trace"
    try await Task.sleep(nanoseconds: 50_000_000)
    fixture.config.accountSlug = "new-account"
    try await Task.sleep(nanoseconds: 50_000_000)
    fixture.config.internetResourceEnabled = true

    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Only one IPC call was made containing all changes
    #expect(fixture.controller.setConfigurationCallCount == 1)
    #expect(fixture.controller.lastConfiguration?.logFilter == "trace")
    #expect(fixture.controller.lastConfiguration?.accountSlug == "new-account")
    #expect(fixture.controller.lastConfiguration?.internetResourceEnabled == true)

    withExtendedLifetime(fixture.store) {}
  }

  // MARK: - Edge Cases

  @Test("Config changes when tunnel controller throws are silently ignored")
  @MainActor
  func configChangesWhenTunnelThrowsIgnored() async throws {
    // This test verifies that config changes don't crash when tunnel throws.
    // In production, setConfiguration can throw if the tunnel isn't ready yet.
    // The Store should handle this gracefully without crashing.

    // Arrange
    let fixture = makeMockStore { controller, _ in
      controller.setConfigurationError = TestError.simulatedFailure
    }

    // Act: Change config (should not crash despite setConfiguration throwing)
    fixture.config.logFilter = "trace"
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Call was attempted but error was silently handled
    #expect(fixture.controller.setConfigurationCallCount == 1)

    // Act: Fix the error and verify Store still works
    fixture.controller.setConfigurationError = nil
    fixture.config.logFilter = "debug"
    try await Task.sleep(nanoseconds: 800_000_000)

    // Assert: Second call succeeded
    #expect(fixture.controller.setConfigurationCallCount == 2)
    #expect(fixture.controller.lastConfiguration?.logFilter == "debug")

    withExtendedLifetime(fixture.store) {}
  }
}
