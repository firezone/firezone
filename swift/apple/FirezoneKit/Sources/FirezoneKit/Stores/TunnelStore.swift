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

public struct TunnelProviderKeys {
  static let keyAuthBaseURLString = "authBaseURLString"
  public static let keyConnlibLogFilter = "connlibLogFilter"
}

public final class TunnelStore: ObservableObject {
  @Published private var manager: NETunnelProviderManager?
  @Published private(set) var tunnelAuthStatus: TunnelAuthStatus?

  @Published private(set) var status: NEVPNStatus {
    didSet { self.logger.log("status changed: \(self.status.description)") }
  }

  @Published private(set) var resources = DisplayableResources()

  private var resourcesTimer: Timer? {
    didSet(oldValue) { oldValue?.invalidate() }
  }

  private var protocolConfiguration: NETunnelProviderProtocol
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
    self.protocolConfiguration = NETunnelProviderProtocol()
    self.manager = nil
    self.tunnelAuthStatus = .noManagerFound

    Task {
      // loadAllFromPreferences() returns list of tunnel configurations we created. Since our bundle ID
      // can change (by us), find the one that's current and ignore the others.
      let managers = try! await NETunnelProviderManager.loadAllFromPreferences()
      logger.log("\(#function): \(managers.count) tunnel managers found")
      for manager in managers {
        if let protocolConfiguration = (manager.protocolConfiguration as? NETunnelProviderProtocol),
           protocolConfiguration.providerBundleIdentifier == bundleIdentifier {
          self.protocolConfiguration = protocolConfiguration
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
      if let urlString = protocolConfiguration.providerConfiguration?[TunnelProviderKeys.keyAuthBaseURLString] as? String {
        return URL(string: urlString)
      }
      return nil
    }()

    if let authBaseURL = authBaseURL,
    let tokenRef = protocolConfiguration.passwordReference {
      return .signedIn(authBaseURL: authBaseURL, tokenReference: tokenRef)
    } else {
      return .signedOut
    }
  }

  func saveAuthStatus(_ authStatus: TunnelAuthStatus) async throws {
    var providerConfig: [String: Any] = protocolConfiguration.providerConfiguration ?? [:]

    switch authStatus {
    case .noManagerFound:
      return

    case .signedOut:
      protocolConfiguration.passwordReference = nil
      break
    case .signedIn(let authBaseURL, let tokenReference):
      providerConfig[TunnelProviderKeys.keyAuthBaseURLString] = authBaseURL.absoluteString
      protocolConfiguration.passwordReference = tokenReference
    }

    protocolConfiguration.providerConfiguration = providerConfig
    sanitizeProtocolConfiguration()
    try await manager?.saveToPreferences()
  }

  func sanitizeProtocolConfiguration() {
    protocolConfiguration.serverAddress = advancedSettings().apiURLString
    protocolConfiguration.providerBundleIdentifier = bundleIdentifier
    manager?.localizedDescription = bundleDescription
  }

  func createManager() async throws {
    guard self.manager == nil else {
      return
    }
    let manager = NETunnelProviderManager()
    manager.localizedDescription = bundleDescription
    manager.protocolConfiguration = basicProviderProtocol()
    try await manager.saveToPreferences()
    logger.log("\(#function): Manager created")
    self.manager = manager
    self.tunnelAuthStatus = authStatus()
  }

  func saveAdvancedSettings(_ advancedSettings: AdvancedSettings) async throws {
    logger.log("TunnelStore.\(#function) \(advancedSettings)")
    guard let manager = manager else {
      fatalError("No manager yet. Can't save advanced settings.")
    }

    if [.connected, .connecting].contains(manager.connection.status) {
      throw TunnelStoreError.cannotSaveToTunnelWhenConnected
    }

    try await manager.loadFromPreferences()
    protocolConfiguration.providerConfiguration?[TunnelProviderKeys.keyAuthBaseURLString] =
      advancedSettings.authBaseURLString
    protocolConfiguration.providerConfiguration?[TunnelProviderKeys.keyConnlibLogFilter] =
      advancedSettings.connlibLogFilterString
    sanitizeProtocolConfiguration()
    try await manager.saveToPreferences()

    self.tunnelAuthStatus = authStatus()
  }

  private func basicProviderProtocol() -> NETunnelProviderProtocol {
    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.providerBundleIdentifier = bundleIdentifier
    protocolConfiguration.serverAddress = AdvancedSettings.defaultValue.apiURLString
    protocolConfiguration.providerConfiguration = [
      TunnelProviderKeys.keyConnlibLogFilter:
        AdvancedSettings.defaultValue.connlibLogFilterString
    ]
    return protocolConfiguration
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

    if advancedSettings().connlibLogFilterString.isEmpty {
      setConnlibLogFilter(AdvancedSettings.defaultValue.connlibLogFilterString)
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

  func advancedSettings() -> AdvancedSettings {
    let defaultValue = AdvancedSettings.defaultValue
    let apiURLString = protocolConfiguration.serverAddress ?? defaultValue.apiURLString
    var authBaseURLString = defaultValue.authBaseURLString
    var logFilter = defaultValue.connlibLogFilterString
    if let providerConfig = protocolConfiguration.providerConfiguration {
      if let authBaseURLStringInProviderConfig =
        (providerConfig[TunnelProviderKeys.keyAuthBaseURLString] as? String)
      {
        authBaseURLString = authBaseURLStringInProviderConfig
      }
      if let logFilterInProviderConfig =
        (providerConfig[TunnelProviderKeys.keyConnlibLogFilter] as? String)
      {
        logFilter = logFilterInProviderConfig
      }
    }

    return AdvancedSettings(
      authBaseURLString: authBaseURLString,
      apiURLString: apiURLString,
      connlibLogFilterString: logFilter
    )
  }

  private func setConnlibLogFilter(_ logFiler: String) {
      protocolConfiguration.providerConfiguration?[TunnelProviderKeys.keyConnlibLogFilter] = logFiler
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
