//
//  Store.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import NetworkExtension
import OSLog
import SystemPackage
import UserNotifications

#if os(macOS)
  import AppKit
  import ServiceManagement
#endif

@MainActor
// TODO: Move some state logic to view models
public final class Store: ObservableObject {
  @Published private(set) var actorName: String
  @Published private(set) var favorites = Favorites()
  @Published private(set) var resourceList: ResourceList = .loading

  // Encapsulate Tunnel status here to make it easier for other components to observe
  @Published public private(set) var vpnStatus: NEVPNStatus?

  // Hash for resource list optimisation
  private var connlibStateHash = Data()

  // User notifications
  @Published private(set) var decision: UNAuthorizationStatus?

  #if os(macOS)
    // Track whether our system extension has been installed (macOS)
    @Published private(set) var systemExtensionStatus: SystemExtensionStatus?

    // Set to true to request the menu bar be opened programmatically.
    // The UI layer observes this and resets it after handling.
    @Published public var menuBarOpenRequested = false
  #endif

  /// Session notification handler. Production uses real implementation,
  /// tests inject MockSessionNotification.
  private(set) var sessionNotification: SessionNotificationProtocol
  #if os(macOS)
    let updateChecker: any UpdateCheckerProtocol
    private let systemExtensionManager: any SystemExtensionManagerProtocol
  #endif

  private var stateTimer: Timer?
  private var stateUpdateTask: Task<Void, Never>?
  public let configuration: Configuration
  private var lastSavedConfiguration: TunnelConfiguration?
  private var cancellables: Set<AnyCancellable> = []

  // Track which session expired alerts have been shown to prevent duplicates
  // Internal for @testable access
  var shownAlertIds: Set<String>

  // Track which unreachable resource notifications we have already shown
  private var unreachableResources: Set<UnreachableResource> = []

  /// UserDefaults instance for persisting GUI state.
  /// Injected for testability; defaults to `.standard` in production.
  private let userDefaults: UserDefaults

  // MARK: - Dependency Injection

  /// Tunnel controller for all VPN and IPC operations.
  /// Production uses RealTunnelController, tests inject MockTunnelController.
  private let tunnelController: TunnelControllerProtocol

  #if os(macOS)
    public init(
      configuration: Configuration? = nil,
      tunnelController: TunnelControllerProtocol = RealTunnelController(),
      sessionNotification: SessionNotificationProtocol = SessionNotification(),
      updateChecker: (any UpdateCheckerProtocol)? = nil,
      systemExtensionManager: (any SystemExtensionManagerProtocol)? = nil,
      userDefaults: UserDefaults = .standard
    ) {
      self.configuration = configuration ?? Configuration.shared
      self.updateChecker = updateChecker ?? UpdateChecker(configuration: configuration)
      self.tunnelController = tunnelController
      self.sessionNotification = sessionNotification
      self.systemExtensionManager = systemExtensionManager ?? SystemExtensionManager()
      self.userDefaults = userDefaults
      self.actorName = userDefaults.string(forKey: "actorName") ?? "Unknown user"
      self.shownAlertIds = Set(userDefaults.stringArray(forKey: "shownAlertIds") ?? [])
      self.postInit()
    }
  #else
    public init(
      configuration: Configuration? = nil,
      tunnelController: TunnelControllerProtocol = RealTunnelController(),
      sessionNotification: SessionNotificationProtocol = SessionNotification(),
      userDefaults: UserDefaults = .standard
    ) {
      self.configuration = configuration ?? Configuration.shared
      self.tunnelController = tunnelController
      self.sessionNotification = sessionNotification
      self.userDefaults = userDefaults
      self.actorName = userDefaults.string(forKey: "actorName") ?? "Unknown user"
      self.shownAlertIds = Set(userDefaults.stringArray(forKey: "shownAlertIds") ?? [])

      self.postInit()
    }
  #endif

