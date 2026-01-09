//
//  Configuration.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  A thin wrapper around UserDefaults for user and admin managed app configuration.

import Combine
import Foundation
import Sentry

#if os(macOS)
  import ServiceManagement
#endif

@MainActor
public class Configuration: ObservableObject {
  static let shared = Configuration()
  private var cancellables = Set<AnyCancellable>()

  @Published private(set) var publishedInternetResourceEnabled = false
  @Published private(set) var publishedHideAdminPortalMenuItem = false
  @Published private(set) var publishedHideResourceList = false

  var isAuthURLForced: Bool { defaults.objectIsForced(forKey: Keys.authURL) }
  var isApiURLForced: Bool { defaults.objectIsForced(forKey: Keys.apiURL) }
  var isLogFilterForced: Bool { defaults.objectIsForced(forKey: Keys.logFilter) }
  var isAccountSlugForced: Bool { defaults.objectIsForced(forKey: Keys.accountSlug) }
  var isConnectOnStartForced: Bool { defaults.objectIsForced(forKey: Keys.connectOnStart) }
  var isStartOnLoginForced: Bool { defaults.objectIsForced(forKey: Keys.startOnLogin) }

  var authURL: String {
    get { defaults.string(forKey: Keys.authURL) ?? Self.defaultAuthURL }
    set { defaults.set(newValue, forKey: Keys.authURL) }
  }

  var apiURL: String {
    get { defaults.string(forKey: Keys.apiURL) ?? Self.defaultApiURL }
    set { defaults.set(newValue, forKey: Keys.apiURL) }
  }

  var logFilter: String {
    get { defaults.string(forKey: Keys.logFilter) ?? Self.defaultLogFilter }
    set { defaults.set(newValue, forKey: Keys.logFilter) }
  }

  var accountSlug: String {
    get { defaults.string(forKey: Keys.accountSlug) ?? Self.defaultAccountSlug }
    set { defaults.set(newValue, forKey: Keys.accountSlug) }
  }

  var hideAdminPortalMenuItem: Bool {
    get { defaults.bool(forKey: Keys.hideAdminPortalMenuItem) }
    set { defaults.set(newValue, forKey: Keys.hideAdminPortalMenuItem) }
  }

  var hideResourceList: Bool {
    get { defaults.bool(forKey: Keys.hideResourceList) }
    set { defaults.set(newValue, forKey: Keys.hideResourceList) }
  }

  var connectOnStart: Bool {
    get { defaults.bool(forKey: Keys.connectOnStart) }
    set { defaults.set(newValue, forKey: Keys.connectOnStart) }
  }

  var startOnLogin: Bool {
    get { defaults.bool(forKey: Keys.startOnLogin) }
    set { defaults.set(newValue, forKey: Keys.startOnLogin) }
  }

  var disableUpdateCheck: Bool {
    get { defaults.bool(forKey: Keys.disableUpdateCheck) }
    set { defaults.set(newValue, forKey: Keys.disableUpdateCheck) }
  }

  var supportURL: String {
    get { defaults.string(forKey: Keys.supportURL) ?? Self.defaultSupportURL }
    set { defaults.set(newValue, forKey: Keys.supportURL) }
  }

  // User-configurable only
  var internetResourceEnabled: Bool {
    get { defaults.bool(forKey: Keys.internetResourceEnabled) }
    set { defaults.set(newValue, forKey: Keys.internetResourceEnabled) }
  }

  #if DEBUG
    static let defaultAuthURL = "https://app.firez.one"
    static let defaultApiURL = "wss://api.firez.one"
    static let defaultLogFilter = "debug"
  #else
    static let defaultAuthURL = "https://app.firezone.dev"
    static let defaultApiURL = "wss://api.firezone.dev"
    static let defaultLogFilter = "info"
  #endif

  static let defaultAccountSlug = ""
  static let defaultSupportURL = "https://firezone.dev/support"

  // Bools are always default false
  static let defaultConnectOnStart = false
  static let defaultStartOnLogin = false
  static let defaultDisableUpdateCheck = false

  private struct Keys {
    static let authURL = "authURL"
    static let apiURL = "apiURL"
    static let logFilter = "logFilter"
    static let accountSlug = "accountSlug"
    static let internetResourceEnabled = "internetResourceEnabled"
    static let hideAdminPortalMenuItem = "hideAdminPortalMenuItem"
    static let hideResourceList = "hideResourceList"
    static let connectOnStart = "connectOnStart"
    static let startOnLogin = "startOnLogin"
    static let disableUpdateCheck = "disableUpdateCheck"
    static let supportURL = "supportURL"
  }

  private var defaults: UserDefaults

  init(userDefaults: UserDefaults = UserDefaults.standard) {
    defaults = userDefaults

    self.publishedInternetResourceEnabled = internetResourceEnabled
    self.publishedHideAdminPortalMenuItem = hideAdminPortalMenuItem
    self.publishedHideResourceList = hideResourceList

    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.handleUserDefaultsChanged()
      }
      .store(in: &cancellables)
  }

  func toTunnelConfiguration() -> TunnelConfiguration {
    return TunnelConfiguration(
      apiURL: apiURL,
      accountSlug: accountSlug,
      logFilter: logFilter,
      internetResourceEnabled: internetResourceEnabled
    )
  }

  #if os(macOS)
    // Register / unregister our launch service based on configuration.
    func updateAppService() async throws {
      // Getting the status initially appears to be blocking sometimes
      SentrySDK.pauseAppHangTracking()
      defer { SentrySDK.resumeAppHangTracking() }
      let status = SMAppService.mainApp.status

      if !startOnLogin, status == .enabled {
        try await SMAppService.mainApp.unregister()
        return
      }

      if startOnLogin, status != .enabled {
        try SMAppService.mainApp.register()
      }
    }
  #endif

  private func handleUserDefaultsChanged() {
    #if os(macOS)
      // This is idempotent
      Task { do { try await updateAppService() } }
    #endif

    // Update published properties
    self.publishedInternetResourceEnabled = internetResourceEnabled
    self.publishedHideAdminPortalMenuItem = hideAdminPortalMenuItem
    self.publishedHideResourceList = hideResourceList

    // Announce we changed
    objectWillChange.send()
  }
}

// Configuration does not conform to Decodable, so introduce a simpler type here to encode for IPC
public struct TunnelConfiguration: Codable, Sendable {
  public let apiURL: String
  public let accountSlug: String
  public let logFilter: String
  public let internetResourceEnabled: Bool

  public init(apiURL: String, accountSlug: String, logFilter: String, internetResourceEnabled: Bool)
  {
    self.apiURL = apiURL
    self.accountSlug = accountSlug
    self.logFilter = logFilter
    self.internetResourceEnabled = internetResourceEnabled
  }
}

extension TunnelConfiguration: Equatable {
  public static func == (lhs: TunnelConfiguration, rhs: TunnelConfiguration) -> Bool {
    return lhs.apiURL == rhs.apiURL && lhs.accountSlug == rhs.accountSlug
      && lhs.logFilter == rhs.logFilter
      && lhs.internetResourceEnabled == rhs.internetResourceEnabled
  }
}
