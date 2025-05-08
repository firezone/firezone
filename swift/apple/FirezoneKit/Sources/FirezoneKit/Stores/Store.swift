//
//  Store.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import NetworkExtension
import UserNotifications
import OSLog

#if os(macOS)
import AppKit
#endif

@MainActor
public final class Store: ObservableObject {
  public enum Keys {
    static let favoriteResourceIDs = "dev.firezone.config.favoriteResourceIDs"
    static let actorName = "dev.firezone.config.actorName"
    static let accountSlug = "dev.firezone.config.accountSlug"
    static let authURL = "dev.firezone.config.authURL"
    static let apiURL = "dev.firezone.config.apiURL"
    static let logFilter = "dev.firezone.config.logFilter"
    static let internetResourceEnabled = "dev.firezone.config.internetResourceEnabled"
  }

#if DEBUG
  public static let defaultAuthURL = URL(string: "https://app.firez.one")!
  public static let defaultApiURL = URL(string: "wss://api.firez.one")!
  public static let defaultLogFilter = "debug"
#else
  public static let defaultAuthURL = URL(string: "https://app.firezone.dev")!
  public static let defaultApiURL = URL(string: "wss://api.firezone.dev")!
  public static let defaultLogFilter = "info"
#endif

  @Published private(set) var resourceList: ResourceList = .loading

  // UserDefaults-backed app configuration that will publish updates to SwiftUI components
  @Published private(set) var actorName: String?
  @Published private(set) var favoriteResourceIDs: [String]
  @Published private(set) var authURL: URL
  @Published private(set) var apiURL: URL
  @Published private(set) var logFilter: String
  @Published private(set) var internetResourceEnabled: Bool?

  // Enacapsulate Tunnel status here to make it easier for other components to observe
  @Published private(set) var status: NEVPNStatus?

  // User notifications
  @Published private(set) var decision: UNAuthorizationStatus?

  // App configuration
  private var appConfiguration: UserDefaults

#if os(macOS)
  // Track whether our system extension has been installed (macOS)
  @Published private(set) var systemExtensionStatus: SystemExtensionStatus?
#endif

  let sessionNotification = SessionNotification()

  private var resourcesTimer: Timer?
  private var resourceUpdateTask: Task<Void, Never>?

  private var vpnConfigurationManager: VPNConfigurationManager?

  public init() {
    guard let userDefaults = UserDefaults(suiteName: BundleHelper.appGroupId)
    else {
      fatalError("Could not initialize app configuration")
    }

    self.favoriteResourceIDs = userDefaults.stringArray(forKey: Keys.favoriteResourceIDs) ?? []
    self.actorName = userDefaults.string(forKey: Keys.actorName)
    self.authURL = userDefaults.url(forKey: Keys.authURL) ?? Self.defaultAuthURL
    self.apiURL = userDefaults.url(forKey: Keys.apiURL) ?? Self.defaultApiURL
    self.logFilter = userDefaults.string(forKey: Keys.logFilter) ?? Self.defaultLogFilter
    self.internetResourceEnabled = userDefaults.bool(forKey: Keys.internetResourceEnabled)

    self.appConfiguration = userDefaults

    // Load our state from the system. Based on what's loaded, we may need to ask the user for permission for things.
    Task {
      self.decision = await self.sessionNotification.loadAuthorizationStatus()
    }

    // Load system extension status
#if os(macOS)
    Task {
      do {
        self.systemExtensionStatus = try await self.checkSystemExtensionStatus()
      } catch {
        Log.error(error)
      }
    }
#endif

    // Load VPN configuration status
    Task {
      do {
        // Try to load existing configuration
        if let manager = try await VPNConfigurationManager.load() {
          self.vpnConfigurationManager = manager
          try await setupTunnelObservers()
          try await manager.enableConfiguration()
          try ipcClient().start()
        } else {
          status = .invalid
        }
      } catch {
        Log.error(error)
      }
    }

    // Set our sign in handler
    self.sessionNotification.signInHandler = {
      Task {
        do { try await WebAuthSession.signIn(store: self) } catch { Log.error(error) }
      }
    }

    // TODO: setup appConfiguration bindings
  }

  func setupTunnelObservers() async throws {
    let statusChangeHandler: (NEVPNStatus) async throws -> Void = { [weak self] status in
      try await self?.handleStatusChange(newStatus: status)
    }

    try ipcClient().subscribeToVPNStatusUpdates(handler: statusChangeHandler)
    try await handleStatusChange(newStatus: ipcClient().sessionStatus())
  }

