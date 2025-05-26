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
  private var configuration: Configuration
  private var vpnConfigurationManager: VPNConfigurationManager?
  private var cancellables: Set<AnyCancellable> = []

  public init(configuration: Configuration? = nil) {
    self.configuration = configuration ?? Configuration.shared

    // Load GUI-only cached state
    self.actorName = UserDefaults.standard.string(forKey: "actorName") ?? "Unknown user"

    self.sessionNotification.signInHandler = {
      Task {
        do { try await WebAuthSession.signIn(store: self) } catch { Log.error(error) }
      }
    }

    // We monitor for any configuration changes and tell the tunnel service about them
    self.configuration.objectWillChange
      .receive(on: DispatchQueue.main)
      .debounce(for: .seconds(0.3), scheduler: DispatchQueue.main) // These happen quite frequently
      .sink(receiveValue: { [weak self] _ in
        guard let self = self else { return }

        if self.vpnConfigurationManager != nil {
          Task { do { try await self.ipcClient().setConfiguration(self.configuration) } catch { Log.error(error) } }
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
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SystemExtensionStatus, Error>) in
      manager.sendRequest(
        requestType: requestType,
        identifier: VPNConfigurationManager.bundleIdentifier,
        continuation: continuation
      )
    }
  }
#endif

  private func setupTunnelObservers() async throws {
    let vpnStatusChangeHandler: (NEVPNStatus) async throws -> Void = { [weak self] status in
      try await self?.handleVPNStatusChange(newVPNStatus: status)
    }
    try ipcClient().subscribeToVPNStatusUpdates(handler: vpnStatusChangeHandler)
    self.vpnStatus = try ipcClient().sessionStatus()
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
    if vpnStatus == .disconnected {
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
      try await systemExtensionRequest(.install)
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
      try ipcClient().start()
    }
  }
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
    let actorName = authResponse.actorName
    let accountSlug = authResponse.accountSlug

    // This is only shown in the GUI, cache it here
    self.actorName = actorName
    UserDefaults.standard.set(actorName, forKey: "actorName")

    configuration.accountSlug = accountSlug
    Telemetry.accountSlug = accountSlug

    try await manager().enable()
    try await ipcClient().setConfiguration(configuration)

    // Bring the tunnel up and send it a token to start
    try ipcClient().start(token: authResponse.token)
  }

  func signOut() async throws {
    try await ipcClient().signOut()
  }

  func clearLogs() async throws {
    try await ipcClient().clearLogs()
  }

  // MARK: Private functions

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
  }
}
