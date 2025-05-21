//
//  SettingsViewModel.swift
//  © 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import SwiftUI

@MainActor
class SettingsViewModel: ObservableObject {
  private let configuration: Configuration
  private var cancellables: Set<AnyCancellable> = []

  @Published private(set) var shouldDisableApplyButton = false
  @Published private(set) var shouldDisableResetButton = false
  @Published var authURL: String
  @Published var apiURL: String
  @Published var logFilter: String
  @Published var accountSlug: String
  @Published var connectOnStart: Bool
  @Published var startOnLogin: Bool

  init(configuration: Configuration? = nil) {
    self.configuration = configuration ?? Configuration.shared

    authURL = self.configuration.authURL
    apiURL = self.configuration.apiURL
    logFilter = self.configuration.logFilter
    accountSlug = self.configuration.accountSlug
    connectOnStart = self.configuration.connectOnStart
    startOnLogin = self.configuration.startOnLogin

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
    authURL = Configuration.defaultAuthURL
    apiURL = Configuration.defaultApiURL
    logFilter = Configuration.defaultLogFilter
    accountSlug = Configuration.defaultAccountSlug
    connectOnStart = Configuration.defaultConnectOnStart
    startOnLogin = Configuration.defaultStartOnLogin

    updateDerivedState()
  }

  func save() async throws {
    configuration.authURL = authURL
    configuration.apiURL = apiURL
    configuration.logFilter = logFilter
    configuration.accountSlug = accountSlug
    configuration.connectOnStart = connectOnStart
    configuration.startOnLogin = startOnLogin

#if os(macOS)
    try await configuration.updateAppService()
#endif

    updateDerivedState()
  }

  func isAllForced() -> Bool {
    return (
      configuration.isAuthURLForced &&
      configuration.isApiURLForced &&
      configuration.isLogFilterForced &&
      configuration.isAccountSlugForced &&
      configuration.isConnectOnStartForced &&
      configuration.isStartOnLoginForced
    )
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
    return (
      authURL == Configuration.defaultAuthURL &&
      apiURL == Configuration.defaultApiURL &&
      logFilter == Configuration.defaultLogFilter &&
      accountSlug == Configuration.defaultAccountSlug &&
      connectOnStart == Configuration.defaultConnectOnStart &&
      startOnLogin == Configuration.defaultStartOnLogin
    )
  }

  func isSaved() -> Bool {
    return (
      authURL == configuration.authURL &&
      apiURL == configuration.apiURL &&
      logFilter == configuration.logFilter &&
      accountSlug == configuration.accountSlug &&
      connectOnStart == configuration.connectOnStart &&
      startOnLogin == configuration.startOnLogin
    )
  }

  private func updateDerivedState() {
    shouldDisableApplyButton = (
      isAllForced() ||
      isSaved() ||
      !isValid()
    )

    shouldDisableResetButton = (
      isAllForced() ||
      isDefault()
    )
  }
}
