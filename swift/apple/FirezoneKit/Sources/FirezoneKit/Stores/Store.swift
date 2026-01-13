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

  private(set) lazy var sessionNotification = SessionNotification()

  private var resourcesTimer: Timer?
  private var resourceUpdateTask: Task<Void, Never>?
  private var connectingWatchdog: ConnectionWatchdog?
  public let configuration: Configuration
  private var lastSavedConfiguration: TunnelConfiguration?
  private var vpnConfigurationManager: VPNConfigurationManager?
  private var cancellables: Set<AnyCancellable> = []

  // Track which session expired alerts have been shown to prevent duplicates
  private var shownAlertIds: Set<String>

  // MARK: - Dependency Injection for Testing

  /// Injected tunnel controller for testing (nil in production)
  private let tunnelController: TunnelControllerProtocol?

  /// IPC client for tunnel communication. Set in setupTunnelObservers() for production,
  /// or injected directly in test initializer.
  private var _ipcClient: IPCClientProtocol?

  /// Watchdog timeout in nanoseconds (configurable for tests)
  private var watchdogTimeoutNs: UInt64 = 10_000_000_000  // 10 seconds default

  /// Retry policy for resource fetching (configurable for tests)
  private var resourceRetryPolicy: RetryPolicy = .resourceFetch

  /// Returns the IPC client, throwing if not yet initialized.
  /// Follows the same pattern as manager() for consistency.
  private func requireIPCClient() throws -> IPCClientProtocol {
    guard let client = _ipcClient else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    return client
  }

  public init(configuration: Configuration? = nil) {
    self.configuration = configuration ?? Configuration.shared
    self.tunnelController = nil  // Production uses VPNConfigurationManager directly

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

    // Monitor configuration changes and propagate to tunnel service
    setupConfigurationObserver()

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

  // MARK: - Test Initializer

  /// UserDefaults instance for test access (nil in production).
  private var testDefaults: UserDefaults?

  /// Test-only initializer for dependency injection.
  ///
  /// Use this to inject mock tunnel controller and IPC client for unit testing.
  /// The Store will use injected dependencies instead of real VPNConfigurationManager/IPCClient.
  ///
  /// - Parameters:
  ///   - configuration: The Configuration instance to use
  ///   - tunnelController: Mock tunnel controller for VPN operations
  ///   - ipcClient: Mock IPC client for tunnel communication
  ///   - retryPolicy: Retry policy for resource fetching
  ///   - userDefaults: Optional UserDefaults for testing persisted state (actorName, shownAlertIds)
  init(
    configuration: Configuration,
    tunnelController: TunnelControllerProtocol,
    ipcClient: IPCClientProtocol,
    retryPolicy: RetryPolicy = .resourceFetch,
    userDefaults: UserDefaults? = nil
  ) {
    self.configuration = configuration
    self.tunnelController = tunnelController
    self._ipcClient = ipcClient
    self.resourceRetryPolicy = retryPolicy
    self.testDefaults = userDefaults

    // Load from provided UserDefaults if available, otherwise use test defaults
    if let defaults = userDefaults {
      self.actorName = defaults.string(forKey: "actorName") ?? "Test User"
      self.shownAlertIds = Set(defaults.stringArray(forKey: "shownAlertIds") ?? [])
    } else {
      self.actorName = "Test User"
      self.shownAlertIds = []
    }

    // Subscribe to status updates from the injected controller
    tunnelController.subscribeToStatusUpdates { [weak self] status in
      try await self?.handleVPNStatusChange(newVPNStatus: status)
    }

    // Subscribe to configuration changes (same as production init)
    setupConfigurationObserver()
  }

  // MARK: - Configuration Observer

  /// Sets up the configuration change observer with debouncing.
  ///
  /// Called by both production and test initializers to ensure configuration
  /// changes are propagated to the tunnel.
  private func setupConfigurationObserver() {
    self.configuration.objectWillChange
      .receive(on: DispatchQueue.main)
      .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
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
            try await self.requireIPCClient().setConfiguration(current)
          } catch {
            // IPC client not ready yet - this is expected during startup
            Log.debug("Config change ignored: \(error)")
          }
        }
      })
      .store(in: &cancellables)
  }

  /// Set watchdog timeout for testing (shorter timeouts for faster tests).
  func setWatchdogTimeout(_ timeoutNs: UInt64) {
    watchdogTimeoutNs = timeoutNs
  }

  /// Directly trigger a resource fetch cycle for testing.
  func testFetchResources() async throws {
    try await fetchResourcesWithIPC(ipcClient: requireIPCClient())
  }

  /// Returns true if there are no shown alert IDs (for testing alert clearing).
  func testShownAlertIdsIsEmpty() -> Bool {
    shownAlertIds.isEmpty
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

    // Create the IPC client now that we have a valid session
    self._ipcClient = RealIPCClient(session: session)

    IPCClient.subscribeToVPNStatusUpdates(session: session, handler: vpnStatusChangeHandler)

    let initialStatus = session.status

    // Handle initial status to ensure resources start loading if already connected
    try await handleVPNStatusChange(newVPNStatus: initialStatus)
  }

  private func handleVPNStatusChange(newVPNStatus: NEVPNStatus) async throws {
    self.vpnStatus = newVPNStatus

    // Cancel any existing connecting watchdog on status change
    connectingWatchdog?.cancel()

    if newVPNStatus == .connected {
      beginUpdatingResources()
    } else if newVPNStatus == .connecting {
      endUpdatingResources()

      // Start watchdog - if still connecting after timeout, auto-restart the tunnel.
      // This handles race conditions during extension startup (e.g., cycleStart causing "Adapter is nil").
      connectingWatchdog = ConnectionWatchdog(timeoutNs: watchdogTimeoutNs) { [weak self] in
        guard let self else { return }
        Log.warning("Connection timeout - stuck in connecting state, restarting...")

        // Use injected controller if available (tests), otherwise use real manager
        if let controller = self.tunnelController {
          controller.session?.stopTunnel()
          try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms delay
          try? controller.start()
        } else if let session = try? self.manager().session() {
          session.stopTunnel()
          try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms delay
          try? IPCClient.start(session: session)
        }
      }
      connectingWatchdog?.start()
    } else {
      endUpdatingResources()
    }

    #if os(macOS)
      // On macOS we must show notifications from the UI process. On iOS, we've already initiated the notification
      // from the tunnel process, because the UI process is not guaranteed to be alive.
      if vpnStatus == .disconnected {
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

    // Clear shown alerts when starting a new session so user can see new errors
    shownAlertIds.removeAll()
    UserDefaults.standard.removeObject(forKey: "shownAlertIds")

    // In production, enable the manager first (tests skip this)
    if tunnelController == nil {
      try await manager().enable()
    }

    try requireIPCClient().start(token: authResponse.token)
  }

  func signOut() async throws {
    try await requireIPCClient().signOut()
  }

  func clearLogs() async throws {
    try await requireIPCClient().clearLogs()
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
                try await self.fetchResourcesWithIPC(ipcClient: self.requireIPCClient())
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
  /// - Parameter attempt: Current retry attempt (0-based), used for exponential backoff
  /// - Parameter retryPolicy: Policy controlling retry behavior (default: .resourceFetch)
  /// - Throws: IPCClient.Error if IPC communication fails
  private func fetchResources(
    session: NETunnelProviderSession,
    attempt: Int = 0,
    retryPolicy: RetryPolicy = .resourceFetch
  ) async throws {
    // Capture current hash before IPC call
    let currentHash = resourceListHash

    // If no data returned, resources haven't changed - no update needed
    guard let data = try await IPCClient.fetchResources(session: session, currentHash: currentHash)
    else {
      // If we're still in loading state and got nil, the adapter may not be ready yet.
      // Retry with exponential backoff to handle race conditions during extension startup.
      if case .loading = resourceList, retryPolicy.shouldRetry(attempt: attempt) {
        let delayMs = retryPolicy.delayMs(forAttempt: attempt)
        Log.debug(
          "Resource fetch returned nil while loading, retrying in \(delayMs)ms (attempt \(attempt + 1)/\(retryPolicy.maxAttempts))"
        )
        try await Task.sleep(nanoseconds: retryPolicy.delay(forAttempt: attempt))
        return try await fetchResources(
          session: session, attempt: attempt + 1, retryPolicy: retryPolicy)
      }
      return
    }

    // Compute new hash and decode resources
    let newHash = Data(SHA256.hash(data: data))
    let decoded = try decoder.decode([Resource].self, from: data)

    // Update both hash and resource list
    resourceListHash = newHash
    resourceList = ResourceList.loaded(decoded)
  }

  /// Fetches resources using an injected IPC client (for testing).
  ///
  /// Uses the same retry logic as fetchResources but with the protocol-based client.
  private func fetchResourcesWithIPC(
    ipcClient: IPCClientProtocol,
    attempt: Int = 0
  ) async throws {
    let currentHash = resourceListHash
    let retryPolicy = resourceRetryPolicy

    guard let data = try await ipcClient.fetchResources(currentHash: currentHash)
    else {
      if case .loading = resourceList, retryPolicy.shouldRetry(attempt: attempt) {
        let delayMs = retryPolicy.delayMs(forAttempt: attempt)
        Log.debug(
          "Resource fetch returned nil while loading, retrying in \(delayMs)ms (attempt \(attempt + 1)/\(retryPolicy.maxAttempts))"
        )
        try await Task.sleep(nanoseconds: retryPolicy.delay(forAttempt: attempt))
        return try await fetchResourcesWithIPC(ipcClient: ipcClient, attempt: attempt + 1)
      }
      return
    }

    let newHash = Data(SHA256.hash(data: data))
    let decoded = try decoder.decode([Resource].self, from: data)

    resourceListHash = newHash
    resourceList = ResourceList.loaded(decoded)
  }
}
