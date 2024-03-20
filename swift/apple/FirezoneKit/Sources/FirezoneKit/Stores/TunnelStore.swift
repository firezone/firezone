//
//  TunnelStore.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Dependencies
import Foundation
import NetworkExtension
import OSLog

enum TunnelStoreError: Error {
  case tunnelCouldNotBeStarted
  case tunnelCouldNotBeStopped
  case cannotSaveToTunnelWhenConnected
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
  @Published private(set) var status: NEVPNStatus {
    didSet { self.logger.log("status changed: \(self.status.description)") }
  }

  @Published private(set) var resources = DisplayableResources()

  public var manager: NETunnelProviderManager?

  private var resourcesTimer: Timer? {
    didSet(oldValue) { oldValue?.invalidate() }
  }

  private let logger: AppLogger
  private var tunnelObservingTasks: [Task<Void, Never>] = []
  private var startTunnelContinuation: CheckedContinuation<(), Error>?
  private var stopTunnelContinuation: CheckedContinuation<(), Error>?
  private var cancellables = Set<AnyCancellable>()

  // Use separate bundle IDs for release and debug. Helps with testing releases
  // and dev builds on the same Mac.
  #if DEBUG
    private let bundleIdentifier = Bundle.main.bundleIdentifier.map { "\($0).debug.network-extension" }
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
    self.status = .invalid
    self.manager = nil
    self.settings = Settings.defaultValue

    Task {
      // loadAllFromPreferences() returns list of tunnel configurations we created. Since our bundle ID
      // can change (by us), find the one that's current and ignore the others.
      let managers = try! await NETunnelProviderManager.loadAllFromPreferences()
      logger.log("\(#function): \(managers.count) tunnel managers found")
      for manager in managers {
        if let protocolConfiguration = (manager.protocolConfiguration as? NETunnelProviderProtocol),
           protocolConfiguration.providerBundleIdentifier == bundleIdentifier {
          self.settings = Settings.fromProviderConfiguration(providerConfiguration: protocolConfiguration.providerConfiguration as? [String: String])
          self.manager = manager
          self.status = manager.connection.status

          // Stop looking for our tunnel
          break
        }
      }

      setupTunnelObservers()
    }
  }

  // Initialize and save a new VPN profile in system Preferences
  func createManager() async throws {
    guard manager == nil else {
      fatalError("Manager unexpectedly exists already.")
    }

    let protocolConfiguration = NETunnelProviderProtocol()
    let manager = NETunnelProviderManager()
    let providerConfiguration =
      protocolConfiguration.providerConfiguration
      as? [String: String]
      ?? Settings.defaultValue.toProviderConfiguration()

    protocolConfiguration.providerConfiguration = providerConfiguration
    protocolConfiguration.providerBundleIdentifier = bundleIdentifier
    protocolConfiguration.serverAddress = settings.apiURL
    manager.localizedDescription = bundleDescription
    manager.protocolConfiguration = protocolConfiguration

    // Save the new VPN profile to System Preferences
    try await manager.saveToPreferences()

    self.manager = manager
    self.status = manager.connection.status
  }

  func start() async throws {
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
    try await manager.loadFromPreferences()

    let session = castToSession(manager.connection)
    do {
      try session.startTunnel()
    } catch {
      throw TunnelStoreError.startTunnelErrored(error)
    }
    try await withCheckedThrowingContinuation { continuation in
      self.startTunnelContinuation = continuation
    }
  }

  func stop() async throws {
    logger.log("\(#function)")
    guard stopTunnelContinuation == nil else {
      throw TunnelStoreError.stopAlreadyBeingAttempted
    }

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
    session.stopTunnel()
    try await withCheckedThrowingContinuation { continuation in
      self.stopTunnelContinuation = continuation
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

    logger.log("\(#function)")

    let authURL = URL(string: settings.authBaseURL)!
    let authResponse = try await auth.signIn(authURL)
    let tokenRef = try await keychain.store(authResponse.token)

    // Save token and actorName
    providerConfiguration[TunnelStoreKeys.actorName] = authResponse.actorName
    protocolConfiguration.passwordReference = tokenRef
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()

    // Start tunnel
    try await start()
  }

  // from authStore
  func signOut() async throws {
    guard let manager = manager,
          ![.disconnecting, .disconnected].contains(status),
          let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
          let passwordReference = protocolConfiguration.passwordReference
    else {
      logger.error("\(#function): Tunnel seems to be already disconnected")
      return
    }
    logger.log("\(#function)")

    // Clear token
    try await keychain.delete(passwordReference)

    // Stop tunnel
    try await stop()
  }

  func beginUpdatingResources() {
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
    guard let manager = manager,
          let protocolConfiguration = manager.protocolConfiguration as? NETunnelProviderProtocol,
          var providerConfiguration = protocolConfiguration.providerConfiguration
    else { fatalError("Manager doesn't seem initialized. Can't save advanced settings.") }

    if [.connected, .connecting].contains(manager.connection.status) {
      throw TunnelStoreError.cannotSaveToTunnelWhenConnected
    }

    providerConfiguration = settings.toProviderConfiguration()
    protocolConfiguration.providerConfiguration = providerConfiguration
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

    guard status == .connected
    else {
      self.resources = DisplayableResources()
      return
    }

    let session = castToSession(manager.connection)
    let resourcesQuery = resources.versionStringToData()

    do {
      try session.sendProviderMessage(resourcesQuery) { [weak self] reply in
        if let reply = reply {  // If reply is nil, then the resources have not changed
          if let updatedResources = DisplayableResources(from: reply) {
            self?.resources = updatedResources
          }
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
          named: .NEVPNStatusDidChange,
          object: nil
        ) {
          guard let session = notification.object as? NETunnelProviderSession
          else {
            logger.error("\(#function): NEVPNStatusDidChange notification doesn't seem to be valid")
            return
          }

          status = session.status

          if let startTunnelContinuation = startTunnelContinuation {
            switch status {
            case .connected:
              startTunnelContinuation.resume(returning: ())
              self.startTunnelContinuation = nil
            case .disconnected:
              startTunnelContinuation.resume(throwing: TunnelStoreError.tunnelCouldNotBeStarted)
              self.startTunnelContinuation = nil
            default:
              break
            }
          }

          if let stopTunnelContinuation = stopTunnelContinuation {
            switch status {
            case .disconnected:
              stopTunnelContinuation.resume(returning: ())
              self.stopTunnelContinuation = nil
            case .connected:
              stopTunnelContinuation.resume(throwing: TunnelStoreError.tunnelCouldNotBeStopped)
              self.stopTunnelContinuation = nil
            default:
              break
            }
          }

          // TODO: Why is this needed
          if status != .connected {
            self.resources = DisplayableResources()
          }
        }
      }
    )
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
