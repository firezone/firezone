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

#if os(iOS)
  import UIKit
#endif

@MainActor
// TODO: Move some state logic to view models
public final class Store: ObservableObject {
  /// The actor the portal named in `init`, `nil` until it arrives.
  @Published private(set) var actorName: String?

  /// Who the client certificate says is connecting, which decides what the controls offer.
  @Published private(set) var certificateIdentity: X509ClaimedIdentity = .absent
  @Published private(set) var favorites: Favorites
  @Published private(set) var resourceList: ResourceList = .loading
  @Published private(set) var connectedDevices: [ConnectedDevice] = []

  /// How a running session reads, which the certificate decides along with the controls.
  var sessionHeading: String {
    let state: String
    switch certificateIdentity {
    case .absent: state = "Signed in"
    case .claimed: state = "Connected"
    }

    guard let actorName else { return state }

    return "\(state) as \(actorName)"
  }

  /// How a session ending reads, matching the control the user pressed to end it.
  var endingSessionTitle: String {
    switch certificateIdentity {
    case .absent: return "Signing out…"
    case .claimed: return "Disconnecting…"
    }
  }

  // Encapsulate Tunnel status here to make it easier for other components to observe
  @Published public private(set) var vpnStatus: NEVPNStatus?

  // Hash of the last tunnel state snapshot received from the network extension.
  private var tunnelStateHash = Data()

  // User notifications
  @Published private(set) var decision: UNAuthorizationStatus?

  #if os(macOS)
    // Track whether our system extension has been installed (macOS)
    @Published private(set) var systemExtensionStatus: SystemExtensionStatus?

    // Set to true to request the menu bar be opened programmatically.
    // The UI layer observes this and resets it after handling.
    @Published public var menuBarOpenRequested = false

    // Startup retries and the manual install button can both land on a staged
    // replacement; the user only needs telling once per run.
    private var shownRestartAlert = false

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
    let updateChecker: any UpdateCheckerProtocol
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
  @Published private(set) var vpnConfigurationManager: VPNConfigurationManager?
  private var cancellables: Set<AnyCancellable> = []
  private let tunnelManagerFactory: TunnelProviderManagerFactory

  /// Where the certificate screen reads the certificate from; `nil` reads the keychain.
  let x509CertificateSource: X509CertificateSource?

  private struct ConfigurationSnapshot: Equatable {
    var providerConfiguration: [String: String]
    var internetResourceEnabled: Bool
    var startOnLogin: Bool
  }

  // Track which session expired alerts have been shown to prevent duplicates
  private var shownAlertIds: Set<String>

  /// UserDefaults instance for persisting GUI state.
  let userDefaults: UserDefaults

  /// The app-side log directory; nil when the app group container is unavailable.
  private let logDirectory: URL?

  // Task consuming VPN status updates; its presence means observers are active.
  private var vpnStatusTask: CancellableTask?

  #if os(macOS)
    public init(
      configuration: Configuration? = nil,
      sessionNotification: SessionNotificationProtocol = SessionNotification(),
      systemExtensionManager: (any SystemExtensionManagerProtocol)? = nil,
      updateChecker: (any UpdateCheckerProtocol)? = nil,
      tunnelManagerFactory: TunnelProviderManagerFactory = NETunnelProviderManagerFactory(),
      x509CertificateSource: X509CertificateSource? = nil,
      logDirectory: URL? = SharedAccess.logFolderURL,
      // swiftlint:disable:next no_userdefaults_standard
      userDefaults: UserDefaults = .standard
    ) {
      self.configuration = configuration ?? Configuration.shared
      self.updateChecker =
        updateChecker ?? UpdateChecker(configuration: configuration, userDefaults: userDefaults)
      self.sessionNotification = sessionNotification
      self.systemExtensionManager = systemExtensionManager ?? SystemExtensionManager()
      self.tunnelManagerFactory = tunnelManagerFactory
      self.x509CertificateSource = x509CertificateSource
      self.logDirectory = logDirectory
      self.userDefaults = userDefaults
      self.favorites = Favorites(userDefaults: userDefaults)
      self.shownAlertIds = Set(userDefaults.stringArray(forKey: "shownAlertIds") ?? [])
      self.postInit()
    }
  #else
    public init(
      configuration: Configuration? = nil,
      sessionNotification: SessionNotificationProtocol = SessionNotification(),
      tunnelManagerFactory: TunnelProviderManagerFactory = NETunnelProviderManagerFactory(),
      x509CertificateSource: X509CertificateSource? = nil,
      logDirectory: URL? = SharedAccess.logFolderURL,
      // swiftlint:disable:next no_userdefaults_standard
      userDefaults: UserDefaults = .standard
    ) {
      self.configuration = configuration ?? Configuration.shared
      self.sessionNotification = sessionNotification
      self.tunnelManagerFactory = tunnelManagerFactory
      self.x509CertificateSource = x509CertificateSource
      self.logDirectory = logDirectory
      self.userDefaults = userDefaults
      self.favorites = Favorites(userDefaults: userDefaults)
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
  }

