//
//  Store.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import CryptoKit
import NetworkExtension
import OSLog
import UserNotifications

#if os(macOS)
  import ServiceManagement
  import AppKit
#endif

@MainActor
// TODO: Move some state logic to view models
public final class Store: ObservableObject {
  @Published private(set) var actorName: String
  @Published private(set) var favorites = Favorites()
  @Published private(set) var resourceList: ResourceList = .loading

  // Enacapsulate Tunnel status here to make it easier for other components to observe
  @Published private(set) var vpnStatus: NEVPNStatus?

  // Hash for resource list optimisation
  private var resourceListHash = Data()
  private let decoder = PropertyListDecoder()

  // User notifications
  @Published private(set) var decision: UNAuthorizationStatus?

  #if os(macOS)
    // Track whether our system extension has been installed (macOS)
    @Published private(set) var systemExtensionStatus: SystemExtensionStatus?
  #endif

  var firezoneId: String?

  let sessionNotification = SessionNotification()

  private var resourcesTimer: Timer?
  private var resourceUpdateTask: Task<Void, Never>?
  public let configuration: Configuration
  private var lastSavedConfiguration: TunnelConfiguration?
  private var vpnConfigurationManager: VPNConfigurationManager?
  private var cancellables: Set<AnyCancellable> = []

  // Track which session expired alerts have been shown to prevent duplicates
  private var shownAlertIds: Set<String>

  public init(configuration: Configuration? = nil) {
    self.configuration = configuration ?? Configuration.shared

    // Load GUI-only cached state
    self.actorName = UserDefaults.standard.string(forKey: "actorName") ?? "Unknown user"
    self.shownAlertIds = Set(UserDefaults.standard.stringArray(forKey: "shownAlertIds") ?? [])

    self.sessionNotification.signInHandler = {
      Task {
        do { try await WebAuthSession.signIn(store: self) } catch { Log.error(error) }
      }
    }

    // Forward favourites changes to Store's objectWillChange so SwiftUI views observing Store get notified
    self.favorites.objectWillChange
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    // We monitor for any configuration changes and tell the tunnel service about them
    self.configuration.objectWillChange
      .receive(on: DispatchQueue.main)
      .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)  // These happen quite frequently
      .sink(receiveValue: { [weak self] _ in
        guard let self = self else { return }
        let current = self.configuration.toTunnelConfiguration()

        if self.vpnConfigurationManager == nil {
          // No manager yet, nothing to update
          return
        }

        if self.lastSavedConfiguration == current {
          // No changes
          return
        }

        self.lastSavedConfiguration = current

        Task {
          do {
            guard let session = try self.manager().session() else { return }
            try await IPCClient.setConfiguration(session: session, current)
          } catch {
            Log.error(error)
          }
        }
      })
      .store(in: &cancellables)

