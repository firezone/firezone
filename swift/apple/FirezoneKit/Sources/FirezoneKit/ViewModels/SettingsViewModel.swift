//
//  SettingsViewModel.swift
//  © 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
  case general = "General"
  case advanced = "Advanced"
  case logs = "Diagnostic Logs"
  case about = "About"

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .general: return "slider.horizontal.3"
    case .advanced: return "gearshape.2"
    case .logs: return "doc.text.magnifyingglass"
    case .about: return "info.circle"
    }
  }
}

enum SettingsField: Hashable {
  case authURL
  case apiURL
  case logFilter
  case accountSlug
}

enum SettingsToggle: Hashable {
  case connectOnStart
  case startOnLogin
}

@MainActor
class SettingsViewModel: ObservableObject {
  private let configuration: Configuration
  private let store: Store?
  private var cancellables: Set<AnyCancellable> = []

  private(set) var isResetting = false
  @Published private(set) var shouldDisableResetButton = false
  @Published var authURL: String
  @Published var apiURL: String
  @Published var logFilter: String
  @Published var accountSlug: String
  @Published var connectOnStart: Bool
  @Published var startOnLogin: Bool

  // Sign-out confirmation for identity-related changes (field edits or reset)
  @Published var showSignOutConfirmation: Bool = false
  private var savedAuthURL: String
  private var savedApiURL: String
  private var savedAccountSlug: String

  private enum PendingChange {
    case field(SettingsField, String)
    case reset
  }

  private var pendingChange: PendingChange?

  init(configuration: Configuration? = nil, store: Store? = nil) {
    self.configuration = configuration ?? Configuration.shared
    self.store = store

    authURL = self.configuration.authURL
    apiURL = self.configuration.apiURL
    logFilter = self.configuration.logFilter
    accountSlug = self.configuration.accountSlug
    connectOnStart = self.configuration.connectOnStart
    startOnLogin = self.configuration.startOnLogin

    savedAuthURL = self.configuration.authURL
    savedApiURL = self.configuration.apiURL
    savedAccountSlug = self.configuration.accountSlug

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
        self?.syncForcedValuesFromConfiguration()
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
    if requiresSignOut {
      pendingChange = .reset
      showSignOutConfirmation = true
      return
    }
    performReset()
  }

  private func performReset() {
    isResetting = true
    defer { isResetting = false }

    if !configuration.isAuthURLForced {
      authURL = ConfigurationDefaults.authURL
      configuration.authURL = authURL
      savedAuthURL = authURL
    }
    if !configuration.isApiURLForced {
      apiURL = ConfigurationDefaults.apiURL
      configuration.apiURL = apiURL
      savedApiURL = apiURL
    }
    if !configuration.isLogFilterForced {
      logFilter = ConfigurationDefaults.logFilter
      configuration.logFilter = logFilter
    }
    if !configuration.isAccountSlugForced {
      accountSlug = ConfigurationDefaults.accountSlug
      configuration.accountSlug = accountSlug
      savedAccountSlug = accountSlug
    }
    if !configuration.isConnectOnStartForced {
      connectOnStart = ConfigurationDefaults.connectOnStart
      configuration.connectOnStart = connectOnStart
    }
    if !configuration.isStartOnLoginForced {
      startOnLogin = ConfigurationDefaults.startOnLogin
      configuration.startOnLogin = startOnLogin
    }

    updateDerivedState()
  }

  func saveField(_ field: SettingsField) async throws {
    guard !isResetting else { return }

    switch field {
    case .authURL:
      guard !configuration.isAuthURLForced, isAuthURLValid else { return }
      if authURL != savedAuthURL, requiresSignOut {
        pendingChange = .field(.authURL, authURL)
        showSignOutConfirmation = true
        return
      }
      configuration.authURL = authURL
      savedAuthURL = authURL

    case .apiURL:
      guard !configuration.isApiURLForced, isApiURLValid else { return }
      if apiURL != savedApiURL, requiresSignOut {
        pendingChange = .field(.apiURL, apiURL)
        showSignOutConfirmation = true
        return
      }
      configuration.apiURL = apiURL
      savedApiURL = apiURL

    case .logFilter:
      guard !configuration.isLogFilterForced, isLogFilterValid else { return }
      configuration.logFilter = logFilter

    case .accountSlug:
      guard !configuration.isAccountSlugForced else { return }
      if accountSlug != savedAccountSlug, requiresSignOut {
        pendingChange = .field(.accountSlug, accountSlug)
        showSignOutConfirmation = true
        return
      }
      configuration.accountSlug = accountSlug
      savedAccountSlug = accountSlug
    }
  }