  /// Loads our state from the system. Based on what's loaded, we may need to ask the user for
  /// permission for things. When everything loads correctly, we attempt to start the tunnel if
  /// connectOnStart is enabled.
  ///
  /// Kept out of `init` so that constructing a `Store` only wires it up: installing a system
  /// extension and connecting a tunnel are things the app asks for, not things that happen
  /// because a value was created. Previews and tests build a `Store` and never call this.
  ///
  /// `async` so the caller decides how to run it; the app fires and forgets, but that is
  /// its call to make, not this function's.
  public func start() async {
    // A mocked run leaves launchd alone: the keep-app-running agent resurrects every
    // instance a UI test ends, and the revived copy races the next test's launch.
    if !MockRun.isActive {
      do {
        try await LaunchAgentManager.syncKeepAppRunning()
      } catch {
        Log.error(error)
      }
    }

    await startupSequence()
    await initNotifications()
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
      requestStop()
      NSApp.terminate(nil)
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
      alertIfNeedsReboot()
    }

    /// Tells the user when only a restart can finish an install we just asked for.
    ///
    /// Nothing the app can do finishes a staged replacement, and the system reports it
    /// once, on the request that staged it, so this is the only chance to say so.
    private func alertIfNeedsReboot() {
      guard systemExtensionStatus == .needsReboot, !shownRestartAlert else { return }

      shownRestartAlert = true
      sessionNotification.showRestartRequiredAlertMacOS()
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

    #if os(iOS)
      observeForegroundForFlowLogDrain()
      Task { await drainFlowLogs() }
    #endif

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
            guard let error else { return }

            // Logged before it is classified: every early return in the provider's
            // `startTunnel` reports a `PacketTunnelProviderError`, which carries
            // neither a reason nor an id and would otherwise be dropped silently.
            Log.error(error)

            let nsError = error as NSError

            guard nsError.domain == ConnlibError.errorDomain,
              let code = ConnlibError.Code(rawValue: nsError.code),
              let reason = nsError.userInfo["reason"] as? String,
              let id = nsError.userInfo["id"] as? String
            else {
              // Deduplicated on the error itself, since only connlib mints an id.
              let id = "\(nsError.domain):\(nsError.code)"
              let message = error.localizedDescription

              Task { @MainActor in
                guard !self.shownAlertIds.contains(id) else { return }
                await self.sessionNotification.showDisconnectedAlertMacOS(message)
                self.markAlertAsShown(id)
              }

              return
            }

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

    for attempt in 0..<maxAttempts {
      do {
        Log.debug("Startup: initSystemExtension (attempt \(attempt + 1)/\(maxAttempts))")
        try await initSystemExtension()
        Log.debug("Startup: initVPNConfiguration")
        try await initVPNConfiguration()
        Log.debug("Startup: loadCertificateIdentity")
        await loadCertificateIdentity()
        Telemetry.setEnvironmentOrClose(configuration.apiURL)
        #if os(macOS)
          Log.debug("Startup: drainFlowLogsOnLaunch")
          await drainFlowLogsOnLaunch()
        #endif
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
        try await replaceSystemExtension()
        Log.info("System extension replacement completed successfully")
      }

      // Startup carries on either way, with whichever version the system still has.
      alertIfNeedsReboot()
    #endif
  }

  #if os(macOS)
    /// Installs the current system extension over the one already there.
    ///
    /// macOS holds the swap until the next reboot while the extension being replaced still
    /// has a provider running, and everything the app sends in the meantime goes to the old
    /// version. So a running tunnel comes down for the install and goes back up afterwards,
    /// whether the install worked or not. Only a version mismatch gets this far, so an
    /// up-to-date extension never costs the user a disconnect.
    private func replaceSystemExtension() async throws {
      let session = try await VPNConfigurationManager.load(using: tunnelManagerFactory)?.session()
      let stoppedTunnel: Bool

      if let session {
        stoppedTunnel = await IPCClient.stopIfRunning(session: session)
      } else {
        stoppedTunnel = false
      }

      defer {
        if stoppedTunnel, let session {
          do { try IPCClient.start(session: session) } catch { Log.error(error) }
        }
      }

      self.systemExtensionStatus = try await systemExtensionManager.tryInstall()
    }
  #endif

  private func initVPNConfiguration() async throws {
    // Try to load existing configuration
    if let manager = try await VPNConfigurationManager.load(using: tunnelManagerFactory) {
      try await manager.loadConfiguration(into: configuration, userDefaults: userDefaults)
      await seedInitialSyncedSnapshot()
      self.vpnConfigurationManager = manager
      SharedAccess.markAppRunning()
    } else {
      self.vpnStatus = .invalid
    }
  }

  private func loadCertificateIdentity() async {
    let keychain = X509CertificateSource.keychain { try self.manager().identityReference() }
    let source = x509CertificateSource ?? keychain

    do {
      let certificate = try await source.read().certificate
      let summary = certificate.flatMap { X509CertificateParser.summary(of: $0) }

      certificateIdentity = summary?.identity ?? .absent
    } catch {
      Log.error("Failed to read the client certificate: \(error.localizedDescription)")

      certificateIdentity = .absent
    }
  }

  private func maybeAutoConnect() async throws {
    if configuration.connectOnStart {
      try await manager().save(configuration: configuration)
      try await manager().enable()
      guard let session = try manager().session() else {
        throw VPNConfigurationManagerError.managerNotInitialized
      }

      // Replacing the system extension puts a running tunnel back up itself.
      guard ![.connected, .connecting, .reasserting].contains(session.status) else { return }

      try IPCClient.start(session: session)
    }
  }
  func installVPNConfiguration() async throws {
    // Create a new VPN configuration in system settings.
    self.vpnConfigurationManager = try await VPNConfigurationManager.create(
      using: tunnelManagerFactory
    )

    try await manager().loadConfiguration(into: configuration, userDefaults: userDefaults)
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

  /// Picks up a VPN configuration that the system replaced underneath us.
  ///
  /// Anything that writes the VPN preferences, the headless client included, leaves
  /// every other process holding a copy the system no longer recognises. Ours then
  /// fails every call with `NEVPNError.configurationInvalid` until it is replaced, and
  /// the session it hands out is no longer the one status notifications arrive for, so
  /// the observers have to be pointed at the new one as well.
  private func reloadVPNConfiguration() async throws {
    guard let manager = try await VPNConfigurationManager.load(using: tunnelManagerFactory)
    else { return }

    self.vpnConfigurationManager = manager

    // Releasing it cancels it, and clearing it lets the observers be set up again.
    vpnStatusTask = nil
    try await setupTunnelObservers()
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

  public func requestStop() {
    // No manager or no session is no tunnel, which is where stopping was headed anyway.
    guard let session = try? manager().session() else { return }

    session.stopTunnel()
  }

  func signIn(token: String) async throws {
    try await manager().save(configuration: configuration)
    try await manager().enable()

    // Clear shown alerts when starting a new session so user can see new errors
    shownAlertIds.removeAll()
    userDefaults.removeObject(forKey: "shownAlertIds")

    // Bring the tunnel up and send it a token to start
    guard let session = try manager().session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try IPCClient.start(session: session, token: token)
  }

  /// Starts the session without a token: the portal authenticates the mutual-TLS
  /// connection itself, so nothing has to go through the browser first.
  func connectWithCertificate() async throws {
    try await manager().save(configuration: configuration)
    try await manager().enable()

    shownAlertIds.removeAll()
    userDefaults.removeObject(forKey: "shownAlertIds")

    guard let session = try manager().session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try IPCClient.start(session: session)
  }

  func signOut() async throws {
    guard let session = try manager().session() else {
      throw VPNConfigurationManagerError.managerNotInitialized
    }
    try await IPCClient.signOut(session: session)
  }

  /// Ends the session the way its controls read it: only signing out gives up the token.
  func endSession() async throws {
    switch certificateIdentity {
    case .absent: try await signOut()
    case .claimed: requestStop()
    }
  }

  // Calculates the total size of our logs by summing the size of the
  // app, tunnel, and connlib log directories.
  //
  // On iOS, the log directory is a single folder that contains all three
  // directories, but on macOS, the app log directory lives in a different
  // Group Container than tunnel and connlib directories, so we use IPC to make
  // a call to sum both the tunnel and connlib directories.
  //
  // Unfortunately the IPC method doesn't work on iOS because the tunnel process
  // is not started on demand, so the IPC calls hang. Thus, we use separate code
  // paths for iOS and macOS.
  func logDirectorySize() async -> UInt64? {
    guard let logDirectory else { return nil }

    let appLogSize = await Log.size(of: logDirectory)

    #if os(macOS)
      do {
        guard let session = try manager().session() else {
          throw VPNConfigurationManagerError.managerNotInitialized
        }

        let providerLogSize = try await IPCClient.getLogFolderSize(session: session)

        return UInt64(clamping: appLogSize + providerLogSize)
      } catch {
        if let error = error as? IPCClient.Error,
          case IPCClient.Error.noIPCData = error
        {
          // Will happen if the extension is not enabled
          Log.warning("\(#function): Unable to count logs: \(error). Is the XPC service running?")
        } else {
          Log.error(error)
        }

        return nil
      }
    #else
      return UInt64(clamping: appLogSize)
    #endif
  }

  // On iOS, all the logs are stored in one directory.
  // On macOS, we clear logs from the app process, then call over IPC
  // to clear the provider's log directory.
  func clearLogs() async throws {
    // Deleting a large log tree is blocking filesystem work, so keep it off the
    // main actor and hop back for the provider IPC.
    let logDirectory = self.logDirectory
    try await Task.detached {
      try Log.clear(in: logDirectory)
    }.value

    #if os(macOS)
      guard let session = try manager().session() else {
        throw VPNConfigurationManagerError.managerNotInitialized
      }

      try await IPCClient.clearLogs(session: session)
    #endif
  }

  #if os(macOS)
    func exportLogs(to destination: URL) async throws {
      guard let logDirectory else {
        throw LogExporter.ExportError.invalidSourceDirectory
      }
      guard let session = try manager().session() else {
        throw VPNConfigurationManagerError.managerNotInitialized
      }

      try await LogExporter.export(to: destination, from: logDirectory, session: session)
    }
  #endif

  #if os(iOS)
    /// Exports the logs to a temporary archive and returns its URL.
    func exportLogs() async throws -> URL {
      guard let logDirectory else {
        throw LogExporter.ExportError.invalidSourceDirectory
      }

      let archiveURL = try LogExporter.tempFile()
      try await LogExporter.export(to: archiveURL, from: logDirectory)

      return archiveURL
    }
  #endif

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

      // Reloading is worth one attempt per run of failures: the tunnel not being up
      // yet reports the same error, and that resolves on its own.
      var didReload = false

      while !Task.isCancelled {
        do {
          try await self.pollUpdatesOnce()
          didReload = false
        } catch is CancellationError {
          break
        } catch IPCClient.Error.noIPCData {
          // The extension can go away underneath a connected session, and it answers
          // nothing while it does. The status change that follows stops the poller, so
          // there is nothing to act on here.
          Log.debug("Tunnel did not answer the state poll")
        } catch let error as NSError {
          // https://developer.apple.com/documentation/networkextension/nevpnerror-swift.struct/code
          if error.domain == "NEVPNErrorDomain" && error.code == 1 {
            // Either the tunnel isn't up yet, or the configuration we hold was replaced
            // and every later poll would fail the same way, leaving resources loading
            // forever. Reloading costs a preferences read and settles both.
            if !didReload {
              didReload = true
              do { try await self.reloadVPNConfiguration() } catch { Log.error(error) }
            }
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
    tunnelStateHash = Data()
    connectedDevices.removeAll()
    actorName = nil
    Log.setStreamingActive(false)
  }

  #if os(iOS)
    private func observeForegroundForFlowLogDrain() {
      NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        .sink { [weak self] _ in
          Task { @MainActor in await self?.drainFlowLogs() }
        }
        .store(in: &cancellables)
    }
  #endif

  /// Nudges the provider to run a best-effort flow-log upload pass.
  private func drainFlowLogs() async {
    guard let session = try? manager().session() else { return }
    do {
      try await IPCClient.drainFlowLogs(session: session)
    } catch {
      Log.debug("Failed to nudge flow-log uploader: \(error)")
    }
  }

  #if os(macOS)
    // `vpnStatus == nil` means no Sign In button yet, so the cycle start can't race one.
    private func drainFlowLogsOnLaunch() async {
      guard vpnStatus == nil,
        let session = try? manager().session(),
        session.status == .disconnected
      else { return }

      await drainFlowLogs()
    }
  #endif

  private func pollUpdatesOnce() async throws {
    guard let session = try self.manager().session() else { return }
    let response = try await IPCClient.pollUpdates(
      session: session,
      currentHash: tunnelStateHash
    )

    try Task.checkCancellation()

    guard vpnStatus == .connected else { return }

    if let state = response.state {
      guard let stateHash = response.stateHash else {
        throw IPCClient.Error.decodeIPCDataFailed
      }

      tunnelStateHash = stateHash
      Log.setStreamingActive(state.isLogStreamingActive)

      if let resources = state.resources {
        resourceList = ResourceList.loaded(resources)
      }

      connectedDevices = state.connectedDevices

      if state.actorName == nil, actorName != nil {
        Log.warning("Portal did not name the actor on `init`")
      }

      actorName = state.actorName

      // Caching the account we reached keeps the next sign-in URL and the admin portal
      // link pointing at it, but an MDM profile forcing one is the admin's answer.
      if let accountSlug = state.accountSlug, !configuration.isAccountSlugForced {
        configuration.accountSlug = accountSlug
      }
    }

    await showNotificationsForUnreachableResources(
      unreachableResources: Set(response.notifications),
      resources: resourceList.asArray()
    )
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
