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

  private let tunnelManager: TunnelManager
  private var sessionNotification: SessionNotification
  private var cancellables: Set<AnyCancellable> = []
  private var resourcesTimer: Timer?

  public init() {
    self.status = .disconnected
    self.decision = .authorized
    self.settings = Settings.defaultValue

    self.tunnelManager = TunnelManager()
    self.sessionNotification = SessionNotification()

    initNotifications()
    initTunnelManager()
  }

  public func internetResourceEnabled() -> Bool {
    tunnelManager.internetResourceEnabled
  }

  private func initNotifications() {
    // Finish initializing notification binding
    sessionNotification.signInHandler = {
      Task { await WebAuthSession.signIn(store: self) }
    }

    sessionNotification.$decision
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] decision in
        guard let self = self else { return }
        self.decision = decision
      })
      .store(in: &cancellables)
  }

  private func initTunnelManager() {
    // Subscribe to status updates from the tunnelManager
    tunnelManager.statusChangeHandler = handleVPNStatusChange

    // Load our existing VPN profile and initialize our state
    tunnelManager.load() { loadedStatus, loadedSettings, loadedActorName in
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

  func createVPNProfile() {
    DispatchQueue.main.async {
      Task {
        self.settings = try await self.tunnelManager.create()
      }
    }
  }

  func installSystemExtension() {
#if os(macOS)
    SystemExtensionManager.shared.installSystemExtension(identifier: TunnelManager.bundleIdentifier)
#endif
  }

  func authURL() -> URL? {
    return URL(string: settings.authBaseURL)
  }

  func start(token: String? = nil) async throws {
    guard status == .disconnected
    else {
      Log.app.log("\(#function): Already connected")
      return
    }

    tunnelManager.start(token: token)
  }

  func stop(clearToken: Bool = false) {
    guard [.connected, .connecting, .reasserting].contains(status)
    else { return }

    tunnelManager.stop(clearToken: clearToken)
  }

  func signIn(authResponse: AuthResponse) async throws {
    // Save actorName
    DispatchQueue.main.async { self.actorName = authResponse.actorName }

    try await tunnelManager.saveSettings(settings)
    try await tunnelManager.saveActorName(authResponse.actorName)

    // Bring the tunnel up and send it a token to start
    tunnelManager.start(token: authResponse.token)
  }

  func signOut() async throws {
    // Stop tunnel and clear token
    stop(clearToken: true)
  }

  // Network Extensions don't have a 2-way binding up to the GUI process,
  // so we need to periodically ask the tunnel process for them.
  func beginUpdatingResources(callback: @escaping (ResourceList) -> Void) {
    Log.app.log("\(#function)")

    tunnelManager.fetchResources(callback: callback)
    let intervalInSeconds: TimeInterval = 1
    let timer = Timer(timeInterval: intervalInSeconds, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      tunnelManager.fetchResources(callback: callback)
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
        try await tunnelManager.saveSettings(newSettings)
        DispatchQueue.main.async { self.settings = newSettings }
      } catch {
        Log.app.error("\(#function): \(error)")
      }
    }
  }

  func toggleInternetResource(enabled: Bool) {
    tunnelManager.toggleInternetResource(enabled: enabled)
    var newSettings = settings
    newSettings.internetResourceEnabled = tunnelManager.internetResourceEnabled
    Task {
      try await save(newSettings)
    }
  }

  // Handles the frequent VPN state changes during sign in, sign out, etc.
  private func handleVPNStatusChange(status: NEVPNStatus) async {
    self.status = status

    if status == .disconnected,
       let savedValue = try? String(contentsOf: SharedAccess.providerStopReasonURL, encoding: .utf8),
       let rawValue = Int(savedValue),
       let reason = NEProviderStopReason(rawValue: rawValue),
       case .authenticationCanceled = reason
    {
      await consumeCanceledAuthentication()
    }
  }

  private func consumeCanceledAuthentication() async {
    try? FileManager.default.removeItem(at: SharedAccess.providerStopReasonURL)

    // Show alert (macOS -- iOS is handled in the PacketTunnelProvider)
    // TODO: See if we can show standard notifications NotificationCenter here
#if os(macOS)
    self.sessionNotification.showSignedOutAlertmacOS()
#endif
  }
}
