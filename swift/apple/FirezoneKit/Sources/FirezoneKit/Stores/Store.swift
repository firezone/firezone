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

  // Track whether our system extension has been installed (macOS)
  @Published private(set) var isInstalled: Bool = false

  // This is not currently updated after it is initialized, but
  // we could periodically update it if we need to.
  @Published private(set) var decision: UNAuthorizationStatus

  let vpnProfileManager: VPNProfileManager
  private var sessionNotification: SessionNotification
  private var cancellables: Set<AnyCancellable> = []
  private var resourcesTimer: Timer?

  public init() {
    // Initialize all stored properties
    self.decision = .authorized
    self.settings = Settings.defaultValue
    self.sessionNotification = SessionNotification()
    self.vpnProfileManager = VPNProfileManager()

    initNotifications()
  }

  public func internetResourceEnabled() -> Bool {
    self.vpnProfileManager.internetResourceEnabled
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
    try await self.vpnProfileManager.loadFromPreferences(
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
    Task {
      do {
        if let savedValue = try await self.vpnProfileManager.consumeStopReason(),
           let rawValue = Int(savedValue),
           let reason = NEProviderStopReason(rawValue: rawValue),
           case .authenticationCanceled = reason
        {
#if os(macOS)
          self.sessionNotification.showSignedOutAlertmacOS()
#endif
        }
      } catch {
        Log.error(error)
      }
    }
  }

  func checkedIfInstalled() async throws {
#if os(macOS)
    let checker = SystemExtensionManager()

    self.isInstalled = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Bool, Error>) in

      checker.isInstalled(
        identifier: VPNProfileManager.bundleIdentifier,
        continuation: continuation
      )
    }
#endif
  }

  func installSystemExtension() async throws {
#if os(macOS)
    let installer = SystemExtensionManager()

    // Apple recommends installing the system extension as early as possible after app launch.
    // See https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers
    self.isInstalled = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Bool, Error>) in

      installer.installSystemExtension(
        identifier: VPNProfileManager.bundleIdentifier,
        continuation: continuation
      )
    }
#endif
  }

  func grantVPNPermission() async throws {
    // Create a new VPN profile in system settings.
    try await self.vpnProfileManager.create()

    // Reload our state
    try await bindToVPNProfileUpdates()
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

    self.vpnProfileManager.start(token: token)
  }

  func stop(clearToken: Bool = false) {
    guard [.connected, .connecting, .reasserting].contains(status)
    else { return }

    self.vpnProfileManager.stop(clearToken: clearToken)
  }

  func signIn(authResponse: AuthResponse) async throws {
    // Save actorName
    DispatchQueue.main.async { self.actorName = authResponse.actorName }

    try await self.vpnProfileManager.saveSettings(settings)
    try await self.vpnProfileManager.saveAuthResponse(authResponse)

    // Bring the tunnel up and send it a token to start
    self.vpnProfileManager.start(token: authResponse.token)
  }

  func signOut() async throws {
    // Stop tunnel and clear token
    stop(clearToken: true)
  }

  // Network Extensions don't have a 2-way binding up to the GUI process,
  // so we need to periodically ask the tunnel process for them.
  func beginUpdatingResources(callback: @escaping (ResourceList) -> Void) {
    Log.log("\(#function)")

    self.vpnProfileManager.fetchResources(callback: callback)
    let intervalInSeconds: TimeInterval = 1
    let timer = Timer(timeInterval: intervalInSeconds, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.vpnProfileManager.fetchResources(callback: callback)
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
        try await self.vpnProfileManager.saveSettings(newSettings)
        DispatchQueue.main.async { self.settings = newSettings }
      } catch {
        Log.error(error)
      }
    }
  }

  func toggleInternetResource(enabled: Bool) {
    self.vpnProfileManager.toggleInternetResource(enabled: enabled)
    var newSettings = settings
    newSettings.internetResourceEnabled = self.vpnProfileManager.internetResourceEnabled
    Task {
      try await save(newSettings)
    }
  }
}
