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
    let fixture = makeMockStore()

    // Subscribe to objectWillChange
    var changeCount = 0
    var cancellables = Set<AnyCancellable>()
    fixture.store.objectWillChange
      .sink { _ in changeCount += 1 }
      .store(in: &cancellables)

    // Trigger a change via sign-in
    let authResponse = AuthResponse(
      actorName: "Test User",
      accountSlug: "test-slug",
      token: "test-token"
    )
    try await fixture.store.signIn(authResponse: authResponse)

    // Store emits objectWillChange when state changes
    #expect(changeCount > 0, "Store should emit objectWillChange when signing in")
  }

  #if os(macOS)
    @Test("Store reflects system extension status from injected manager")
    @MainActor
    func storeReflectsSystemExtensionStatus() async throws {
      // Mock defaults to .installed
      let fixture = makeMockStore()

      // Wait for async initialization to complete
      try await Task.sleep(for: .milliseconds(100))

      // Verify Store's observable state reflects what the manager returned
      // If Store didn't use the injected mock, status would be nil
      #expect(
        fixture.store.systemExtensionStatus == .installed,
        "Store should expose system extension status for UI binding"
      )
    }
  #endif
}
