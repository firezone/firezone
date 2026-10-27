//
//  SignInChangeNoteTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Foundation
  import Testing

  @testable import FirezoneKit

  /// The note under the Settings tab's sign-in section, against the real `Store` and the
  /// mocked extension, each with a configuration of its own.
  @MainActor
  @Suite("Sign-in change note")
  struct SignInChangeNoteTests {
    private static let token = "stored-token"
    // What the mock scenarios seed.
    private static let accountSlug = "example-corp"

    @Test("is hidden while signed out")
    func hiddenWhileSignedOut() async throws {
      let store = try await startedStore()
      let viewModel = SettingsViewModel(store: store)

      viewModel.accountSlug = "other-corp"
      try await viewModel.save(.general)

      #expect(!viewModel.showsSignInChangeNote)
    }

    @Test("shows a drafted change before it is saved, and goes once it is reverted")
    func showsADraftedChange() async throws {
      let store = try await signedInStore()
      let viewModel = SettingsViewModel(store: store)

      #expect(!viewModel.showsSignInChangeNote)

      viewModel.accountSlug = "other-corp"
      #expect(viewModel.showsSignInChangeNote)

      viewModel.accountSlug = Self.accountSlug
      #expect(!viewModel.showsSignInChangeNote)
    }

    @Test("shows a saved change until it is saved back")
    func showsASavedChange() async throws {
      let store = try await signedInStore()
      let viewModel = SettingsViewModel(store: store)

      viewModel.accountSlug = "other-corp"
      try await viewModel.save(.general)

      #expect(viewModel.showsSignInChangeNote)
      #expect(SettingsViewModel(store: store).showsSignInChangeNote)

      viewModel.accountSlug = Self.accountSlug
      #expect(viewModel.showsSignInChangeNote)

      try await viewModel.save(.general)
      #expect(!viewModel.showsSignInChangeNote)
    }

    @Test("goes once a new sign-in uses the saved change")
    func goesAfterANewSignIn() async throws {
      let store = try await signedInStore()
      let viewModel = SettingsViewModel(store: store)

      viewModel.accountSlug = "other-corp"
      try await viewModel.save(.general)
      #expect(viewModel.showsSignInChangeNote)

      try await store.signOut()
      try await waitUntil { store.vpnStatus == .disconnected }
      #expect(store.configuration.signedInWith == nil)
      #expect(!viewModel.showsSignInChangeNote)

      try await store.signIn(token: Self.token)
      try await waitUntil { store.vpnStatus == .connected }
      #expect(store.configuration.signedInWith?.accountSlug == "other-corp")
      #expect(!viewModel.showsSignInChangeNote)
    }

    private func startedStore() async throws -> Store {
      let store = Store.mock(
        scenario: .named("welcome"),
        configuration: Configuration(userDefaults: UserDefaults.makeTestDefaults())
      )
      await store.start()

      return store
    }

    private func signedInStore() async throws -> Store {
      let store = try await startedStore()
      try await store.signIn(token: Self.token)
      try await waitUntil { store.vpnStatus == .connected }

      return store
    }
  }
#endif
