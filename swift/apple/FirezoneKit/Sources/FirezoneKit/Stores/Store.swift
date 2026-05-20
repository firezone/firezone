//
//  Store.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import NetworkExtension
import OSLog
import UserNotifications

#if os(macOS)
  import AppKit
#endif

@MainActor
// TODO: Move some state logic to view models
public final class Store: ObservableObject {
  @Published private(set) var actorName: String
  @Published private(set) var favorites: Favorites
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

    public var quitMenuTitle: String {
      switch vpnStatus {
      case .connected, .connecting:
        return "Disconnect and Quit"
      default:
        return "Quit"
      }
    }
  #endif

  private(set) var sessionNotification: SessionNotificationProtocol
  #if os(macOS)
    let updateChecker: UpdateChecker
    private let systemExtensionManager: any SystemExtensionManagerProtocol
  #endif

  private static let statePollingInterval: Duration = .seconds(1)
  private var stateUpdateTask: Task<Void, Never>?
  public let configuration: Configuration
  private var lastSyncedSnapshot: ConfigurationSnapshot?
  // Serialization for `syncConfiguration`. The MainActor is reentrant at `await`
  // points, so without a guard a second sink invocation could observe a stale
  // `lastSyncedSnapshot` mid-flight. Treat `Store` as a single-method serial
  // actor: while one sync is running, later callers just flip `pending` and the
  // running pass loops until the latest target is durable.
  private var syncInFlight = false
  private var syncPending = false
  private var vpnConfigurationManager: VPNConfigurationManager?
  private var cancellables: Set<AnyCancellable> = []
  private let tunnelManagerFactory: TunnelProviderManagerFactory

  private struct ConfigurationSnapshot: Equatable {
    var providerConfiguration: [String: String]
    var internetResourceEnabled: Bool
    var startOnLogin: Bool
  }

  // Track which session expired alerts have been shown to prevent duplicates
  private var shownAlertIds: Set<String>

  // Track which unreachable resource notifications we have already shown
  private var unreachableResources: Set<UnreachableResource> = []

  /// UserDefaults instance for persisting GUI state.
  let userDefaults: UserDefaults

  // Task consuming VPN status updates; its presence means observers are active.
  private var vpnStatusTask: CancellableTask?

  #if os(macOS)
    public init(
      configuration: Configuration? = nil,
      sessionNotification: SessionNotificationProtocol = SessionNotification(),
      systemExtensionManager: (any SystemExtensionManagerProtocol)? = nil,
      tunnelManagerFactory: TunnelProviderManagerFactory = NETunnelProviderManagerFactory(),
      // swiftlint:disable:next no_userdefaults_standard
      userDefaults: UserDefaults = .standard
    ) {
      self.configuration = configuration ?? Configuration.shared
      self.updateChecker = UpdateChecker(configuration: configuration, userDefaults: userDefaults)
      self.sessionNotification = sessionNotification
      self.systemExtensionManager = systemExtensionManager ?? SystemExtensionManager()
      self.tunnelManagerFactory = tunnelManagerFactory
      self.userDefaults = userDefaults
      self.favorites = Favorites(userDefaults: userDefaults)
      self.actorName = self.configuration.actorName
      self.shownAlertIds = Set(userDefaults.stringArray(forKey: "shownAlertIds") ?? [])
      self.postInit()
    }
  #else
    public init(
      configuration: Configuration? = nil,
      sessionNotification: SessionNotificationProtocol = SessionNotification(),
      tunnelManagerFactory: TunnelProviderManagerFactory = NETunnelProviderManagerFactory(),
      // swiftlint:disable:next no_userdefaults_standard
      userDefaults: UserDefaults = .standard
    ) {
      self.configuration = configuration ?? Configuration.shared
      self.sessionNotification = sessionNotification
      self.tunnelManagerFactory = tunnelManagerFactory
      self.userDefaults = userDefaults
      self.favorites = Favorites(userDefaults: userDefaults)
      self.actorName = self.configuration.actorName
      self.shownAlertIds = Set(userDefaults.stringArray(forKey: "shownAlertIds") ?? [])
      self.postInit()
    }
  #endif