  func handleStatusChange(newStatus: NEVPNStatus) async throws {
    status = newStatus

    if status == .connected {
      beginUpdatingResources()
    } else {
      endUpdatingResources()
    }

#if os(macOS)
    // On macOS we must show notifications from the UI process. On iOS, we've already initiated the notification
    // from the tunnel process, because the UI process is not guaranteed to be alive.
    if status == .disconnected {
      do {
        let reason = try await ipcClient().consumeStopReason()
        if reason == .authenticationCanceled {
          await self.sessionNotification.showSignedOutAlertmacOS()
        }
      } catch {
        Log.error(error)
      }
    }

    // When this happens, it's because either our VPN configuration or System Extension (or both) were removed.
    // So load the system extension status again to determine which view to load.
    if status == .invalid {
      self.systemExtensionStatus = try await checkSystemExtensionStatus()
    }
#endif
  }

#if os(macOS)
  func checkSystemExtensionStatus() async throws -> SystemExtensionStatus {
    let checker = SystemExtensionManager()

    let status =
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SystemExtensionStatus, Error>) in
      checker.checkStatus(
        identifier: VPNConfigurationManager.bundleIdentifier,
        continuation: continuation
      )
    }

    // If already installed but the wrong version, go ahead and install.
    // This shouldn't prompt the user.
    if status == .needsReplacement {
      try await installSystemExtension()
    }

    return status
  }

  func installSystemExtension() async throws {
    let installer = SystemExtensionManager()

    // Apple recommends installing the system extension as early as possible after app launch.
    // See https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers
    self.systemExtensionStatus =
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SystemExtensionStatus, Error>) in
      installer.installSystemExtension(
        identifier: VPNConfigurationManager.bundleIdentifier,
        continuation: continuation
      )
    }
  }
#endif

  func installVPNConfiguration() async throws {
    // Create a new VPN configuration in system settings.
    self.vpnConfigurationManager = try await VPNConfigurationManager()

    try await setupTunnelObservers()
  }

  func ipcClient() throws -> IPCClient {
    guard let session = try manager().session()
    else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }

    return IPCClient(session: session)
  }

  func manager() throws -> VPNConfigurationManager {
    guard let vpnConfigurationManager
    else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }

    return vpnConfigurationManager
  }

  func grantNotifications() async throws {
    self.decision = try await sessionNotification.askUserForNotificationPermissions()
  }

  func stop() throws {
    try ipcClient().stop()
  }

  func signIn(authResponse: AuthResponse) async throws {
    // Save actorName
    self.actorName = authResponse.actorName

    try await manager().save(authResponse: authResponse)

    // Bring the tunnel up and send it a token to start
    try ipcClient().start(token: authResponse.token)
  }

  func signOut() throws {
    try ipcClient().signOut()
  }

  func clearLogs() async throws {
    try await ipcClient().clearLogs()
  }

  func toggleInternetResource() async throws {
    let enabled = !(internetResourceEnabled ?? false)
    setInternetResourceEnabled(enabled)
  }

  // MARK: App configuration setters

  func setFavoriteResourceIDs(_ favoriteResourceIDs: [String]) {
    appConfiguration.set(favoriteResourceIDs, forKey: Keys.favoriteResourceIDs)
    self.favoriteResourceIDs = favoriteResourceIDs
  }

  func setActorName(_ actorName: String) {
    appConfiguration.set(actorName, forKey: Keys.actorName)
    self.actorName = actorName
  }

  func setAccountSlug(_ accountSlug: String) {
    appConfiguration.set(accountSlug, forKey: Keys.accountSlug)
    // TODO: Show accountSlug in UI
  }

  func setAuthURL(_ authURL: URL) {
    appConfiguration.set(authURL, forKey: Keys.authURL)
    self.authURL = authURL
  }

  func setApiURL(_ apiURL: URL) {
    appConfiguration.set(apiURL, forKey: Keys.apiURL)
    self.apiURL = apiURL
  }

  func setLogFilter(_ logFilter: String) {
    appConfiguration.set(logFilter, forKey: Keys.logFilter)
    self.logFilter = logFilter
  }

  func setInternetResourceEnabled(_ enabled: Bool) {
    appConfiguration.set(enabled, forKey: Keys.internetResourceEnabled)
    self.internetResourceEnabled = enabled
  }

  // MARK: Private functions

  private func start(token: String? = nil) throws {
    try ipcClient().start(token: token)
  }

  // Network Extensions don't have a 2-way binding up to the GUI process,
  // so we need to periodically ask the tunnel process for them.
  private func beginUpdatingResources() {
    if self.resourcesTimer != nil {
      // Prevent duplicate timer scheduling. This will happen if the system sends us two .connected status updates
      // in a row, which can happen occasionally.
      return
    }

    // Define the Timer's closure
    let updateResources: @Sendable (Timer) -> Void = { _ in
      Task {
        await MainActor.run {
          self.resourceUpdateTask?.cancel()
          self.resourceUpdateTask = Task {
            if !Task.isCancelled {
              do {
                self.resourceList = try await self.ipcClient().fetchResources()
              } catch {
                Log.error(error)
              }
            }
          }
        }
      }
    }

    // Configure the timer
    let intervalInSeconds: TimeInterval = 1
    let timer = Timer(timeInterval: intervalInSeconds, repeats: true, block: updateResources)

    // Schedule the timer on the main runloop
    RunLoop.main.add(timer, forMode: .common)
    resourcesTimer = timer

    // We're impatient, make one call now
    updateResources(timer)
  }

  private func endUpdatingResources() {
    resourceUpdateTask?.cancel()
    resourcesTimer?.invalidate()
    resourcesTimer = nil
    resourceList = ResourceList.loading
  }
}
