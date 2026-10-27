//
//  SettingsViewModel.swift
//  © 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation

@MainActor
class SettingsViewModel: ObservableObject {
  private let configuration: Configuration
  private let store: Store?
  private var cancellables: Set<AnyCancellable> = []
  private var logDirectorySizeTask: Task<Void, Never>?

  // Save and Reset act on one tab's settings only.
  @Published var selectedTab: SettingsView.Tab
  @Published private(set) var shouldDisableResetButton = false
  // Kept apart from the URLs so that picking Custom does not snap back to the portal they match.
  @Published private(set) var portal: Portal
  @Published var authURL: String
  @Published var apiURL: String
  @Published var logFilter: String
  /// Why the last save left a value out; nil when it was saved.
  @Published private(set) var authURLError: String?
  @Published private(set) var apiURLError: String?
  @Published private(set) var logFilterError: String?
  @Published var accountSlug: String
  @Published var connectOnStart: Bool
  @Published var startOnLogin: Bool

  /// Formatted size of the log directories; nil while a computation is running.
  @Published private(set) var logDirectorySizeText: String?
  @Published private(set) var isClearingLogs = false

  // Spans the whole export interaction, so the presentation flows (save panel,
  // share sheet) drive it from the view.
  @Published var isExportingLogs = false