  private func postInit() {
    self.sessionNotification.signInHandler = {
      do { try await WebAuthSession.signIn(store: self) } catch { Log.error(error) }
    }

    // We monitor for configuration changes and persist them to the VPN provider configuration.
    self.configuration.objectWillChange
      .receive(on: DispatchQueue.main)
      .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)  // These happen quite frequently
      .sink(receiveValue: { [weak self] _ in
        guard let self = self else { return }
        self.objectWillChange.send()
        guard self.vpnConfigurationManager != nil else { return }
        Task { @MainActor in await self.syncConfiguration() }
      })
      .store(in: &cancellables)

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
    self.configuration.internetResourceEnabledPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    // Load our state from the system. Based on what's loaded, we may need to ask the user for permission for things.
    // When everything loads correctly, we attempt to start the tunnel if connectOnStart is enabled.
    Task {
      do {
        try await LaunchAgentManager.syncKeepAppRunning()
      } catch {
        Log.error(error)
      }

      await startupSequence()
      await initNotifications()
    }
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

    public func quitApp() {
      SharedAccess.clearAppRunning()
      Task {
        do { try await stop() } catch { Log.error(error) }
        NSApp.terminate(nil)
      }
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

  private func setupTunnelObservers() async throws {
    guard vpnStatusTask == nil else {
      Log.debug("Tunnel observers already set up, skipping")
      return
    }

    guard let session = try manager().session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }

    let statusStream = IPCClient.vpnStatusUpdates(session: session)

    vpnStatusTask = CancellableTask { [weak self] in
      for await status in statusStream {
        do { try await self?.handleVPNStatusChange(newVPNStatus: status) } catch {
          Log.error(error)
        }
      }
    }

    // Handle initial status to ensure resources start loading if already connected
    try await handleVPNStatusChange(newVPNStatus: session.status)
  }

