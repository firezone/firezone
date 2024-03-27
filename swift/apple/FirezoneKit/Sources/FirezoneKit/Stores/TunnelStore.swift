//
//  TunnelStore.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import CryptoKit
import Dependencies
import Foundation
import NetworkExtension
import OSLog

#if os(macOS)
  import AppKit
#endif

enum TunnelStoreError: Error {
  case tunnelCouldNotBeStarted
  case tunnelCouldNotBeStopped
  case cannotSaveWhenConnected
  case cannotSaveIfMissing
  case cannotSignOutWhenConnected
  case stopAlreadyBeingAttempted
  case startTunnelErrored(Error)
}

public struct TunnelStoreKeys {
  static let actorName = "actorName"
  static let authBaseURL = "authBaseURL"
  static let apiURL = "apiURL"
  public static let logFilter = "logFilter"
}

/// A utility class for managing our VPN profile in System Preferences
public final class TunnelStore: ObservableObject {
  // Make our tunnel configuration convenient for SettingsView to consume
  @Published private(set) var settings: Settings

  // Enacapsulate Tunnel status here to make it easier for other components
  // to observe
  @Published private(set) var status: NEVPNStatus

  @Published private(set) var resourceListJSON: String?

  public var manager: NETunnelProviderManager?

  private var resourcesTimer: Timer? {
    didSet(oldValue) { oldValue?.invalidate() }
  }

  private let logger: AppLogger
  private var tunnelObservingTasks: [Task<Void, Never>] = []
  private var cancellables = Set<AnyCancellable>()

  // Use separate bundle IDs for release and debug. Helps with testing releases
  // and dev builds on the same Mac.
  #if DEBUG
    private let bundleIdentifier = Bundle.main.bundleIdentifier.map {
      "\($0).debug.network-extension"
    }
    private let bundleDescription = "Firezone (Debug)"
  #else
    private let bundleIdentifier = Bundle.main.bundleIdentifier.map { "\($0).network-extension" }
    private let bundleDescription = "Firezone"
  #endif

  @Dependency(\.keychain) private var keychain
  @Dependency(\.auth) private var auth
  @Dependency(\.mainQueue) private var mainQueue

  public init(logger: AppLogger) {
    self.logger = logger
    self.status = .disconnected
    self.manager = nil
    self.settings = Settings.defaultValue

    // Connect UI state updates to this manager's status
    setupTunnelObservers()

    Task {
      // loadAllFromPreferences() returns list of tunnel configurations we created. Since our bundle ID
      // can change (by us), find the one that's current and ignore the others.
      let managers = try! await NETunnelProviderManager.loadAllFromPreferences()
      logger.log("\(#function): \(managers.count) tunnel managers found")
      for manager in managers {
        if let protocolConfiguration = (manager.protocolConfiguration as? NETunnelProviderProtocol),
          protocolConfiguration.providerBundleIdentifier == bundleIdentifier
        {
          self.settings = Settings.fromProviderConfiguration(
            providerConfiguration: protocolConfiguration.providerConfiguration as? [String: String])
          self.manager = manager
          self.status = manager.connection.status

          // Stop looking for our tunnel
          break
        }
      }

      // Try to connect on app launch
      if self.status == .disconnected {
        try await start()
      }

      // If we haven't found a manager by this point, consider our status invalid
      // to prompt creating one.
      if manager == nil {
        self.status = .invalid
      }
    }
  }

  // If firezone-id hasn't ever been written, the app is considered
  // to be launched for the first time.
  func firstTime() -> Bool {
    let fileExists = FileManager.default.fileExists(
      atPath: SharedAccess.baseFolderURL.appendingPathComponent("firezone-id").path
    )
    return !fileExists
  }

