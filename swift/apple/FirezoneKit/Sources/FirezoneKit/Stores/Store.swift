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
  @Published private(set) var favorites = Favorites()
  @Published private(set) var resourceList: ResourceList = .loading
  @Published private(set) var actorName: String?

  // Make our tunnel configuration convenient for SettingsView to consume
  @Published var settings: Settings

  // Enacapsulate Tunnel status here to make it easier for other components
  // to observe
  @Published private(set) var status: NEVPNStatus?

  @Published private(set) var decision: UNAuthorizationStatus?

#if os(macOS)
  // Track whether our system extension has been installed (macOS)
  @Published private(set) var systemExtensionStatus: SystemExtensionStatus?
#endif

  let vpnConfigurationManager: VPNConfigurationManager
  private var sessionNotification: SessionNotification
  private var cancellables: Set<AnyCancellable> = []
  private var resourcesTimer: Timer?

  public init() {
    // Initialize all stored properties
    self.settings = Settings.defaultValue
    self.sessionNotification = SessionNotification()
    self.vpnConfigurationManager = VPNConfigurationManager()

    self.sessionNotification.signInHandler = {
      Task {
        do { try await WebAuthSession.signIn(store: self) } catch { Log.error(error) }
      }
    }

    Task {
      // Load user's decision whether to allow / disallow notifications
      self.decision = await self.sessionNotification.loadAuthorizationStatus()

      // Load VPN configuration and system extension status
      do {
        try await self.bindToVPNConfigurationUpdates()
        let vpnConfigurationStatus = self.status

#if os(macOS)
        let systemExtensionStatus = try await self.checkedSystemExtensionStatus()

        if systemExtensionStatus != .installed
            || vpnConfigurationStatus == .invalid {

          // Show the main Window if VPN permission needs to be granted
          AppView.WindowDefinition.main.openWindow()
        } else {
          AppView.WindowDefinition.main.window()?.close()
        }
#endif

        if vpnConfigurationStatus == .disconnected {

          // Try to connect on start
          try self.vpnConfigurationManager.start()
        }
      } catch {
        Log.error(error)
      }
    }
  }

  public func internetResourceEnabled() -> Bool {
    self.vpnConfigurationManager.internetResourceEnabled
  }

  func bindToVPNConfigurationUpdates() async throws {
    // Load our existing VPN configuration and set an update handler
    try await self.vpnConfigurationManager.loadFromPreferences(
      vpnStateUpdateHandler: { @MainActor [weak self] status, settings, actorName, stopReason in
        guard let self else { return }

        self.status = status

        if let settings {
          self.settings = settings
        }

        if let actorName {
          self.actorName = actorName
        }

        if status == .connected {
          self.beginUpdatingResources { resourceList in
            self.resourceList = resourceList
          }
        }

        if status == .disconnected {
          self.endUpdatingResources()
          self.resourceList = ResourceList.loading
        }

#if os(macOS)
        // On macOS we must show notifications from the UI process. On iOS, we've already initiated the notification
        // from the tunnel process, because the UI process is not guaranteed to be alive.
        if status == .disconnected,
           stopReason == .authenticationCanceled {
          await self.sessionNotification.showSignedOutAlertmacOS()
        }
#endif
      }
    )
  }

#if os(macOS)
  func checkedSystemExtensionStatus() async throws -> SystemExtensionStatus {
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

    self.systemExtensionStatus = status

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

  func grantVPNPermission() async throws {
    // Create a new VPN configuration in system settings.
    try await self.vpnConfigurationManager.create()

    // Reload our state
    try await bindToVPNConfigurationUpdates()
  }

  func grantNotifications() async throws {
    self.decision = try await sessionNotification.askUserForNotificationPermissions()
  }

  func authURL() -> URL? {
    return URL(string: settings.authBaseURL)
  }

  private func start(token: String? = nil) throws {
    try self.vpnConfigurationManager.start(token: token)
  }

  func stop() throws {
    try self.vpnConfigurationManager.stop()
  }

  func signIn(authResponse: AuthResponse) async throws {
    // Save actorName
    self.actorName = authResponse.actorName

    try await self.vpnConfigurationManager.saveSettings(settings)
    try await self.vpnConfigurationManager.saveAuthResponse(authResponse)

    // Bring the tunnel up and send it a token to start
    try self.vpnConfigurationManager.start(token: authResponse.token)
  }

  func signOut() throws {
    try self.vpnConfigurationManager.signOut()
  }

  // Network Extensions don't have a 2-way binding up to the GUI process,
  // so we need to periodically ask the tunnel process for them.
  func beginUpdatingResources(callback: @escaping @MainActor (ResourceList) -> Void) {
    Log.log("\(#function)")

    if self.resourcesTimer != nil {
      // Prevent duplicate timer scheduling. This will happen if the system sends us two .connected status updates
      // in a row, which can happen occasionally.
      return
    }

    // Define the Timer's closure
    let updateResources: @Sendable (Timer) -> Void = { _ in
      Task {
        do {
          let resources = try await self.vpnConfigurationManager.fetchResources()
          await callback(resources)
        } catch {
          Log.error(error)
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

  func endUpdatingResources() {
    resourcesTimer?.invalidate()
    resourcesTimer = nil
  }

  func save(_ newSettings: Settings) async throws {
    try await self.vpnConfigurationManager.saveSettings(newSettings)
    self.settings = newSettings
  }

  func toggleInternetResource(enabled: Bool) async throws {
    try self.vpnConfigurationManager.toggleInternetResource(enabled: enabled)
    var newSettings = settings
    newSettings.internetResourceEnabled = self.vpnConfigurationManager.internetResourceEnabled
    try await save(newSettings)
  }
}
