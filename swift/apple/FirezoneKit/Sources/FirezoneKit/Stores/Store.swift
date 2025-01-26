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
  @Published private(set) var actorName: String?

  // Make our tunnel configuration convenient for SettingsView to consume
  @Published private(set) var settings: Settings

  // Enacapsulate Tunnel status here to make it easier for other components
  // to observe
  @Published private(set) var status: NEVPNStatus?

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
  }

  public func internetResourceEnabled() -> Bool {
    self.vpnConfigurationManager.internetResourceEnabled
  }

  func bindToVPNConfigurationUpdates() async throws {
    // Load our existing VPN configuration and set an update handler
    try await self.vpnConfigurationManager.loadFromPreferences(
      vpnStateUpdateHandler: { @MainActor [weak self] status, settings, actorName in
        guard let self else { return }

        self.status = status

        if let settings {
          self.settings = settings
        }

        if let actorName {
          self.actorName = actorName
        }

        if status == .disconnected {
          maybeShowSignedOutAlert()
        }
      }
    )
  }

  /// On iOS, we can initiate notifications directly from the tunnel process.
  /// On macOS, however, the system extension runs as root which doesn't
  /// support showing User notifications. Instead, we read the last stopped
  /// reason and alert the user if it was due to receiving a 401 from the
  /// portal.
  private func maybeShowSignedOutAlert() {
    Task.detached { [weak self] in
      guard let self else { return }

      do {
        if let savedValue = try await self.vpnConfigurationManager.consumeStopReason(),
           let rawValue = Int(savedValue),
           let reason = NEProviderStopReason(rawValue: rawValue),
           case .authenticationCanceled = reason
        {
#if os(macOS)
          await self.sessionNotification.showSignedOutAlertmacOS()
#endif
        }
      } catch {
        Log.error(error)
      }
    }
  }

#if os(macOS)
  func checkedSystemExtensionStatus() async throws -> SystemExtensionStatus {
    let checker = SystemExtensionManager()

    let status = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<SystemExtensionStatus, Error>) in

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
    self.systemExtensionStatus = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<SystemExtensionStatus, Error>) in

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

  func authURL() -> URL? {
    return URL(string: settings.authBaseURL)
  }

  private func start(token: String? = nil) throws {
    guard status == .disconnected
    else {
      Log.log("\(#function): Already connected")
      return
    }

    try self.vpnConfigurationManager.start(token: token)
  }

  func stop(clearToken: Bool = false) {
    guard [.connected, .connecting, .reasserting].contains(status)
    else { return }

    self.vpnConfigurationManager.stop(clearToken: clearToken)
  }

  func signIn(authResponse: AuthResponse) async throws {
    // Save actorName
    await MainActor.run { self.actorName = authResponse.actorName }

    try await self.vpnConfigurationManager.saveSettings(settings)
    try await self.vpnConfigurationManager.saveAuthResponse(authResponse)

    // Bring the tunnel up and send it a token to start
    try self.vpnConfigurationManager.start(token: authResponse.token)
  }

  func signOut() async throws {
    // Stop tunnel and clear token
    stop(clearToken: true)
  }

  // Network Extensions don't have a 2-way binding up to the GUI process,
  // so we need to periodically ask the tunnel process for them.
  func beginUpdatingResources(callback: @escaping (ResourceList) -> Void) {
    Log.log("\(#function)")

    // Define the Timer's closure
    let updateResources: @Sendable (Timer) -> Void = { _timer in
      Task.detached { [weak self] in
        await self?.vpnConfigurationManager.fetchResources(callback: callback)
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

  func save(_ newSettings: Settings) {
    Task.detached { [weak self] in
      guard let self else { return }

      do {
        try await self.vpnConfigurationManager.saveSettings(newSettings)
        await MainActor.run { self.settings = newSettings }
      } catch {
        Log.error(error)
      }
    }
  }

  func toggleInternetResource(enabled: Bool) {
    self.vpnConfigurationManager.toggleInternetResource(enabled: enabled)
    var newSettings = settings
    newSettings.internetResourceEnabled = self.vpnConfigurationManager.internetResourceEnabled
    save(newSettings)
  }
}
