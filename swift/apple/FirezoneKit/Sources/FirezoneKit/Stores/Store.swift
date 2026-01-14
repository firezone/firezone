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

  // Encapsulate Tunnel status here to make it easier for other components to observe
  @Published private(set) var vpnStatus: NEVPNStatus?

  // Hash for resource list optimization
  private var resourceListHash = Data()
  private let decoder = PropertyListDecoder()

  // User notifications
  @Published private(set) var decision: UNAuthorizationStatus?

  #if os(macOS)
    // Track whether our system extension has been installed (macOS)
    @Published private(set) var systemExtensionStatus: SystemExtensionStatus?
  #endif

  var firezoneId: String?

  /// Session notification handler. Production uses real implementation,
  /// tests inject MockSessionNotification.
  private(set) var sessionNotification: SessionNotificationProtocol

  private var resourcesTimer: Timer?
  private var resourceUpdateTask: Task<Void, Never>?
  public let configuration: Configuration
  private var lastSavedConfiguration: TunnelConfiguration?
  private var cancellables: Set<AnyCancellable> = []

  // Track which session expired alerts have been shown to prevent duplicates
  // Internal for @testable access
  var shownAlertIds: Set<String>

  /// UserDefaults instance for persisting GUI state.
  /// Injected for testability; defaults to `.standard` in production.
  private let userDefaults: UserDefaults

  // MARK: - Dependency Injection

  /// Tunnel controller for all VPN and IPC operations.
  /// Production uses RealTunnelController, tests inject MockTunnelController.
  private let tunnelController: TunnelControllerProtocol

  #if os(macOS)
    /// System extension manager for checking and installing the network extension.
    /// Production uses SystemExtensionManager, tests inject MockSystemExtensionManager.
    private let systemExtensionManager: SystemExtensionManagerProtocol
  #endif

  /// The current tunnel session, if available.
  /// Used by views that need direct IPC access (e.g., log export).
  var session: NETunnelProviderSession? {
    tunnelController.session as? NETunnelProviderSession
  }

  /// Creates a Store with the given configuration and dependencies.
  ///
  /// - Parameters:
  ///   - configuration: The app configuration. Defaults to `Configuration.shared`.
  ///   - tunnelController: The tunnel controller for VPN/IPC operations.
  ///     Defaults to `RealTunnelController()` for production use.
  ///     Inject `MockTunnelController` for testing.
  ///   - sessionNotification: The session notification handler.
  ///     Defaults to `SessionNotification()` for production use.
  ///     Inject `MockSessionNotification` for testing.
  ///   - systemExtensionManager: (macOS only) The system extension manager.
  ///     Defaults to `SystemExtensionManager()` for production use.
  ///     Inject `MockSystemExtensionManager` for testing.
  ///   - userDefaults: UserDefaults for persisting GUI state. Defaults to `.standard`.
  #if os(macOS)
    public init(
      configuration: Configuration? = nil,
      tunnelController: TunnelControllerProtocol = RealTunnelController(),
      sessionNotification: SessionNotificationProtocol = SessionNotification(),
      systemExtensionManager: SystemExtensionManagerProtocol = SystemExtensionManager(),
      userDefaults: UserDefaults = .standard
    ) {
      self.configuration = configuration ?? Configuration.shared
      self.tunnelController = tunnelController
      self.sessionNotification = sessionNotification
      self.systemExtensionManager = systemExtensionManager
      self.userDefaults = userDefaults
      // Initialize stored properties before calling commonInit()
      self.actorName = userDefaults.string(forKey: "actorName") ?? "Unknown user"
      self.shownAlertIds = Set(userDefaults.stringArray(forKey: "shownAlertIds") ?? [])
      commonInit()
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
      // Initialize stored properties before calling commonInit()
      self.actorName = userDefaults.string(forKey: "actorName") ?? "Unknown user"
      self.shownAlertIds = Set(userDefaults.stringArray(forKey: "shownAlertIds") ?? [])
      commonInit()
    }
  #endif

  private func commonInit() {
    self.sessionNotification.signInHandler = {
      Task {
        do { try await WebAuthSession.signIn(store: self) } catch { Log.error(error) }
      }
    }

    // Forward favorites changes to Store's objectWillChange so SwiftUI views observing Store get notified
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
    func systemExtensionRequest(_ requestType: SystemExtensionRequestType) async throws {
      self.systemExtensionStatus =
        switch requestType {
        case .check:
          try await systemExtensionManager.checkStatus()
        case .install:
          try await systemExtensionManager.install()
        }
    }
  #endif

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
      if vpnStatus == .disconnected {
        if let session = tunnelController.session as? NETunnelProviderSession {
          session.fetchLastDisconnectError { [weak self] error in
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
      try tunnelController.start()
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
    await Telemetry.setAccountSlug(accountSlug)

    // Clear shown alerts when starting a new session so user can see new errors
    shownAlertIds.removeAll()
    userDefaults.removeObject(forKey: "shownAlertIds")

    // Enable and start the tunnel with the auth token
    try await tunnelController.enable()
    try tunnelController.start(token: authResponse.token)
  }

  func signOut() async throws {
    try await tunnelController.signOut()
  }

  func clearLogs() async throws {
    try await tunnelController.clearLogs()
  }

  // MARK: Private functions

  private func markAlertAsShown(_ id: String) {
    shownAlertIds.insert(id)
    userDefaults.set(Array(shownAlertIds), forKey: "shownAlertIds")
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
    // Note: Strong capture of self is intentional - timer is invalidated in endUpdatingResources()
    // when VPN disconnects, preventing retain cycles.
    let updateResources: @Sendable (Timer) -> Void = { _ in
      Task {
        await MainActor.run {
          self.resourceUpdateTask?.cancel()
          self.resourceUpdateTask = Task {
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

  /// Fetches resources from the tunnel provider, using hash-based optimization.
  ///
  /// If the resource list hash matches what the provider has, resources are unchanged.
  /// Otherwise, fetches and caches the new list.
  // Internal for @testable access
  func fetchResources() async throws {
    // Capture current hash before IPC call
    let currentHash = resourceListHash

    // If no data returned, resources haven't changed - no update needed
    guard let data = try await tunnelController.fetchResources(currentHash: currentHash) else {
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
