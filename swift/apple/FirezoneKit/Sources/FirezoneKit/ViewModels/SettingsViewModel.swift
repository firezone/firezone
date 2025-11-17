//
//  SettingsViewModel.swift
//  © 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
  case general = "General"
  case advanced = "Advanced"
  case logs = "Diagnostic Logs"
  case about = "About"

  public var id: String { rawValue }

  public var icon: String {
    switch self {
    case .general: return "slider.horizontal.3"
    case .advanced: return "gearshape.2"
    case .logs: return "doc.text.magnifyingglass"
    case .about: return "info.circle"
    }
  }
}

@MainActor
class SettingsViewModel: ObservableObject {
  private let configuration: Configuration
  private let store: Store?
  private var cancellables: Set<AnyCancellable> = []

  @Published private(set) var shouldDisableApplyButton = false
  @Published private(set) var shouldDisableResetButton = false
  @Published var selectedSection: SettingsSection = .general
  @Published var authURL: String
  @Published var apiURL: String
  @Published var logFilter: String
  @Published var accountSlug: String
  @Published var connectOnStart: Bool
  @Published var startOnLogin: Bool

  // API URL change confirmation
  @Published var showApiURLChangeConfirmation: Bool = false
  private var savedApiURL: String
  var pendingApiURLChange: String?

  init(configuration: Configuration? = nil, store: Store? = nil) {
    self.configuration = configuration ?? Configuration.shared
    self.store = store

    authURL = self.configuration.authURL
    apiURL = self.configuration.apiURL
    logFilter = self.configuration.logFilter
    accountSlug = self.configuration.accountSlug
    connectOnStart = self.configuration.connectOnStart
    startOnLogin = self.configuration.startOnLogin

    savedApiURL = self.configuration.apiURL

    Publishers.MergeMany(
      $authURL,
      $apiURL,
      $logFilter,
      $accountSlug
    )
    .receive(on: RunLoop.main)
    .sink(receiveValue: { [weak self] _ in
      self?.updateDerivedState()
    })
    .store(in: &cancellables)

    self.configuration.objectWillChange
      .receive(on: RunLoop.main)
      .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
      .sink(receiveValue: { [weak self] _ in
        self?.updateDerivedState()
      })
      .store(in: &cancellables)

    Publishers.MergeMany(
      $connectOnStart,
      $startOnLogin
    )
    .receive(on: RunLoop.main)
    .sink(receiveValue: { [weak self] _ in
      self?.updateDerivedState()
    })
    .store(in: &cancellables)

    updateDerivedState()
  }

  func reset() {
    if !configuration.isAuthURLForced { authURL = Configuration.defaultAuthURL }
    if !configuration.isApiURLForced { apiURL = Configuration.defaultApiURL }
    if !configuration.isLogFilterForced { logFilter = Configuration.defaultLogFilter }
    if !configuration.isAccountSlugForced { accountSlug = Configuration.defaultAccountSlug }
    if !configuration.isConnectOnStartForced {
      connectOnStart = Configuration.defaultConnectOnStart
    }
    if !configuration.isStartOnLoginForced { startOnLogin = Configuration.defaultStartOnLogin }

    updateDerivedState()
  }

  func save() async throws {
    Log.log("SettingsViewModel.save() called")
    Log.log("API URL changed: \(apiURL) != \(savedApiURL) = \(apiURL != savedApiURL)")
    Log.log("Store exists: \(store != nil)")
    Log.log("VPN status: \(String(describing: store?.vpnStatus))")

    // Check if API URL changed and user is signed in
    if apiURL != savedApiURL,
      let store = store,
      store.vpnStatus == .connected
    {
      Log.log("Showing API URL change confirmation dialog")
      // Show confirmation dialog instead of saving immediately
      pendingApiURLChange = apiURL
      showApiURLChangeConfirmation = true
      return
    }

    Log.log("Proceeding with save (no confirmation needed)")
    // Proceed with save
    configuration.authURL = authURL
    configuration.apiURL = apiURL
    configuration.logFilter = logFilter
    configuration.accountSlug = accountSlug
    configuration.connectOnStart = connectOnStart
    configuration.startOnLogin = startOnLogin

    #if os(macOS)
      try await configuration.updateAppService()
    #endif

    // Update saved API URL after successful save
    savedApiURL = apiURL

    updateDerivedState()
  }

  func confirmApiURLChange() async throws {
    guard let newApiURL = pendingApiURLChange else {
      return
    }

    // Save the new API URL
    apiURL = newApiURL
    configuration.authURL = authURL
    configuration.apiURL = apiURL
    configuration.logFilter = logFilter
    configuration.accountSlug = accountSlug
    configuration.connectOnStart = connectOnStart
    configuration.startOnLogin = startOnLogin

    #if os(macOS)
      try await configuration.updateAppService()
    #endif

    // Update saved API URL
    savedApiURL = apiURL

    // Sign out the user
    if let store = store {
      try await store.signOut()
    }

    // Clean up
    pendingApiURLChange = nil
    showApiURLChangeConfirmation = false

    updateDerivedState()
  }

  func cancelApiURLChange() {
    // Revert to saved API URL
    apiURL = savedApiURL
    pendingApiURLChange = nil
    showApiURLChangeConfirmation = false
  }

  func isAllForced() -> Bool {
    return
      (configuration.isAuthURLForced && configuration.isApiURLForced
      && configuration.isLogFilterForced && configuration.isAccountSlugForced
      && configuration.isConnectOnStartForced && configuration.isStartOnLoginForced)
  }

  func isValid() -> Bool {
    guard let apiURL = URL(string: apiURL),
      apiURL.host != nil,
      ["wss", "ws"].contains(apiURL.scheme),
      apiURL.pathComponents.isEmpty
    else {
      return false
    }

    guard let authURL = URL(string: authURL),
      authURL.host != nil,
      ["http", "https"].contains(authURL.scheme),
      authURL.pathComponents.isEmpty
    else {
      return false
    }

    guard !logFilter.isEmpty
    else {
      return false
    }

    return true
  }

  func isDefault() -> Bool {
    return
      ((configuration.isAuthURLForced || authURL == Configuration.defaultAuthURL)
      && (configuration.isApiURLForced || apiURL == Configuration.defaultApiURL)
      && (configuration.isLogFilterForced || logFilter == Configuration.defaultLogFilter)
      && (configuration.isAccountSlugForced || accountSlug == Configuration.defaultAccountSlug)
      && (configuration.isConnectOnStartForced
        || connectOnStart == Configuration.defaultConnectOnStart)
      && (configuration.isStartOnLoginForced || startOnLogin == Configuration.defaultStartOnLogin))
  }

  func isSaved() -> Bool {
    return
      (authURL == configuration.authURL && apiURL == configuration.apiURL
      && logFilter == configuration.logFilter && accountSlug == configuration.accountSlug
      && connectOnStart == configuration.connectOnStart
      && startOnLogin == configuration.startOnLogin)
  }

  private func updateDerivedState() {
    shouldDisableApplyButton = (isAllForced() || isSaved() || !isValid())

    shouldDisableResetButton = (isAllForced() || isDefault())
  }
}