    // Load our state from the system. Based on what's loaded, we may need to ask the user for permission for things.
    // When everything loads correctly, we attempt to start the tunnel if connectOnStart is enabled.
    Task {
      do {
        await initNotifications()
        try await initSystemExtension()
        try await initVPNConfiguration()
        try await setupTunnelObservers()
        try await maybeAutoConnect()
      } catch {
        Log.error(error)
      }
    }
  }

  #if os(macOS)
    func systemExtensionRequest(_ requestType: SystemExtensionRequestType) async throws {
      let manager = SystemExtensionManager()

      self.systemExtensionStatus =
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<SystemExtensionStatus, Error>) in
          manager.sendRequest(
            requestType: requestType,
            identifier: VPNConfigurationManager.bundleIdentifier,
            continuation: continuation
          )
        }
    }
  #endif

  private func setupTunnelObservers() async throws {
    let vpnStatusChangeHandler: @MainActor (NEVPNStatus) async throws -> Void = {
      [weak self] status in
      try await self?.handleVPNStatusChange(newVPNStatus: status)
    }

    guard let session = try manager().session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }

    IPCClient.subscribeToVPNStatusUpdates(session: session, handler: vpnStatusChangeHandler)

    let initialStatus = session.status

    // Handle initial status to ensure resources start loading if already connected
    try await handleVPNStatusChange(newVPNStatus: initialStatus)
  }

  private func handleVPNStatusChange(newVPNStatus: NEVPNStatus) async throws {
    self.vpnStatus = newVPNStatus

    if newVPNStatus == .connected {
      beginUpdatingResources()
    } else {
      endUpdatingResources()
    }

    #if os(macOS)
      // On macOS we must show notifications from the UI process. On iOS, we've already initiated the notification
      // from the tunnel process, because the UI process is not guaranteed to be alive.

      // fetchLastDisconnectError is only available on macOS 13+
      if #available(macOS 13, *), vpnStatus == .disconnected {
        do {
          try manager().session()?.fetchLastDisconnectError { error in
            if let nsError = error as NSError?,
              nsError.domain == ConnlibError.errorDomain,
              nsError.code == 0,  // sessionExpired error code
              let reason = nsError.userInfo["reason"] as? String,
              let id = nsError.userInfo["id"] as? String
            {
              // Only show the alert if we haven't shown this specific error before
              Task { @MainActor in
                if !self.shownAlertIds.contains(id) {
                  await self.sessionNotification.showSignedOutAlertmacOS(reason)
                  self.markAlertAsShown(id)
                }
              }
            }
          }
        } catch {
          Log.error(error)
        }
      }

      // When this happens, it's because either our VPN configuration or System Extension (or both) were removed.
      // So load the system extension status again to determine which view to load.
      if vpnStatus == .invalid {
        try await systemExtensionRequest(.check)
      }
    #endif
  }

  private func initNotifications() async {
    self.decision = await self.sessionNotification.loadAuthorizationStatus()
  }

  private func initSystemExtension() async throws {
    #if os(macOS)
      try await systemExtensionRequest(.check)

      // If already installed but the wrong version, go ahead and install. This shouldn't prompt the user.
      if systemExtensionStatus == .needsReplacement {
        Log.info("Replacing system extension with current version")
        try await systemExtensionRequest(.install)
        Log.info("System extension replacement completed successfully")
      }
    #endif
  }

  private func initVPNConfiguration() async throws {
    // Try to load existing configuration
    if let manager = try await VPNConfigurationManager.load() {
      try await manager.maybeMigrateConfiguration()
      self.vpnConfigurationManager = manager
    } else {
      self.vpnStatus = .invalid
    }
  }

  private func maybeAutoConnect() async throws {
    if configuration.connectOnStart {
      try await manager().enable()
      guard let session = try manager().session() else {
        throw VPNConfigurationManagerError.managerNotInitialized
      }
      try IPCClient.start(session: session)
    }
  }
  func installVPNConfiguration() async throws {
    // Create a new VPN configuration in system settings.
    self.vpnConfigurationManager = try await VPNConfigurationManager()

    try await setupTunnelObservers()
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

  public func stop() async throws {
    guard let session = try manager().session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }

    session.stopTunnel()
  }

  func signIn(authResponse: AuthResponse) async throws {
    let actorName = authResponse.actorName
    let accountSlug = authResponse.accountSlug

    // This is only shown in the GUI, cache it here
    self.actorName = actorName
    UserDefaults.standard.set(actorName, forKey: "actorName")

    configuration.accountSlug = accountSlug
    await Telemetry.setAccountSlug(accountSlug)

    try await manager().enable()

    // Clear shown alerts when starting a new session so user can see new errors
    shownAlertIds.removeAll()
    UserDefaults.standard.removeObject(forKey: "shownAlertIds")

    // Bring the tunnel up and send it a token and configuration to start
    guard let session = try manager().session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try IPCClient.start(session: session, token: authResponse.token)
  }

  func signOut() async throws {
    guard let session = try manager().session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try await IPCClient.signOut(session: session)
  }

  func clearLogs() async throws {
    guard let session = try manager().session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try await IPCClient.clearLogs(session: session)
  }

  // MARK: Private functions

  private func markAlertAsShown(_ id: String) {
    shownAlertIds.insert(id)
    UserDefaults.standard.set(Array(shownAlertIds), forKey: "shownAlertIds")
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
                guard let session = try self.manager().session() else { return }
                try await self.fetchResources(session: session)
              } catch let error as NSError {
                // https://developer.apple.com/documentation/networkextension/nevpnerror-swift.struct/code
                if error.domain == "NEVPNErrorDomain" && error.code == 1 {
                  // not initialized yet
                } else {
                  Log.error(error)
                }
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
    resourceListHash = Data()
  }

  /// Fetches resources from the tunnel provider, using hash-based optimisation.
  ///
  /// If the resource list hash matches what the provider has, resources are unchanged.
  /// Otherwise, fetches and caches the new list.
  ///
  /// - Parameter session: The tunnel provider session to communicate with
  /// - Throws: IPCClient.Error if IPC communication fails
  private func fetchResources(session: NETunnelProviderSession) async throws {
    // Capture current hash before IPC call
    let currentHash = resourceListHash

    // If no data returned, resources haven't changed - no update needed
    guard let data = try await IPCClient.fetchResources(session: session, currentHash: currentHash)
    else {
      return
    }

    // Compute new hash and decode resources
    let newHash = Data(SHA256.hash(data: data))
    let decoded = try decoder.decode([Resource].self, from: data)

    // Update both hash and resource list
    resourceListHash = newHash
    resourceList = ResourceList.loaded(decoded)
  }
}