  private static let logSizeFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .usePB]
    return formatter
  }()

  /// `store` powers the diagnostic logs actions; without one they report an
  /// unknown size and clear nothing.
  init(
    configuration: Configuration? = nil,
    store: Store? = nil,
    selectedTab: SettingsView.Tab = .general
  ) {
    self.configuration = configuration ?? store?.configuration ?? Configuration.shared
    self.store = store
    self.selectedTab = selectedTab

    authURL = self.configuration.authURL
    apiURL = self.configuration.apiURL
    portal = .custom
    logFilter = self.configuration.logFilter
    accountSlug = self.configuration.accountSlug
    connectOnStart = self.configuration.connectOnStart
    startOnLogin = self.configuration.startOnLogin
    portal = detectPortal()

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

    $selectedTab
      .receive(on: RunLoop.main)
      .sink(receiveValue: { [weak self] _ in
        self?.updateDerivedState()
      })
      .store(in: &cancellables)

    updateDerivedState()
  }

  func reset() {
    switch selectedTab {
    case .general:
      if !configuration.isAuthURLForced { authURL = ConfigurationDefaults.authURL }
      if !configuration.isApiURLForced { apiURL = ConfigurationDefaults.apiURL }
      if !configuration.isAccountSlugForced { accountSlug = ConfigurationDefaults.accountSlug }
      if !configuration.isConnectOnStartForced {
        connectOnStart = ConfigurationDefaults.connectOnStart
      }
      if !configuration.isStartOnLoginForced { startOnLogin = ConfigurationDefaults.startOnLogin }
      portal = detectPortal()
    case .logs:
      if !configuration.isLogFilterForced { logFilter = ConfigurationDefaults.logFilter }
    case .deviceTrust:
      break
    }

    updateDerivedState()
  }

  /// Saves the settings of `tab`, or of the selected tab, skipping any that are invalid.
  ///
  /// Returns whether the account slug or the portal changed, which only take effect on the next
  /// sign-in.
  @discardableResult
  func save(_ tab: SettingsView.Tab? = nil) async throws -> Bool {
    let savedSignInSettings = signInSettings

    switch tab ?? selectedTab {
    case .general:
      authURLError = isAuthURLValid() ? nil : "Enter a valid http:// or https:// URL"
      apiURLError = isApiURLValid() ? nil : "Enter a valid ws:// or wss:// URL"

      if areURLsValid() {
        if !configuration.isAuthURLForced { configuration.authURL = authURL }
        if !configuration.isApiURLForced { configuration.apiURL = apiURL }
        if portal == .custom, !isPortalForced {
          configuration.lastCustomURLs = (authURL, apiURL)
        }
      }
      if !configuration.isAccountSlugForced { configuration.accountSlug = accountSlug }
      if !configuration.isConnectOnStartForced { configuration.connectOnStart = connectOnStart }
      if !configuration.isStartOnLoginForced { configuration.startOnLogin = startOnLogin }
    case .logs:
      logFilterError = logFilterProblem()

      if !configuration.isLogFilterForced, isLogFilterValid() {
        configuration.logFilter = logFilter
      }
    case .deviceTrust:
      break
    }

    updateDerivedState()

    return signInSettings != savedSignInSettings
  }

  /// Picks `portal` on the user's behalf: Firezone Cloud brings its own URLs, and Custom brings
  /// back the last ones saved with it, if any.
  func selectPortal(_ portal: Portal) {
    guard portal != self.portal, !isPortalForced else { return }

    self.portal = portal

    guard let urls = portal.urls ?? configuration.lastCustomURLs else { return }

    authURL = urls.authURL
    apiURL = urls.apiURL
  }

  func refreshLogDirectorySize() {
    logDirectorySizeTask?.cancel()
    logDirectorySizeText = nil

    logDirectorySizeTask = Task {
      let size = await store?.logDirectorySize()

      guard !Task.isCancelled else { return }

      logDirectorySizeText =
        size.map { Self.logSizeFormatter.string(fromByteCount: Int64(clamping: $0)) } ?? "Unknown"
    }
  }

  func cancelLogDirectorySizeRefresh() {
    logDirectorySizeTask?.cancel()
  }

  func clearLogs() {
    guard !isClearingLogs else { return }

    isClearingLogs = true
    logDirectorySizeTask?.cancel()

    Task {
      do {
        try await store?.clearLogs()
      } catch {
        Log.error(error)
      }

      isClearingLogs = false
      refreshLogDirectorySize()
    }
  }

  func logArchiveFileName() -> String {
    "firezone_logs_\(LogExporter.now()).zip"
  }

  /// Puts invalid values back to the saved ones, so that the settings reopen showing what is in
  /// effect.
  func discardInvalidDrafts() {
    if !areURLsValid() {
      authURL = configuration.authURL
      apiURL = configuration.apiURL
      portal = detectPortal()
    }
    if !isLogFilterValid() { logFilter = configuration.logFilter }

    authURLError = nil
    apiURLError = nil
    logFilterError = nil
    updateDerivedState()
  }

  func areURLsValid() -> Bool {
    isAuthURLValid() && isApiURLValid()
  }

  private func isAuthURLValid() -> Bool {
    guard let authURL = URL(string: authURL),
      authURL.host != nil,
      ["http", "https"].contains(authURL.scheme),
      authURL.pathComponents.isEmpty
    else {
      return false
    }

    return true
  }

  private func isApiURLValid() -> Bool {
    guard let apiURL = URL(string: apiURL),
      apiURL.host != nil,
      ["wss", "ws"].contains(apiURL.scheme),
      apiURL.pathComponents.isEmpty
    else {
      return false
    }

    return true
  }

  func isLogFilterValid() -> Bool {
    logFilterProblem() == nil
  }

  private func logFilterProblem() -> String? {
    if logFilter.isEmpty { return "Enter a log filter" }

    if !LogFilter.isValid(logFilter) {
      return "Use a level such as info, or target=level pairs separated by commas"
    }

    return nil
  }

  private var signInSettings: [String] {
    [configuration.accountSlug, configuration.authURL, configuration.apiURL]
  }

  var isPortalForced: Bool {
    configuration.isAuthURLForced || configuration.isApiURLForced
  }

  // With only one of the URLs forced, `custom` keeps the other one editable.
  private func detectPortal() -> Portal {
    guard configuration.isAuthURLForced == configuration.isApiURLForced else { return .custom }

    return Portal.of(authURL: authURL, apiURL: apiURL)
  }

  private func updateDerivedState() {
    switch selectedTab {
    case .general:
      let isAllForced =
        configuration.isAuthURLForced && configuration.isApiURLForced
        && configuration.isAccountSlugForced && configuration.isConnectOnStartForced
        && configuration.isStartOnLoginForced
      let isDefault =
        (configuration.isAuthURLForced || authURL == ConfigurationDefaults.authURL)
        && (configuration.isApiURLForced || apiURL == ConfigurationDefaults.apiURL)
        && (configuration.isAccountSlugForced || accountSlug == ConfigurationDefaults.accountSlug)
        && (configuration.isConnectOnStartForced
          || connectOnStart == ConfigurationDefaults.connectOnStart)
        && (configuration.isStartOnLoginForced
          || startOnLogin == ConfigurationDefaults.startOnLogin)

      shouldDisableResetButton = isAllForced || isDefault
    case .logs:
      shouldDisableResetButton =
        configuration.isLogFilterForced || logFilter == ConfigurationDefaults.logFilter
    case .deviceTrust:
      shouldDisableResetButton = true
    }
  }

  private func syncForcedValuesFromConfiguration() {
    if configuration.isAuthURLForced { authURL = configuration.authURL }
    if configuration.isApiURLForced { apiURL = configuration.apiURL }
    if configuration.isLogFilterForced { logFilter = configuration.logFilter }
    if configuration.isAccountSlugForced { accountSlug = configuration.accountSlug }
    if configuration.isConnectOnStartForced { connectOnStart = configuration.connectOnStart }
    if configuration.isStartOnLoginForced { startOnLogin = configuration.startOnLogin }
    if isPortalForced { portal = detectPortal() }
  }
}
