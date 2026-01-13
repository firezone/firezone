//
//  StoreSignInTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@Suite("Store Sign-In Tests")
struct StoreSignInTests {

  @Test("Token is passed to tunnel controller when signing in")
  @MainActor
  func tokenPassedToTunnelController() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    let authResponse = AuthResponse(
      actorName: "Test Actor",
      accountSlug: "test-account",
      token: "secret-auth-token-12345"
    )

    // Act
    try await store.signIn(authResponse: authResponse)

    // Assert
    #expect(mockController.startCallCount == 1)
    #expect(mockController.lastStartToken == "secret-auth-token-12345")
  }

  @Test("Actor name is saved after sign-in")
  @MainActor
  func actorNameSaved() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification(),
      userDefaults: defaults
    )

    // Initial state
    #expect(store.actorName == "Unknown user")

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
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification(),
      userDefaults: defaults
    )

    // Verify initial state has pre-populated alerts
    #expect(store.shownAlertIds.isEmpty == false)

    let authResponse = AuthResponse(
      actorName: "Bob Jones",
      accountSlug: "example-org",
      token: "token-abc"
    )

    // Act
    try await store.signIn(authResponse: authResponse)

    // Assert: Alert IDs should be cleared for fresh session
    #expect(store.shownAlertIds.isEmpty == true)
  }

  @Test("Account slug is saved to configuration on sign-in")
  @MainActor
  func accountSlugSaved() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
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

  @Test("Enable is called before start on sign-in")
  @MainActor
  func enableCalledBeforeStart() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    let authResponse = AuthResponse(
      actorName: "Test User",
      accountSlug: "test-account",
      token: "token-123"
    )

    // Act
    try await store.signIn(authResponse: authResponse)

    // Assert: Both enable and start were called in correct order
    #expect(mockController.enableCallCount == 1)
    #expect(mockController.startCallCount == 1)

    // Verify enable comes before start in the call log
    let enableIndex = mockController.callLog.firstIndex(of: .enable)
    let startIndex = mockController.callLog.firstIndex(where: {
      if case .startWithToken = $0 { return true }
      return false
    })
    guard let enableIdx = enableIndex, let startIdx = startIndex else {
      Issue.record("enable and start should both have been called")
      return
    }
    #expect(enableIdx < startIdx, "enable must be called before start")
  }

  // MARK: - Error Path Tests

  @Test("Sign-in throws when enable fails")
  @MainActor
  func signInThrowsWhenEnableFails() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    mockController.enableError = TestError.simulatedFailure

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    let authResponse = AuthResponse(
      actorName: "Test User",
      accountSlug: "test-account",
      token: "token-123"
    )

    // Act & Assert
    await #expect(throws: TestError.self) {
      try await store.signIn(authResponse: authResponse)
    }

    // Assert: enable was called but start was not (failed before start)
    #expect(mockController.enableCallCount == 1)
    #expect(mockController.startCallCount == 0)
  }

  @Test("Sign-in throws when start fails")
  @MainActor
  func signInThrowsWhenStartFails() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    mockController.startError = TestError.simulatedFailure

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    let authResponse = AuthResponse(
      actorName: "Test User",
      accountSlug: "test-account",
      token: "token-123"
    )

    // Act & Assert
    await #expect(throws: TestError.self) {
      try await store.signIn(authResponse: authResponse)
    }

    // Assert: both enable and start were called (failed during start)
    #expect(mockController.enableCallCount == 1)
    #expect(mockController.startCallCount == 1)
  }

  // MARK: - Sign-Out Tests

  @Test("Sign-out calls tunnel controller signOut")
  @MainActor
  func signOutCallsTunnelController() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Act
    try await store.signOut()

    // Assert
    #expect(mockController.signOutCallCount == 1)
  }

  @Test("Sign-out throws when tunnel controller fails")
  @MainActor
  func signOutThrowsOnFailure() async throws {
    // Arrange
    let defaults = makeTestDefaults()
    let config = Configuration(userDefaults: defaults)
    let mockController = MockTunnelController()
    mockController.signOutError = TestError.simulatedFailure

    let store = Store(
      configuration: config,
      tunnelController: mockController,
      sessionNotification: MockSessionNotification()
    )

    // Act & Assert
    await #expect(throws: TestError.self) {
      try await store.signOut()
    }

    // Assert: signOut was attempted
    #expect(mockController.signOutCallCount == 1)
  }
}