  // Initialize and save a new VPN profile in system Preferences
  func createManager() async throws {
    let protocolConfiguration = NETunnelProviderProtocol()
    let manager = NETunnelProviderManager()
    let providerConfiguration =
      protocolConfiguration.providerConfiguration
      as? [String: String]
      ?? Settings.defaultValue.toProviderConfiguration()

    protocolConfiguration.providerConfiguration = providerConfiguration
    protocolConfiguration.providerBundleIdentifier = bundleIdentifier
    protocolConfiguration.serverAddress = providerConfiguration[TunnelStoreKeys.apiURL]
    manager.localizedDescription = bundleDescription
    manager.protocolConfiguration = protocolConfiguration

    // Save the new VPN profile to System Preferences
    try await manager.saveToPreferences()

    self.manager = manager
    self.status = .disconnected
  }

  func start(token: String? = nil) async throws {
    logger.log("\(#function)")

    guard let manager = manager
    else {
      logger.error("\(#function): No manager created yet")
      return
    }

    guard ![.connected, .connecting].contains(status)
    else {
      logger.log("\(#function): Already connected")
      return
    }

    manager.isEnabled = true
    try await manager.saveToPreferences()

    let session = castToSession(manager.connection)
    do {
      var options: [String: NSObject]? = nil
      if let token = token {
        options = ["token": token as NSObject]
      }

      try session.startTunnel(options: options)
    } catch {
      logger.error("Error starting tunnel: \(error)")
      throw TunnelStoreError.startTunnelErrored(error)
    }
  }

  func stop(clearToken: Bool = false) async throws {
    logger.log("\(#function)")

    guard let manager = manager else {
      logger.error("\(#function): No manager created yet")
      return
    }

    guard [.connected, .connecting, .reasserting].contains(status)
    else {
      logger.error("\(#function): Already stopped")
      return
    }
    let session = castToSession(manager.connection)
    if clearToken {
      try session.sendProviderMessage("signOut".data(using: .utf8)!) { _ in
        session.stopTunnel()
      }
    } else {
      session.stopTunnel()
    }
  }

  public func cancelSignIn() {
    auth.cancelSignIn()
  }

  func signIn() async throws {
    logger.log("\(#function)")
    guard let manager = manager,
      let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
      var providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
    else {
      logger.error("\(#function): Can't sign in if our tunnel configuration is missing!")
      return
    }

    let authURL = URL(string: settings.authBaseURL)!
    let authResponse = try await auth.signIn(authURL)

    // Save actorName
    providerConfiguration[TunnelStoreKeys.actorName] = authResponse.actorName
    protocolConfiguration.providerConfiguration = providerConfiguration
    manager.protocolConfiguration = protocolConfiguration

    try await manager.saveToPreferences()

    // Bring the tunnel up and send it a token to start
    do {
      try await start(token: authResponse.token)
    } catch {
      logger.error("Error signing in: \(error)")
    }
  }

  func signOut() async throws {
    logger.log("\(#function)")

    // Stop tunnel
    try await stop(clearToken: true)
  }

