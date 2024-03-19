//
//  TunnelStore.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
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
  @Published private var manager: NETunnelProviderManager?
  @Published private(set) var tunnelAuthStatus: TunnelAuthStatus?

  // Make our tunnel configuration convenient for SettingsView to consume
  @Published private(set) var settings: Settings

  @Published private(set) var status: NEVPNStatus {
    didSet { self.logger.log("status changed: \(self.status.description)") }
  }

  @Published private(set) var resources = DisplayableResources()

  private var resourcesTimer: Timer? {
    didSet(oldValue) { oldValue?.invalidate() }
  }

  private var protocolConfiguration: NETunnelProviderProtocol?
  private let logger: AppLogger
  private var tunnelObservingTasks: [Task<Void, Never>] = []
  private var startTunnelContinuation: CheckedContinuation<(), Error>?
  private var stopTunnelContinuation: CheckedContinuation<(), Error>?
  private var cancellables = Set<AnyCancellable>()

  #if DEBUG
    private let bundleIdentifier = Bundle.main.bundleIdentifier.map { "\($0).debug.network-extension" }
    private let bundleDescription = "Firezone (Debug)"
  #else
    private let bundleIdentifier = Bundle.main.bundleIdentifier.map { "\($0).network-extension" }
    private let bundleDescription = "Firezone"
  #endif

  public init(logger: AppLogger) {
    self.logger = logger
    self.status = .invalid
    self.manager = nil
    self.tunnelAuthStatus = .noManagerFound
    self.settings = Settings.defaultValue

    Task {
      // loadAllFromPreferences() returns list of tunnel configurations we created. Since our bundle ID
      // can change (by us), find the one that's current and ignore the others.
      let managers = try! await NETunnelProviderManager.loadAllFromPreferences()
      logger.log("\(#function): \(managers.count) tunnel managers found")
      for manager in managers {
        if let protocolConfiguration = (manager.protocolConfiguration as? NETunnelProviderProtocol),
           protocolConfiguration.providerBundleIdentifier == bundleIdentifier {
          self.protocolConfiguration = protocolConfiguration
          self.settings = Settings.fromProviderConfiguration(providerConfiguration: protocolConfiguration.providerConfiguration as? [String: String])
          self.manager = manager
          self.tunnelAuthStatus = authStatus()
          self.status = manager.connection.status

          // Stop looking for our tunnel
          break
        }
      }

      setupTunnelObservers()
    }
  }

  private func authStatus() -> TunnelAuthStatus {
    let authBaseURL: URL? = {
      if let urlString = protocolConfiguration?.providerConfiguration?[TunnelStoreKeys.authBaseURL] as? String {
        return URL(string: urlString)
      }
      return nil
    }()

    if let authBaseURL = authBaseURL,
    let tokenRef = protocolConfiguration!.passwordReference {
      return .signedIn(authBaseURL: authBaseURL, tokenReference: tokenRef)
    } else {
      return .signedOut
    }
  }

  func saveAuthStatus(_ authStatus: TunnelAuthStatus) async throws {
    guard let protocolConfiguration = protocolConfiguration else { return }
    var providerConfig = protocolConfiguration.providerConfiguration as! [String: String]

    switch authStatus {
    case .noManagerFound:
      return

    case .signedOut:
      protocolConfiguration.passwordReference = nil
      break
    case .signedIn(let authBaseURL, let tokenReference):
      providerConfig[TunnelStoreKeys.authBaseURL] = authBaseURL.absoluteString
      protocolConfiguration.passwordReference = tokenReference
    }

    protocolConfiguration.providerConfiguration = providerConfig
    try await manager?.saveToPreferences()
  }

  // Initialize and save a new VPN profile in system Preferences
  func createManager() async throws {
    guard manager == nil else {
      fatalError("Manager unexpectedly exists already.")
    }

    let protocolConfiguration = NETunnelProviderProtocol()
    let manager = NETunnelProviderManager()
    let providerConfiguration = protocolConfiguration.providerConfiguration as! [String: String]

    protocolConfiguration.providerConfiguration = providerConfiguration
    protocolConfiguration.providerBundleIdentifier = bundleIdentifier
    protocolConfiguration.serverAddress = Settings.defaultValue.apiURL
    manager.localizedDescription = bundleDescription
    manager.protocolConfiguration = protocolConfiguration

    // Save the new VPN profile to System Preferences
    try await manager.saveToPreferences()

    self.manager = manager
    self.tunnelAuthStatus = .signedOut
  }

  func start() async throws {
    guard let manager = manager else {
      logger.log("\(#function): No manager created yet")
      return
    }

    logger.log("\(#function)")

    if [.connected, .connecting].contains(manager.connection.status) {
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
    guard let manager = manager else {
      logger.log("\(#function): No manager created yet")
      return
    }

    guard self.stopTunnelContinuation == nil else {
      throw TunnelStoreError.stopAlreadyBeingAttempted
    }

    logger.log("\(#function)")

    if [.connected, .connecting].contains(manager.connection.status) {
      let session = castToSession(manager.connection)
      session.stopTunnel()
      try await withCheckedThrowingContinuation { continuation in
        self.stopTunnelContinuation = continuation
      }
    }
  }

  func signOut() async throws -> Keychain.PersistentRef? {
    guard let manager = manager else {
      logger.log("\(#function): No manager created yet")
      return nil
    }

    if [.connected, .connecting].contains(manager.connection.status) {
      throw TunnelStoreError.cannotSignOutWhenConnected
    }

    if case .signedIn(_, let tokenReference) = self.tunnelAuthStatus {
      do {
        try await saveAuthStatus(.signedOut)
      } catch {
        logger.log(
          "\(#function): Error saving signed out auth status: \(error)"
        )
      }
      return tokenReference
    }

    return nil
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
          let protocolConfiguration = protocolConfiguration,
          var providerConfiguration = protocolConfiguration.providerConfiguration else {
      fatalError("Manager doesn't seem initialized. Can't save advanced settings.")
    }

    if [.connected, .connecting].contains(manager.connection.status) {
      throw TunnelStoreError.cannotSaveToTunnelWhenConnected
    }

    providerConfiguration = settings.toProviderConfiguration()
    protocolConfiguration.providerConfiguration = providerConfiguration
    try await manager.saveToPreferences()
    self.settings = settings
    self.manager = manager
    self.tunnelAuthStatus = authStatus()
  }

  private func castToSession(_ connection: NEVPNConnection) -> NETunnelProviderSession {
    guard let session = connection as? NETunnelProviderSession else {
      fatalError("Could not cast tunnel connection to NETunnelProviderSession!")
    }
    return session
  }

  private func updateResources() {
    guard let manager = manager else {
      logger.log("\(#function): No tunnel created yet")
      return
    }

    let session = castToSession(manager.connection)
    guard session.status == .connected else {
      self.resources = DisplayableResources()
      return
    }
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
          guard let session = notification.object as? NETunnelProviderSession else {
            return
          }
          let status = session.status
          self.status = status
          if let startTunnelContinuation = self.startTunnelContinuation {
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
          if let stopTunnelContinuation = self.stopTunnelContinuation {
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
          if status != .connected {
            self.resources = DisplayableResources()
          }
        }
      }
    )
  }
}

enum TunnelAuthStatus: Equatable, CustomStringConvertible {
  case noManagerFound
  case signedOut
  case signedIn(authBaseURL: URL, tokenReference: Data)

  var description: String {
    switch self {

    case .noManagerFound:
      return "no manager found"
    case .signedOut:
      return "signedOut"
    case .signedIn(let authBaseURL, _):
      return "signedIn(authBaseURL: \(authBaseURL))"
    }
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