  private func handleVPNStatusChange(newVPNStatus: NEVPNStatus) async throws {
    self.vpnStatus = newVPNStatus

    if newVPNStatus == .connected {
      beginUpdatingState()
      fetchAndCacheFirezoneId()
      // Reset disconnect-alert dedup so failures during the next disconnect cycle aren't suppressed
      shownAlertIds.removeAll()
      userDefaults.removeObject(forKey: "shownAlertIds")
    } else {
      endUpdatingState()
    }

    #if os(macOS)
      // On macOS we must show notifications from the UI process. On iOS, we've already initiated the notification
      // from the tunnel process, because the UI process is not guaranteed to be alive.
      if vpnStatus == .disconnected {
        do {
          try manager().session()?.fetchLastDisconnectError { error in
            if let nsError = error as NSError?,
              nsError.domain == ConnlibError.errorDomain,
              let code = ConnlibError.Code(rawValue: nsError.code),
              let reason = nsError.userInfo["reason"] as? String,
              let id = nsError.userInfo["id"] as? String
            {
              // Only show the alert if we haven't shown this specific error before
              Task { @MainActor in
                guard !self.shownAlertIds.contains(id) else { return }
                switch code {
                case .sessionExpired:
                  await self.sessionNotification.showSignedOutAlertMacOS(reason)
                case .disconnected:
                  await self.sessionNotification.showDisconnectedAlertMacOS(reason)
                }
                self.markAlertAsShown(id)
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
    let maxAttempts = 4
    var telemetryConfigured = false

    for attempt in 0..<maxAttempts {
      do {
        Log.debug("Startup: initSystemExtension (attempt \(attempt + 1)/\(maxAttempts))")
        try await initSystemExtension()
        Log.debug("Startup: initVPNConfiguration")
        try await initVPNConfiguration()
        if !telemetryConfigured {
          Telemetry.setEnvironmentOrClose(configuration.apiURL)
          telemetryConfigured = true
        }
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
    // Try to load existing configuration
    if let manager = try await VPNConfigurationManager.load(using: tunnelManagerFactory) {
      try await manager.loadConfiguration(into: configuration, userDefaults: userDefaults)
      actorName = configuration.actorName
      await seedInitialSyncedSnapshot()
      self.vpnConfigurationManager = manager
      SharedAccess.markAppRunning()
    } else {
      self.vpnStatus = .invalid
    }
  }

  private func maybeAutoConnect() async throws {
    if configuration.connectOnStart {
      try await manager().save(configuration: configuration)
      try await manager().enable()
      guard let session = try manager().session() else {
        throw VPNConfigurationManagerError.managerNotInitialized
      }
      try IPCClient.start(session: session)
    }
  }
  func installVPNConfiguration() async throws {
    // Create a new VPN configuration in system settings.
    self.vpnConfigurationManager = try await VPNConfigurationManager(
      manager: tunnelManagerFactory.createManager()
    )

    try await manager().loadConfiguration(into: configuration, userDefaults: userDefaults)
    actorName = configuration.actorName
    await seedInitialSyncedSnapshot()

    try await setupTunnelObservers()
    SharedAccess.markAppRunning()
  }

  func manager() throws -> VPNConfigurationManager {
    guard let vpnConfigurationManager
    else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }

    return vpnConfigurationManager
  }

  /// Establishes `lastSyncedSnapshot` after the VPN configuration is loaded and
  /// performs the one-shot reconciliation of OS-level state (LoginItem) that
  /// isn't covered by simply mirroring `providerConfiguration` to disk.
  ///
  /// If the LoginItem sync fails we deliberately leave `startOnLogin` inverted
  /// in the snapshot so the next `syncConfiguration` pass diffs and retries.
  private func seedInitialSyncedSnapshot() async {
    var snapshot = currentSnapshot()
    do {
      try await LoginItemManager.syncStartOnLogin(startOnLogin: configuration.startOnLogin)
    } catch {
      Log.error(error)
      snapshot.startOnLogin.toggle()
    }
    lastSyncedSnapshot = snapshot
  }

  private func currentSnapshot() -> ConfigurationSnapshot {
    ConfigurationSnapshot(
      providerConfiguration: configuration.toProviderConfiguration(),
      internetResourceEnabled: configuration.internetResourceEnabled,
      startOnLogin: configuration.startOnLogin
    )
  }

  private func syncConfiguration() async {
    if syncInFlight {
      syncPending = true
      return
    }
    syncInFlight = true
    defer { syncInFlight = false }

    repeat {
      syncPending = false
      await runSyncOnce()
    } while syncPending
  }

  private func runSyncOnce() async {
    let target = currentSnapshot()
    // initVPNConfiguration / installVPNConfiguration seed lastSyncedSnapshot
    // before the configuration sink can fire, so this is expected to be non-nil.
    guard var synced = lastSyncedSnapshot else { return }
    defer { lastSyncedSnapshot = synced }
    guard synced != target else { return }

    // Advance `synced` per-field only after each step's async work succeeds so a
    // failure in one step doesn't lose the retry signal for the others.
    do {
      if synced.startOnLogin != target.startOnLogin {
        try await LoginItemManager.syncStartOnLogin(startOnLogin: target.startOnLogin)
        synced.startOnLogin = target.startOnLogin
      }
      if synced.providerConfiguration != target.providerConfiguration {
        try await manager().save(providerConfiguration: target.providerConfiguration)
        synced.providerConfiguration = target.providerConfiguration
      }
      if synced.internetResourceEnabled != target.internetResourceEnabled {
        // The new value is already persisted via providerConfiguration above;
        // push it live to a running tunnel as well. If IPC throws we exit before
        // advancing synced so the next configuration change retries.
        if let session = try manager().session(),
          [.connected, .connecting, .reasserting].contains(session.status)
        {
          try await IPCClient.setInternetResourceEnabled(
            session: session,
            target.internetResourceEnabled
          )
        }
        synced.internetResourceEnabled = target.internetResourceEnabled
      }
    } catch {
      Log.error(error)
    }
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

    // This is only shown in the GUI.
    configuration.actorName = actorName
    self.actorName = actorName

    configuration.accountSlug = accountSlug

    try await manager().save(configuration: configuration)
    try await manager().enable()

    // Clear shown alerts when starting a new session so user can see new errors
    shownAlertIds.removeAll()
    userDefaults.removeObject(forKey: "shownAlertIds")

    // Clear notified unreachable resources for fresh session
    unreachableResources.removeAll()

    // Bring the tunnel up and send it a token to start
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

  private func fetchAndCacheFirezoneId() {
    if let firezoneId = userDefaults.string(forKey: "encodedFirezoneId") {
      Telemetry.setUser(firezoneId: firezoneId, accountSlug: configuration.accountSlug)
      return
    }

    Task {
      do {
        guard let session = try manager().session(),
          let firezoneId = try await IPCClient.fetchEncodedFirezoneId(session: session)
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
    if self.stateUpdateTask != nil {
      // Prevent duplicate poller scheduling. This will happen if the system sends us two .connected status updates
      // in a row, which can happen occasionally.
      return
    }

    self.stateUpdateTask = Task {
      defer { self.stateUpdateTask = nil }

      while !Task.isCancelled {
        do {
          try await self.pollStateOnce()
        } catch is CancellationError {
          break
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

        do {
          try await Task.sleep(for: Self.statePollingInterval)
        } catch is CancellationError {
          break
        } catch {
          Log.error(error)
          break
        }
      }
    }
  }

  private func endUpdatingState() {
    stateUpdateTask?.cancel()
    stateUpdateTask = nil
    resourceList = ResourceList.loading
    connlibStateHash = Data()
    unreachableResources.removeAll()
    Log.setStreamingActive(false)
  }

  private func pollStateOnce() async throws {
    guard let session = try self.manager().session() else { return }
    try await self.fetchState(session: session)
  }

  /// Fetches state from the tunnel provider, using hash-based optimisation.
  ///
  /// If the hash matches what the provider has, state is unchanged.
  /// Otherwise, fetches and caches the new state.
  ///
  /// - Parameter session: The tunnel provider session to communicate with
  /// - Throws: IPCClient.Error if IPC communication fails
  private func fetchState(session: NETunnelProviderSession) async throws {
    // Capture current hash before IPC call
    let currentHash = self.connlibStateHash

    // If no data returned, state hasn't changed - no update needed
    guard let data = try await IPCClient.fetchState(session: session, currentHash: currentHash)
    else {
      return
    }

    try Task.checkCancellation()

    guard vpnStatus == .connected else { return }

    // Decode state and compute hash
    let (state, hash) = try ConnlibState.decode(from: data)

    // Update both hash and resource list
    self.connlibStateHash = hash

    // Propagate log streaming state from the NE to the main app process
    Log.setStreamingActive(state.isLogStreamingActive)

    if let resources = state.resources {
      resourceList = ResourceList.loaded(resources)
    }

    let newlyUnreachableResources = Set(state.unreachableResources).subtracting(
      self.unreachableResources)

    await showNotificationsForUnreachableResources(
      unreachableResources: newlyUnreachableResources,
      resources: state.resources ?? []
    )

    self.unreachableResources = Set(state.unreachableResources)
  }

  private func showNotificationsForUnreachableResources(
    unreachableResources: Set<UnreachableResource>,
    resources: [FirezoneKit.Resource]
  ) async {
    for unreachableResource in unreachableResources {
      guard !Task.isCancelled, vpnStatus == .connected else { return }

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