  private func postInit() {
    self.sessionNotification.signInHandler = {
      do { try await WebAuthSession.signIn(store: self) } catch { Log.error(error) }
    }

    // Forward favorites changes to Store's objectWillChange so SwiftUI redraws.
    // This is necessary because Favorites is a separate ObservableObject, and SwiftUI
    // doesn't automatically propagate nested ObservableObject changes through @Published
    // properties. Without this manual forwarding, toggling favorites in MenuBarView
    // wouldn't trigger a menu redraw until the next unrelated state change occurred.
    self.favorites.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    // Forward internet resource toggle changes for immediate UI feedback.
    // The debounced configuration.objectWillChange subscription above handles
    // tunnel sync but adds 0.3s latency. This provides instant menu updates.
    self.configuration.$publishedInternetResourceEnabled
      .dropFirst()  // Skip initial value
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    // Monitor configuration changes and propagate to tunnel service
    setupConfigurationObserver()

    // Load our state from the system. Based on what's loaded, we may need to ask the user for permission for things.
    // When everything loads correctly, we attempt to start the tunnel if connectOnStart is enabled.
    Task {
      await startupSequence()
      await initNotifications()
    }
  }

  // MARK: - Configuration Observer

  /// Sets up the configuration change observer with debouncing.
  private func setupConfigurationObserver() {
    self.configuration.objectWillChange
      .receive(on: DispatchQueue.main)
      .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)  // These happen quite frequently
      .sink(receiveValue: { [weak self] _ in
        guard let self = self else { return }
        let current = self.configuration.toTunnelConfiguration()

        if self.lastSavedConfiguration == current {
          // No changes
          return
        }

        self.lastSavedConfiguration = current

        Task {
          do {
            try await self.tunnelController.setConfiguration(current)
          } catch {
            // Tunnel controller not ready yet - this is expected during startup
            Log.debug("Config change ignored: \(error)")
          }
        }
      })
      .store(in: &cancellables)
  }

  #if os(macOS)
    /// Returns the appropriate menu bar icon name for the current state
    public var menuBarIconName: String {
      Self.menuBarIcon(for: vpnStatus, updateAvailable: updateChecker.updateAvailable)
    }

    /// Requests the menu bar dropdown to be opened programmatically.
    /// The UI layer observes `menuBarOpenRequested` and handles the actual opening.
    public func requestOpenMenuBar() {
      menuBarOpenRequested = true
    }

    /// Returns the appropriate icon name from asset catalog for the given state
    /// - Parameters:
    ///   - status: Current VPN connection status
    ///   - updateAvailable: Whether an update is available
    /// - Returns: Icon name string from Assets.xcassets
    nonisolated internal static func menuBarIcon(for status: NEVPNStatus?, updateAvailable: Bool)
      -> String
    {
      switch status {
      case nil, .invalid, .disconnected:
        return updateAvailable ? "MenuBarIconSignedOutNotification" : "MenuBarIconSignedOut"
      case .connected:
        return updateAvailable
          ? "MenuBarIconSignedInConnectedNotification" : "MenuBarIconSignedInConnected"
      case .connecting, .disconnecting, .reasserting:
        return "MenuBarIconConnecting3"
      @unknown default:
        return "MenuBarIconSignedOut"
      }
    }

    func installSystemExtension() async throws {
      self.systemExtensionStatus = try await systemExtensionManager.tryInstall()
    }
  #endif

  private func handleVPNStatusChange(newVPNStatus: NEVPNStatus) async throws {
    self.vpnStatus = newVPNStatus

    if newVPNStatus == .connected {
      beginUpdatingState()
      fetchAndCacheFirezoneId()
    } else {
      endUpdatingState()
    }

    #if os(macOS)
      // On macOS we must show notifications from the UI process. On iOS, we've already initiated the notification
      // from the tunnel process, because the UI process is not guaranteed to be alive.
      if vpnStatus == .disconnected {
        tunnelController.fetchLastDisconnectError { [weak self] error in
          guard let self = self else { return }
          if let nsError = error as NSError?,
            nsError.domain == ConnlibError.errorDomain,
            nsError.code == 0,  // sessionExpired error code
            let reason = nsError.userInfo["reason"] as? String,
            let id = nsError.userInfo["id"] as? String
          {
            // Only show the alert if we haven't shown this specific error before
            Task { @MainActor in
              if !self.shownAlertIds.contains(id) {
                await self.sessionNotification.showSignedOutAlertMacOS(reason)
                self.markAlertAsShown(id)
              }
            }
          }
        }
      }

      // When this happens, it's because either our VPN configuration or System Extension (or both) were removed.
      // So load the system extension status again to determine which view to load.
      if vpnStatus == .invalid {
        self.systemExtensionStatus = try await systemExtensionManager.check()
      }
    #endif
  }

  /// Runs the throwing startup steps with exponential backoff on CancellationError.
  ///
  /// The OS may cancel system extension or VPN requests during boot (e.g. the system
  /// extension daemon isn't ready yet). Steps that run inside the retry loop are
  /// idempotent, so retrying is safe.
  private func startupSequence() async {
    // Configure telemetry once before retryable steps — it only depends on the
    // API URL which is fixed, and calling setEnvironmentOrClose multiple times
    // can close the Sentry SDK with no way to reopen it.
    Telemetry.setEnvironmentOrClose(configuration.apiURL)

    let maxAttempts = 4

    for attempt in 0..<maxAttempts {
      do {
        Log.debug("Startup: initSystemExtension (attempt \(attempt + 1)/\(maxAttempts))")
        try await initSystemExtension()
        Log.debug("Startup: initVPNConfiguration")
        try await initVPNConfiguration()
        Log.debug("Startup: setupTunnelObservers")
        try await setupTunnelObservers()
        Log.debug("Startup: maybeAutoConnect")
        try await maybeAutoConnect()
        return
      } catch is CancellationError {
        if attempt < maxAttempts - 1 {
          let delay = UInt64(1) << attempt  // 1s, 2s, 4s
          Log.info(
            "Startup cancelled by OS, retrying in \(delay)s (attempt \(attempt + 1)/\(maxAttempts))"
          )
          try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }
      } catch {
        Log.error(error)
        return
      }
    }

    Log.warning(
      "Startup sequence gave up after \(maxAttempts) attempts due to repeated cancellation")

    // Transition to a recoverable UI state instead of leaving the user on a spinner.
    // GrantVPNView is shown when systemExtensionStatus == .needsInstall or vpnStatus == .invalid,
    // and it has buttons to manually retry installation.
    #if os(macOS)
      if self.systemExtensionStatus == nil {
        self.systemExtensionStatus = .needsInstall
      }
    #endif
    if self.vpnStatus == nil {
      self.vpnStatus = .invalid
    }
  }

  private func initNotifications() async {
    self.decision = await self.sessionNotification.loadAuthorizationStatus()
  }

  private func initSystemExtension() async throws {
    #if os(macOS)
      self.systemExtensionStatus = try await systemExtensionManager.check()

      // If already installed but the wrong version, go ahead and install. This shouldn't prompt the user.
      if systemExtensionStatus == .needsReplacement {
        Log.info("Replacing system extension with current version")
        self.systemExtensionStatus = try await systemExtensionManager.tryInstall()
        Log.info("System extension replacement completed successfully")
      }
    #endif
  }

  private func initVPNConfiguration() async throws {
    // Try to load existing configuration via the tunnel controller
    let loaded = try await tunnelController.load()
    if !loaded {
      self.vpnStatus = .invalid
    }
  }

  private func setupTunnelObservers() async throws {
    // Subscribe to status updates - must be called after load() so the session exists
    tunnelController.subscribeToStatusUpdates { [weak self] status in
      try await self?.handleVPNStatusChange(newVPNStatus: status)
    }

    // Handle initial status to ensure resources start loading if already connected
    if let initialStatus = tunnelController.session?.status {
      try await handleVPNStatusChange(newVPNStatus: initialStatus)
    }
  }

  private func maybeAutoConnect() async throws {
    if configuration.connectOnStart {
      try await tunnelController.enable()
      try tunnelController.start(configuration: configuration.toTunnelConfiguration())
    }
  }

  func installVPNConfiguration() async throws {
    // Create a new VPN configuration in system settings.
    try await tunnelController.installConfiguration()
  }

  func grantNotifications() async throws {
    self.decision = try await sessionNotification.askUserForNotificationPermissions()
  }

  public func stop() async throws {
    tunnelController.stop()
  }

  func signIn(authResponse: AuthResponse) async throws {
    let actorName = authResponse.actorName
    let accountSlug = authResponse.accountSlug

    // This is only shown in the GUI, cache it here
    self.actorName = actorName
    userDefaults.set(actorName, forKey: "actorName")

    configuration.accountSlug = accountSlug

    // Clear shown alerts when starting a new session so user can see new errors
    shownAlertIds.removeAll()
    userDefaults.removeObject(forKey: "shownAlertIds")

    // Clear notified unreachable resources for fresh session
    unreachableResources.removeAll()

    // Enable and start the tunnel with the auth token
    try await tunnelController.enable()
    try tunnelController.start(
      token: authResponse.token, configuration: configuration.toTunnelConfiguration())
  }

  func signOut() async throws {
    try await tunnelController.signOut()
  }

  func clearLogs() async throws {
    try await tunnelController.clearLogs()
  }

  #if os(macOS)
    func getLogFolderSize() async throws -> Int64 {
      try await tunnelController.getLogFolderSize()
    }

    func exportLogs(fd: FileDescriptor) async throws {
      try await tunnelController.exportLogs(fd: fd)
    }
  #endif

  // MARK: Private functions

  private func fetchAndCacheFirezoneId() {
    // Skip IPC if we already have a cached Firezone ID for this session
    if userDefaults.string(forKey: "encodedFirezoneId") != nil {
      return
    }

    Task {
      do {
        guard let firezoneId = try await tunnelController.fetchFirezoneId()
        else { return }

        userDefaults.set(firezoneId, forKey: "encodedFirezoneId")
        Telemetry.setUser(firezoneId: firezoneId, accountSlug: configuration.accountSlug)
      } catch {
        Log.error(error)
      }
    }
  }

  private func markAlertAsShown(_ id: String) {
    shownAlertIds.insert(id)
    userDefaults.set(Array(shownAlertIds), forKey: "shownAlertIds")
  }

  // Network Extensions don't have a 2-way binding up to the GUI process,
  // so we need to periodically ask the tunnel process for them.
  private func beginUpdatingState() {
    if self.stateTimer != nil {
      // Prevent duplicate timer scheduling. This will happen if the system sends us two .connected status updates
      // in a row, which can happen occasionally.
      return
    }

    // Define the Timer's closure
    // Note: Strong capture of self is intentional - timer is invalidated in endUpdatingResources()
    // when VPN disconnects, preventing retain cycles.
    let updateState: @Sendable (Timer) -> Void = { _ in
      Task {
        await MainActor.run {
          self.stateUpdateTask?.cancel()
          self.stateUpdateTask = Task {
            if !Task.isCancelled {
              do {
                try await self.fetchResources()
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
    let timer = Timer(timeInterval: intervalInSeconds, repeats: true, block: updateState)

    // Schedule the timer on the main runloop
    RunLoop.main.add(timer, forMode: .common)
    stateTimer = timer

    // We're impatient, make one call now
    updateState(timer)
  }

  private func endUpdatingState() {
    stateUpdateTask?.cancel()
    stateTimer?.invalidate()
    stateTimer = nil
    resourceList = ResourceList.loading
    connlibStateHash = Data()
    unreachableResources.removeAll()
  }

  /// Fetches state from the tunnel provider, using hash-based optimisation.
  ///
  /// If the hash matches what the provider has, state is unchanged.
  /// Otherwise, fetches and caches the new state.
  /// Internal for `@testable` access.
  func fetchResources() async throws {
    // Capture current hash before IPC call
    let currentHash = self.connlibStateHash

    // If no data returned, state hasn't changed - no update needed
    guard let data = try await tunnelController.fetchResources(currentHash: currentHash) else {
      return
    }

    // Decode state and compute hash
    let (resources, unreachableResources, hash) = try ConnlibState.decode(from: data)

    // Update both hash and resource list
    self.connlibStateHash = hash

    if let resources = resources {
      resourceList = ResourceList.loaded(resources)
    }

    let newlyUnreachableResources = Set(unreachableResources).subtracting(self.unreachableResources)

    await showNotificationsForUnreachableResources(
      unreachableResources: newlyUnreachableResources,
      resources: resources ?? []
    )

    self.unreachableResources = Set(unreachableResources)
  }

  private func showNotificationsForUnreachableResources(
    unreachableResources: Set<UnreachableResource>,
    resources: [FirezoneKit.Resource]
  ) async {
    for unreachableResource in unreachableResources {
      // Find the resource and site to get names for the notification
      guard let resource = resources.first(where: { $0.id == unreachableResource.resourceId }),
        let site = resource.sites.first
      else {
        Log.debug("Unknown resource: \(unreachableResource.resourceId)")
        continue
      }

      // Show notification based on reason
      let title: String
      let body: String

      switch unreachableResource.reason {
      case .offline:
        title = "Failed to connect to '\(resource.name)'"
        body =
          "All Gateways in the site '\(site.name)' are offline. Contact your administrator to resolve this issue."
      case .versionMismatch:
        title = "Failed to connect to '\(resource.name)'"
        body =
          "Your Firezone Client is incompatible with all Gateways in the site '\(site.name)'. Please update your Client to the latest version and contact your administrator if the issue persists."
      }

      await sessionNotification.showResourceNotification(title: title, body: body)
    }
  }

}
