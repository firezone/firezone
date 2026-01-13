//
//  StoreSignInTests.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@Suite("Store Sign-In Tests")
struct StoreSignInTests {

  // Each test gets a unique UserDefaults suite for isolation
  private func makeTestDefaults() -> UserDefaults {
    let suiteName = "dev.firezone.firezone.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("Token is passed to IPC client when signing in")
  @MainActor
  func tokenPassedToIPC() async throws {
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

    let authResponse = AuthResponse(
      actorName: "Test Actor",
      accountSlug: "test-account",
      token: "secret-auth-token-12345"
    )

    // Act
    try await store.signIn(authResponse: authResponse)

    // Assert
    #expect(mockIPC.startCallCount == 1)
    #expect(mockIPC.lastStartToken == "secret-auth-token-12345")
  }

  @Test("Actor name is saved after sign-in")
  @MainActor
  func actorNameSaved() async throws {
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

    // Initial state
    #expect(store.actorName == "Test User")

    let authResponse = AuthResponse(
      actorName: "Alice Smith",
      accountSlug: "acme-corp",
      token: "token-xyz"
    )

    // Act
    try await store.signIn(authResponse: authResponse)

    // Assert
    #expect(store.actorName == "Alice Smith")
  }

  @Test("Shown alert IDs are cleared on sign-in")
  @MainActor
  func alertIdsClearedOnSignIn() async throws {
    // Arrange: Pre-populate shown alert IDs in UserDefaults
    let defaults = makeTestDefaults()
    defaults.set(["alert-1", "alert-2", "alert-3"], forKey: "shownAlertIds")

    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let mockIPC = MockIPCClient()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      ipcClient: mockIPC,
      userDefaults: defaults
    )

    // Verify initial state has pre-populated alerts
    #expect(store.testShownAlertIdsIsEmpty() == false)

    let authResponse = AuthResponse(
      actorName: "Bob Jones",
      accountSlug: "example-org",
      token: "token-abc"
    )

    // Act
    try await store.signIn(authResponse: authResponse)

    // Assert: Alert IDs should be cleared for fresh session
    #expect(store.testShownAlertIdsIsEmpty() == true)
  }

  @Test("Account slug is saved to configuration on sign-in")
  @MainActor
  func accountSlugSaved() async throws {
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

    // Initial state
    #expect(config.accountSlug == "")

    let authResponse = AuthResponse(
      actorName: "Charlie Brown",
      accountSlug: "peanuts-inc",
      token: "token-123"
    )

    // Act
    try await store.signIn(authResponse: authResponse)

    // Assert
    #expect(config.accountSlug == "peanuts-inc")
  }
}
