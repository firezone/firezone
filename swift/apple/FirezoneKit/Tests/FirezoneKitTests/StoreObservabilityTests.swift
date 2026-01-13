//
//  StoreObservabilityTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import NetworkExtension
import Testing

@testable import FirezoneKit

/// Tests that verify Store can be observed by SwiftUI views when all dependencies are mocked.
/// These tests ensure UI testing is possible without real system access.
@Suite("Store Observability Tests")
struct StoreObservabilityTests {

  @Test("Store with mocked dependencies is observable")
  @MainActor
  func storeIsObservable() async throws {
    // Arrange - create Store with all mocked dependencies
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockNotification = MockSessionNotification()

    #if os(macOS)
      let mockSysExt = MockSystemExtensionManager()
      let store = Store(
        configuration: config,
        tunnelController: mockController,
        sessionNotification: mockNotification,
        systemExtensionManager: mockSysExt,
        userDefaults: defaults
      )
    #else
      let store = Store(
        configuration: config,
        tunnelController: mockController,
        sessionNotification: mockNotification,
        userDefaults: defaults
      )
    #endif

    // Act - subscribe to objectWillChange
    var changeCount = 0
    var cancellables = Set<AnyCancellable>()
    store.objectWillChange
      .sink { _ in changeCount += 1 }
      .store(in: &cancellables)

    // Trigger a change via sign-in
    let authResponse = AuthResponse(
      actorName: "Test User",
      accountSlug: "test-slug",
      token: "test-token"
    )
    try await store.signIn(authResponse: authResponse)

    // Assert - Store emits objectWillChange when state changes
    #expect(changeCount > 0, "Store should emit objectWillChange when signing in")
  }

  #if os(macOS)
    @Test("MockSystemExtensionManager returns configured status")
    @MainActor
    func mockSystemExtensionReturnsConfiguredStatus() async throws {
      // Arrange
      let mockSysExt = MockSystemExtensionManager()
      mockSysExt.checkStatusResult = .needsInstall

      // Act
      let status = try await mockSysExt.checkStatus()

      // Assert
      #expect(status == .needsInstall)
      #expect(mockSysExt.checkStatusCallCount == 1)
    }

    @Test("Store uses injected SystemExtensionManager")
    @MainActor
    func storeUsesInjectedSystemExtensionManager() async throws {
      // Arrange
      let defaults = makeTestDefaults()
      let config = Configuration(userDefaults: defaults)
      let mockController = MockTunnelController()
      let mockSysExt = MockSystemExtensionManager()
      mockSysExt.checkStatusResult = .installed

      _ = Store(
        configuration: config,
        tunnelController: mockController,
        sessionNotification: MockSessionNotification(),
        systemExtensionManager: mockSysExt,
        userDefaults: defaults
      )

      // Store init calls checkStatus automatically
      // Give time for the async init to complete
      try await Task.sleep(for: .milliseconds(100))

      // Assert - the mock was called during Store initialization
      #expect(
        mockSysExt.checkStatusCallCount >= 1, "Store should check system extension status on init")
    }
  #endif
}
