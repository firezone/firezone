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
  @Published private(set) var status: NEVPNStatus

  // This is not currently updated after it is initialized, but
  // we could periodically update it if we need to.
  @Published private(set) var decision: UNAuthorizationStatus

  let tunnelManager: TunnelManager
  private var sessionNotification: SessionNotification
  private var cancellables: Set<AnyCancellable> = []
  private var resourcesTimer: Timer?

  public init() {
    self.status = .disconnected
    self.decision = .authorized
    self.settings = Settings.defaultValue

    self.sessionNotification = SessionNotification()

    self.tunnelManager = TunnelManager()

    initNotifications()
    loadTunnelManager()
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

  private func loadTunnelManager() {
    // Subscribe to status updates from the tunnel manager
    self.tunnelManager.statusChangeHandler = handleVPNStatusChange

    // Load our existing VPN profile and initialize our state
    self.tunnelManager.load() { loadedStatus, loadedSettings, loadedActorName in
      DispatchQueue.main.async {
        self.status = loadedStatus

        if let loadedSettings = loadedSettings {
          self.settings = loadedSettings
        }

        if let loadedActorName = loadedActorName {
          self.actorName = loadedActorName
        }

        // Try to connect on app launch
        if self.status == .disconnected {
          Task { try await self.start() }
        }
      }
    }
  }

  func requestNotifications() {
    #if os(iOS)
    sessionNotification.askUserForNotificationPermissions()
    #endif
  }

  func createVPNProfile() async throws {
    try await TunnelManager.shared.create()

    // Load the new settings and bind observers
    self.loadTunnelManager()
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

  // Handles the frequent VPN state changes during sign in, sign out, etc.
  private func handleVPNStatusChange(status: NEVPNStatus) async {
    self.status = status

#if os(macOS)
    // On iOS, we can initiate notifications directly from the tunnel process.
    // On macOS, however, the system extension runs as root which doesn't
    // support showing User notifications. Instead, we read the last stopped
    // reason and alert the user if it was due to receiving a 401 from the
    // portal.
    if status == .disconnected,
       let savedValue = try? await self.tunnelManager.consumeStopReason(),
       let rawValue = Int(savedValue),
       let reason = NEProviderStopReason(rawValue: rawValue),
       case .authenticationCanceled = reason
    {
      self.sessionNotification.showSignedOutAlertmacOS()
    }
#endif
  }
}