  func beginUpdatingResources() {
    logger.log("\(#function)")

    self.updateResources()
    let intervalInSeconds: TimeInterval = 1
    let timer = Timer(timeInterval: intervalInSeconds, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      guard self.status == .connected else { return }
      self.updateResources()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.resourcesTimer = timer
  }

  func endUpdatingResources() {
    self.resourcesTimer = nil
  }

  func save(_ settings: Settings) async throws {
    logger.log("\(#function)")

    guard let manager = manager,
      let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
      var providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
    else {
      logger.error("Manager doesn't seem initialized. Can't save advanced settings.")
      throw TunnelStoreError.cannotSaveIfMissing
    }

    if [.connected, .connecting].contains(manager.connection.status) {
      throw TunnelStoreError.cannotSaveWhenConnected
    }

    providerConfiguration = settings.toProviderConfiguration()
    protocolConfiguration.providerConfiguration = providerConfiguration
    protocolConfiguration.serverAddress = providerConfiguration[TunnelStoreKeys.apiURL]
    manager.protocolConfiguration = protocolConfiguration
    try await manager.saveToPreferences()
    self.settings = settings
    self.manager = manager
    self.status = manager.connection.status
  }

  func actorName() -> String? {
    guard let manager = manager,
      let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
      let providerConfiguration = protocolConfiguration.providerConfiguration
    else {
      logger.error("\(#function): Tunnel not initialized!")
      return nil
    }

    return providerConfiguration[TunnelStoreKeys.actorName] as? String
  }

  private func castToSession(_ connection: NEVPNConnection) -> NETunnelProviderSession {
    guard let session = connection as? NETunnelProviderSession else {
      fatalError("Could not cast tunnel connection to NETunnelProviderSession!")
    }

    return session
  }

  private func updateResources() {
    guard let manager = manager
    else {
      logger.error("\(#function): No tunnel created yet")
      return
    }

    let session = castToSession(manager.connection)
    let hash = Data(SHA256.hash(data: Data((resourceListJSON ?? "").utf8)))
    do {
      try session.sendProviderMessage(hash) { [weak self] reply in
        if let reply = reply {
          self?.resourceListJSON = String(data: reply, encoding: .utf8)
        }
      }
    } catch {
      logger.error("Error: sendProviderMessage: \(error)")
    }
  }

  // Receive notifications about our VPN profile status changing,
  // and sync our status to it so UI components can react accordingly.
  private func setupTunnelObservers() {
    logger.log("\(#function)")

    for task in tunnelObservingTasks { task.cancel() }
    tunnelObservingTasks.removeAll()

    tunnelObservingTasks.append(
      Task {
        for await notification in NotificationCenter.default.notifications(
          named: .NEVPNStatusDidChange
        ) {
          await self.handleVPNStatusChange(notification)
        }
        for await _ in NotificationCenter.default.notifications(
          named: .NEVPNConfigurationChange
        ) {
          do {
            try await self.handleVPNConfigurationChange()
          } catch {
            logger.error(
              "\(#function): Error while trying to handle VPN configuration change: \(error)")
          }
        }
      }
    )
  }

  private func handleVPNStatusChange(_ notification: Notification) async {
    guard let session = notification.object as? NETunnelProviderSession
    else {
      logger.error("\(#function): NEVPNStatusDidChange notification doesn't seem to be valid")
      return
    }
    logger.log("\(#function): NEVPNStatusDidChange: \(session.status)")
    status = session.status

    if case .disconnected = status,
      let savedValue = try? String(contentsOf: SharedAccess.providerStopReasonURL, encoding: .utf8),
      let rawValue = Int(savedValue),
      let reason = NEProviderStopReason(rawValue: rawValue),
      case .authenticationCanceled = reason
    {
      await consumeCanceledAuthentication()
    }

    if status != .connected {
      // Reset resources list
      resourceListJSON = nil
    }
  }

  // Handle cases where our stored tunnel manager changes out from under us.
  // This can happen for example if another VPN app turns on and the system
  // decides to turn ours off.
  private func handleVPNConfigurationChange() async throws {
    guard let manager = manager
    else {
      logger.error("\(#function): Our manager is somehow gone!")
      return
    }

    try await manager.loadFromPreferences()

    if !manager.isEnabled {
      logger.log("\(#function): Something turned us off! Shutting down the tunnel")

      try await stop()
    }
  }

  private func consumeCanceledAuthentication() async {
    try? FileManager.default.removeItem(at: SharedAccess.providerStopReasonURL)

    // Show alert (macOS -- iOS is handled in the PacketTunnelProvider)
    // TODO: See if we can show standard notifications NotificationCenter here
    #if os(macOS)
      DispatchQueue.main.async {
        SessionNotificationHelper.showSignedOutAlertmacOS(logger: self.logger, tunnelStore: self)
      }
    #endif
  }
}

// MARK: - Extensions

/// Make NEVPNStatus convertible to a string
extension NEVPNStatus: CustomStringConvertible {
  public var description: String {
    switch self {
    case .disconnected: return "Disconnected"
    case .invalid: return "Invalid"
    case .connected: return "Connected"
    case .connecting: return "Connecting…"
    case .disconnecting: return "Disconnecting…"
    case .reasserting: return "No network connectivity"
    @unknown default: return "Unknown"
    }
  }
}
