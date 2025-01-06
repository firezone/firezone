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

  // This is not currently updated after it is initialized, but
  // we could periodically update it if we need to.
  @Published private(set) var decision: UNAuthorizationStatus

  let tunnelManager: TunnelManager
  private var sessionNotification: SessionNotification
  private var cancellables: Set<AnyCancellable> = []
  private var resourcesTimer: Timer?

  public init() {
    // Initialize all stored properties
    self.decision = .authorized
    self.settings = Settings.defaultValue
    self.sessionNotification = SessionNotification()
    self.tunnelManager = TunnelManager()

    initNotifications()
  }

  public func internetResourceEnabled() -> Bool {
    self.tunnelManager.internetResourceEnabled
  }

  private func initNotifications() {
    // Finish initializing notification binding
    sessionNotification.signInHandler = {
      WebAuthSession.signIn(store: self)
    }

    sessionNotification.$decision
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] decision in
        guard let self = self else { return }
        self.decision = decision
      })
      .store(in: &cancellables)
  }

  func bindToVPNProfileUpdates() async throws {
    // Load our existing VPN profile and set an update handler
    try await self.tunnelManager.loadFromPreferences(
      vpnStateUpdateHandler: { [weak self] status, settings, actorName in
        guard let self else { return }

        DispatchQueue.main.async {
          self.status = status

          if let settings {
            self.settings = settings
          }

          if let actorName {
            self.actorName = actorName
          }
        }

#if os(macOS)
        if status == .disconnected {
          maybeShowSignedOutAlert()
        }
#endif
      }
    )
  }

  /// On iOS, we can initiate notifications directly from the tunnel process.
  /// On macOS, however, the system extension runs as root which doesn't
  /// support showing User notifications. Instead, we read the last stopped
  /// reason and alert the user if it was due to receiving a 401 from the
  /// portal.
  private func maybeShowSignedOutAlert() {
    Task {
      do {
        if let savedValue = try await self.tunnelManager.consumeStopReason(),
           let rawValue = Int(savedValue),
           let reason = NEProviderStopReason(rawValue: rawValue),
           case .authenticationCanceled = reason
        {
          self.sessionNotification.showSignedOutAlertmacOS()
        }
      } catch {
        Log.error(error)
      }
    }
  }

  func grantVPNPermissions() async throws {

#if os(macOS)
    // Install the system extension. No-op if already installed.
    try await installSystemExtension()
#endif

    // Create a new VPN profile in system settings.
    try await self.tunnelManager.create()

    // Reload our state
    try await bindToVPNProfileUpdates()
  }

  private func installSystemExtension() async throws {
    // Apple recommends installing the system extension as early as possible after app launch.
    // See https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in

      SystemExtensionManager.shared.installSystemExtension(
        identifier: TunnelManager.bundleIdentifier,
        continuation: continuation
      )
    }
  }

  func requestNotifications() {
    #if os(iOS)
    sessionNotification.askUserForNotificationPermissions()
    #endif
  }

  func authURL() -> URL? {
    return URL(string: settings.authBaseURL)
  }

  func start(token: String? = nil) async throws {
    guard status == .disconnected
    else {
      Log.log("\(#function): Already connected")
      return
    }

    self.tunnelManager.start(token: token)
  }

  func stop(clearToken: Bool = false) {
    guard [.connected, .connecting, .reasserting].contains(status)
    else { return }

    self.tunnelManager.stop(clearToken: clearToken)
  }

  func signIn(authResponse: AuthResponse) async throws {
    // Save actorName
    DispatchQueue.main.async { self.actorName = authResponse.actorName }

    try await self.tunnelManager.saveSettings(settings)
    try await self.tunnelManager.saveAuthResponse(authResponse)

    // Bring the tunnel up and send it a token to start
    self.tunnelManager.start(token: authResponse.token)
  }

  func signOut() async throws {
    // Stop tunnel and clear token
    stop(clearToken: true)
  }

  // Network Extensions don't have a 2-way binding up to the GUI process,
  // so we need to periodically ask the tunnel process for them.
  func beginUpdatingResources(callback: @escaping (ResourceList) -> Void) {
    Log.log("\(#function)")

    self.tunnelManager.fetchResources(callback: callback)
    let intervalInSeconds: TimeInterval = 1
    let timer = Timer(timeInterval: intervalInSeconds, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.tunnelManager.fetchResources(callback: callback)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    resourcesTimer = timer
  }

  func endUpdatingResources() {
    resourcesTimer?.invalidate()
    resourcesTimer = nil
  }

  func save(_ newSettings: Settings) async throws {
    Task {
      do {
        try await self.tunnelManager.saveSettings(newSettings)
        DispatchQueue.main.async { self.settings = newSettings }
      } catch {
        Log.error(error)
      }
    }
  }

  func toggleInternetResource(enabled: Bool) {
    self.tunnelManager.toggleInternetResource(enabled: enabled)
    var newSettings = settings
    newSettings.internetResourceEnabled = self.tunnelManager.internetResourceEnabled
    Task {
      try await save(newSettings)
    }
  }
}
