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
    let fixture = try await makeMockStore()

    let authResponse = AuthResponse(
      actorName: "Test Actor",
      accountSlug: "test-account",
      token: "secret-auth-token-12345"
    )

    try await fixture.store.signIn(authResponse: authResponse)

    // Verify token was passed correctly (implies start was called)
    #expect(fixture.controller.lastStartToken == "secret-auth-token-12345")
  }

  @Test("Actor name is saved after sign-in")
  @MainActor
  func actorNameSaved() async throws {
    let fixture = try await makeMockStore()

    // Initial state
    #expect(fixture.store.actorName == "Unknown user")

    let authResponse = AuthResponse(
      actorName: "Alice Smith",
      accountSlug: "acme-corp",
      token: "token-xyz"
    )

    try await fixture.store.signIn(authResponse: authResponse)

    #expect(fixture.store.actorName == "Alice Smith")
  }

  @Test("Shown alert IDs are cleared on sign-in")
  @MainActor
  func alertIdsClearedOnSignIn() async throws {
    // Pre-populate shown alert IDs in UserDefaults before creating fixture
    let defaults = makeTestDefaults()
    defaults.set(["alert-1", "alert-2", "alert-3"], forKey: "shownAlertIds")

    let config = Configuration(userDefaults: defaults)
    let controller = MockTunnelController()
    let notification = MockSessionNotification()

    #if os(macOS)
      let systemExtension = MockSystemExtensionManager()
      let store = Store(
        configuration: config,
        tunnelController: controller,
        sessionNotification: notification,
        systemExtensionManager: systemExtension,
        userDefaults: defaults
      )
    #else
      let store = Store(
        configuration: config,
        tunnelController: controller,
        sessionNotification: notification,
        userDefaults: defaults
      )
    #endif

    // Verify initial state has pre-populated alerts
    #expect(store.shownAlertIds.isEmpty == false)

    let authResponse = AuthResponse(
      actorName: "Bob Jones",
      accountSlug: "example-org",
      token: "token-abc"
    )

    try await store.signIn(authResponse: authResponse)

    // Alert IDs should be cleared for fresh session
    #expect(store.shownAlertIds.isEmpty == true)
  }

  @Test("Account slug is saved to configuration on sign-in")
  @MainActor
  func accountSlugSaved() async throws {
    let fixture = try await makeMockStore()

    // Initial state
    #expect(fixture.config.accountSlug == "")

    let authResponse = AuthResponse(
      actorName: "Charlie Brown",
      accountSlug: "peanuts-inc",
      token: "token-123"
    )

    try await fixture.store.signIn(authResponse: authResponse)

    #expect(fixture.config.accountSlug == "peanuts-inc")
  }

  @Test("Enable is called before start on sign-in")
  @MainActor
  func enableCalledBeforeStart() async throws {
    let fixture = try await makeMockStore()

    let authResponse = AuthResponse(
      actorName: "Test User",
      accountSlug: "test-account",
      token: "token-123"
    )

    try await fixture.store.signIn(authResponse: authResponse)

    // Both enable and start were called in correct order
    #expect(fixture.controller.enableCallCount == 1)
    #expect(fixture.controller.startCallCount == 1)

    // Verify enable comes before start in the call log
    let enableIndex = fixture.controller.callLog.firstIndex(of: .enable)
    let startIndex = fixture.controller.callLog.firstIndex(where: {
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
    let fixture = try await makeMockStore { controller, _ in
      controller.enableError = TestError.simulatedFailure
    }

    let authResponse = AuthResponse(
      actorName: "Test User",
      accountSlug: "test-account",
      token: "token-123"
    )

    await #expect(throws: TestError.self) {
      try await fixture.store.signIn(authResponse: authResponse)
    }

    // enable was called but start was not (failed before start)
    #expect(fixture.controller.enableCallCount == 1)
    #expect(fixture.controller.startCallCount == 0)
  }

  @Test("Sign-in throws when start fails")
  @MainActor
  func signInThrowsWhenStartFails() async throws {
    let fixture = try await makeMockStore { controller, _ in
      controller.startError = TestError.simulatedFailure
    }

    let authResponse = AuthResponse(
      actorName: "Test User",
      accountSlug: "test-account",
      token: "token-123"
    )

    await #expect(throws: TestError.self) {
      try await fixture.store.signIn(authResponse: authResponse)
    }

    // both enable and start were called (failed during start)
    #expect(fixture.controller.enableCallCount == 1)
    #expect(fixture.controller.startCallCount == 1)
  }

  // MARK: - Sign-Out Tests

  @Test("Sign-out throws when tunnel controller fails")
  @MainActor
  func signOutThrowsOnFailure() async throws {
    let fixture = try await makeMockStore { controller, _ in
      controller.signOutError = TestError.simulatedFailure
    }

    // Error should propagate from tunnel controller
    await #expect(throws: TestError.self) {
      try await fixture.store.signOut()
    }
  }
}