  func save() async throws {
    try await saveField(.authURL)
    try await saveField(.apiURL)
    try await saveField(.logFilter)
    try await saveField(.accountSlug)
    try await saveToggle(.connectOnStart)
    try await saveToggle(.startOnLogin)
  }

  private var requiresSignOut: Bool {
    guard let store = store else { return false }
    return [.connected, .connecting, .reasserting].contains(store.vpnStatus)
  }

  func saveToggle(_ field: SettingsToggle) async throws {
    switch field {
    case .connectOnStart:
      guard !configuration.isConnectOnStartForced,
        connectOnStart != configuration.connectOnStart
      else { return }
      configuration.connectOnStart = connectOnStart
    case .startOnLogin:
      guard !configuration.isStartOnLoginForced,
        startOnLogin != configuration.startOnLogin
      else { return }
      configuration.startOnLogin = startOnLogin
    }
  }

  /// Applies the pending change (field edit or reset) and signs out.
  ///
  /// Safe to read `pendingChange` directly because the sign-out
  /// confirmation alert is modal — the user cannot edit fields while it is presented.
  func confirmSignOutChange() async throws {
    guard let pending = pendingChange else { return }

    switch pending {
    case .field(let field, let value):
      switch field {
      case .authURL:
        authURL = value
        configuration.authURL = authURL
        savedAuthURL = authURL
      case .apiURL:
        apiURL = value
        configuration.apiURL = apiURL
        savedApiURL = apiURL
      case .accountSlug:
        accountSlug = value
        configuration.accountSlug = accountSlug
        savedAccountSlug = accountSlug
      case .logFilter:
        break
      }
    case .reset:
      performReset()
    }

    if let store = store {
      try await store.signOut()
    }

    pendingChange = nil
    showSignOutConfirmation = false
  }

  func cancelSignOutChange() {
    guard let pending = pendingChange else { return }

    // Revert UI fields to their last-saved values for field edits.
    // Reset needs no revert — the UI fields haven't been changed yet.
    if case .field(let field, _) = pending {
      switch field {
      case .authURL: authURL = savedAuthURL
      case .apiURL: apiURL = savedApiURL
      case .accountSlug: accountSlug = savedAccountSlug
      case .logFilter: break
      }
    }

    pendingChange = nil
    showSignOutConfirmation = false
  }

  var isAllForced: Bool {
    configuration.isAuthURLForced && configuration.isApiURLForced
      && configuration.isLogFilterForced && configuration.isAccountSlugForced
      && configuration.isConnectOnStartForced && configuration.isStartOnLoginForced
  }

  var isAuthURLValid: Bool {
    guard let url = URL(string: authURL),
      url.host != nil,
      ["http", "https"].contains(url.scheme),
      url.pathComponents.isEmpty
    else { return false }
    return true
  }

  var isApiURLValid: Bool {
    guard let url = URL(string: apiURL),
      url.host != nil,
      ["wss", "ws"].contains(url.scheme),
      url.pathComponents.isEmpty
    else { return false }
    return true
  }

  var isLogFilterValid: Bool {
    !logFilter.isEmpty
  }

  var isValid: Bool {
    isAuthURLValid && isApiURLValid && isLogFilterValid
  }

  var isDefault: Bool {
    (configuration.isAuthURLForced || authURL == ConfigurationDefaults.authURL)
      && (configuration.isApiURLForced || apiURL == ConfigurationDefaults.apiURL)
      && (configuration.isLogFilterForced || logFilter == ConfigurationDefaults.logFilter)
      && (configuration.isAccountSlugForced || accountSlug == ConfigurationDefaults.accountSlug)
      && (configuration.isConnectOnStartForced
        || connectOnStart == ConfigurationDefaults.connectOnStart)
      && (configuration.isStartOnLoginForced || startOnLogin == ConfigurationDefaults.startOnLogin)
  }

  private func updateDerivedState() {
    shouldDisableResetButton = (isAllForced || isDefault)
  }

  private func syncForcedValuesFromConfiguration() {
    if configuration.isAuthURLForced {
      authURL = configuration.authURL
      savedAuthURL = configuration.authURL
    }
    if configuration.isApiURLForced {
      apiURL = configuration.apiURL
      savedApiURL = configuration.apiURL
    }
    if configuration.isLogFilterForced { logFilter = configuration.logFilter }
    if configuration.isAccountSlugForced {
      accountSlug = configuration.accountSlug
      savedAccountSlug = configuration.accountSlug
    }
    if configuration.isConnectOnStartForced { connectOnStart = configuration.connectOnStart }
    if configuration.isStartOnLoginForced { startOnLogin = configuration.startOnLogin }
  }
}
