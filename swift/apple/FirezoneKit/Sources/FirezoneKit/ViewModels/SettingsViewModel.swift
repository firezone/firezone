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

enum SettingsToggle {
  case connectOnStart
  case startOnLogin
}

@MainActor
class SettingsViewModel: ObservableObject {
  private let configuration: Configuration
  private let store: Store?
  private var cancellables: Set<AnyCancellable> = []

  @Published private(set) var shouldDisableResetButton = false
  @Published var authURL: String
  @Published var apiURL: String
  @Published var logFilter: String
  @Published var accountSlug: String
  @Published var connectOnStart: Bool
  @Published var startOnLogin: Bool

  // Sign-out confirmation for identity-related field changes
  @Published var showSignOutConfirmation: Bool = false
  private var savedAuthURL: String
  private var savedApiURL: String
  private var savedAccountSlug: String
  var pendingFieldChange: (field: SettingsField, value: String)?

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
    if !configuration.isAuthURLForced {
      authURL = Configuration.defaultAuthURL
      configuration.authURL = authURL
      savedAuthURL = authURL
    }
    if !configuration.isApiURLForced {
      apiURL = Configuration.defaultApiURL
      configuration.apiURL = apiURL
      savedApiURL = apiURL
    }
    if !configuration.isLogFilterForced {
      logFilter = Configuration.defaultLogFilter
      configuration.logFilter = logFilter
    }
    if !configuration.isAccountSlugForced {
      accountSlug = Configuration.defaultAccountSlug
      configuration.accountSlug = accountSlug
      savedAccountSlug = accountSlug
    }
    if !configuration.isConnectOnStartForced {
      connectOnStart = Configuration.defaultConnectOnStart
      configuration.connectOnStart = connectOnStart
    }
    if !configuration.isStartOnLoginForced {
      startOnLogin = Configuration.defaultStartOnLogin
      configuration.startOnLogin = startOnLogin
    }

    updateDerivedState()
  }

  func saveField(_ field: SettingsField) async throws {
    switch field {
    case .authURL:
      guard isAuthURLValid else { return }
      if authURL != savedAuthURL, requiresSignOut {
        pendingFieldChange = (field: .authURL, value: authURL)
        showSignOutConfirmation = true
        return
      }
      configuration.authURL = authURL
      savedAuthURL = authURL

    case .apiURL:
      guard isApiURLValid else { return }
      if apiURL != savedApiURL, requiresSignOut {
        pendingFieldChange = (field: .apiURL, value: apiURL)
        showSignOutConfirmation = true
        return
      }
      configuration.apiURL = apiURL
      savedApiURL = apiURL

    case .logFilter:
      guard isLogFilterValid else { return }
      configuration.logFilter = logFilter

    case .accountSlug:
      if accountSlug != savedAccountSlug, requiresSignOut {
        pendingFieldChange = (field: .accountSlug, value: accountSlug)
        showSignOutConfirmation = true
        return
      }
      configuration.accountSlug = accountSlug
      savedAccountSlug = accountSlug
    }
  }

  private var requiresSignOut: Bool {
    guard let store = store else { return false }
    return [.connected, .connecting, .reasserting].contains(store.vpnStatus)
  }

  func saveToggle(_ field: SettingsToggle) async throws {
    switch field {
    case .connectOnStart:
      configuration.connectOnStart = connectOnStart
    case .startOnLogin:
      configuration.startOnLogin = startOnLogin
      #if os(macOS)
        try await configuration.updateAppService()
      #endif
    }
  }

  func confirmSignOutChange() async throws {
    guard let pending = pendingFieldChange else { return }

    switch pending.field {
    case .authURL:
      authURL = pending.value
      configuration.authURL = authURL
      savedAuthURL = authURL
    case .apiURL:
      apiURL = pending.value
      configuration.apiURL = apiURL
      savedApiURL = apiURL
    case .accountSlug:
      accountSlug = pending.value
      configuration.accountSlug = accountSlug
      savedAccountSlug = accountSlug
    case .logFilter:
      break
    }

    if let store = store {
      try await store.signOut()
    }

    pendingFieldChange = nil
    showSignOutConfirmation = false
  }

  func cancelSignOutChange() {
    guard let pending = pendingFieldChange else { return }

    switch pending.field {
    case .authURL: authURL = savedAuthURL
    case .apiURL: apiURL = savedApiURL
    case .accountSlug: accountSlug = savedAccountSlug
    case .logFilter: break
    }

    pendingFieldChange = nil
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
    (configuration.isAuthURLForced || authURL == Configuration.defaultAuthURL)
      && (configuration.isApiURLForced || apiURL == Configuration.defaultApiURL)
      && (configuration.isLogFilterForced || logFilter == Configuration.defaultLogFilter)
      && (configuration.isAccountSlugForced || accountSlug == Configuration.defaultAccountSlug)
      && (configuration.isConnectOnStartForced
        || connectOnStart == Configuration.defaultConnectOnStart)
      && (configuration.isStartOnLoginForced || startOnLogin == Configuration.defaultStartOnLogin)
  }

  private func updateDerivedState() {
    shouldDisableResetButton = (isAllForced || isDefault)
  }
}
