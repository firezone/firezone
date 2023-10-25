//
//  TunnelStore.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import NetworkExtension
import OSLog

enum TunnelStoreError: Error {
  case tunnelCouldNotBeStarted
}

final class TunnelStore: ObservableObject {
  private static let logger = Logger.make(for: TunnelStore.self)

  static let shared = TunnelStore()

  static let keyAuthBaseURLString = "authBaseURLString"
  static let keyAccountId = "accountId"
  static let keyApiURLString = "apiURLString"
  static let keyLogFilter = "logFilter"

  @Published private var tunnel: NETunnelProviderManager?
  @Published private(set) var tunnelState: TunnelState = TunnelState(
    protocolConfiguration: nil)

  @Published private(set) var status: NEVPNStatus {
    didSet { TunnelStore.logger.info("status changed: \(self.status.description)") }
  }

  @Published private(set) var resources = DisplayableResources()

  private var resourcesTimer: Timer? {
    didSet(oldValue) { oldValue?.invalidate() }
  }

  private var tunnelObservingTasks: [Task<Void, Never>] = []
  private var startTunnelContinuation: CheckedContinuation<(), Error>?
  private var cancellables = Set<AnyCancellable>()

  init() {
    self.tunnel = nil
    self.tunnelState = TunnelState(protocolConfiguration: nil)
    self.status = .invalid

    Task {
      await initializeTunnel()
    }
  }

  func initializeTunnel() async {
    do {
      let managers = try await NETunnelProviderManager.loadAllFromPreferences()
      Self.logger.log("\(#function): \(managers.count) tunnel managers found")
      if let tunnel = managers.first {
        Self.logger.log("\(#function): Tunnel already exists")
        self.tunnel = tunnel
        self.tunnelState = TunnelState(
          protocolConfiguration: tunnel.protocolConfiguration as? NETunnelProviderProtocol)
      } else {
        let tunnel = NETunnelProviderManager()
        tunnel.localizedDescription = "Firezone"
        tunnel.protocolConfiguration = TunnelState.accountNotSetup.toProtocolConfiguration()
        try await tunnel.saveToPreferences()
        Self.logger.log("\(#function): Tunnel created")
        self.tunnel = tunnel
        self.tunnelState = .accountNotSetup
      }
      setupTunnelObservers()
      Self.logger.log("\(#function): TunnelStore initialized")
    } catch {
      Self.logger.error("Error (\(#function)): \(error)")
    }
  }

  func setState(_ tunnelState: TunnelState) async throws {
    guard let tunnel = tunnel else {
      fatalError("Tunnel not initialized yet")
    }

    let wasConnected =
      (tunnel.connection.status == .connected || tunnel.connection.status == .connecting)
    if wasConnected {
      stop()
    }
    tunnel.protocolConfiguration = tunnelState.toProtocolConfiguration()
    try await tunnel.saveToPreferences()
    self.tunnelState = tunnelState
  }

  func start() async throws {
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): TunnelStore is not initialized")
      return
    }

    TunnelStore.logger.trace("\(#function)")

    if tunnel.connection.status == .connected || tunnel.connection.status == .connecting {
      return
    }

    tunnel.isEnabled = true
    try await tunnel.saveToPreferences()
    try await tunnel.loadFromPreferences()

    let session = castToSession(tunnel.connection)
    try session.startTunnel()
    try await withCheckedThrowingContinuation { continuation in
      self.startTunnelContinuation = continuation
    }
  }

  func stop() {
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): TunnelStore is not initialized")
      return
    }

    TunnelStore.logger.trace("\(#function)")
    let session = castToSession(tunnel.connection)
    session.stopTunnel()
  }

  func stopAndSignOut() async throws -> Keychain.PersistentRef? {
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): TunnelStore is not initialized")
      return nil
    }

    TunnelStore.logger.trace("\(#function)")
    let session = castToSession(tunnel.connection)
    session.stopTunnel()

    if case .signedIn(
      let authBaseURL, let accountId, let apiURL, let logFilter, let tokenReference) = self
      .tunnelState
    {
      try await setState(
        .signedOut(
          authBaseURL: authBaseURL, accountId: accountId, apiURL: apiURL, logFilter: logFilter))
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
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): TunnelStore is not initialized")
      return
    }

    let session = castToSession(tunnel.connection)
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
      TunnelStore.logger.error("Error: sendProviderMessage: \(error)")
    }
  }

  private static func makeManager() -> NETunnelProviderManager {
    logger.trace("\(#function)")

    let manager = NETunnelProviderManager()
    manager.localizedDescription = "Firezone"

    return manager
  }

  private func setupTunnelObservers() {
    TunnelStore.logger.trace("\(#function)")

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
          if status != .connected {
            self.resources = DisplayableResources()
          }
        }
      }
    )
  }

  func removeProfile() async throws {
    TunnelStore.logger.trace("\(#function)")
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): TunnelStore is not initialized")
      return
    }

    try await tunnel.removeFromPreferences()
  }
}

enum TunnelState {
  case tunnelUninitialized
  case accountNotSetup
  case signedOut(authBaseURL: URL, accountId: String, apiURL: URL, logFilter: String)
  case signedIn(
    authBaseURL: URL, accountId: String, apiURL: URL, logFilter: String, tokenReference: Data)

  var isInitialized: Bool {
    switch self {
    case .tunnelUninitialized: return false
    default: return true
    }
  }

  init(protocolConfiguration: NETunnelProviderProtocol?) {
    if let protocolConfiguration = protocolConfiguration {
      let providerConfig = protocolConfiguration.providerConfiguration
      let authBaseURL: URL? = {
        guard let urlString = providerConfig?[TunnelStore.keyAuthBaseURLString] as? String else {
          return nil
        }
        return URL(string: urlString)
      }()
      let accountId = providerConfig?[TunnelStore.keyAccountId] as? String
      let apiURL: URL? = {
        guard let urlString = providerConfig?[TunnelStore.keyApiURLString] as? String else {
          return nil
        }
        return URL(string: urlString)
      }()
      let logFilter = providerConfig?[TunnelStore.keyLogFilter] as? String
      let tokenRef = protocolConfiguration.passwordReference
      if let authBaseURL = authBaseURL, let accountId = accountId, let apiURL = apiURL,
        let logFilter = logFilter
      {
        if let tokenRef = tokenRef {
          self = .signedIn(
            authBaseURL: authBaseURL, accountId: accountId, apiURL: apiURL, logFilter: logFilter,
            tokenReference: tokenRef)
        } else {
          self = .signedOut(
            authBaseURL: authBaseURL, accountId: accountId, apiURL: apiURL, logFilter: logFilter)
        }
      } else {
        self = .accountNotSetup
      }
    } else {
      self = .tunnelUninitialized
    }
  }

  func toProtocolConfiguration() -> NETunnelProviderProtocol {
    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.providerBundleIdentifier = Bundle.main.bundleIdentifier.map {
      "\($0).network-extension"
    }
    protocolConfiguration.serverAddress = apiURL().absoluteString

    switch self {
    case .tunnelUninitialized, .accountNotSetup:
      break
    case .signedOut(let authBaseURL, let accountId, let apiURL, let logFilter):
      protocolConfiguration.providerConfiguration = [
        TunnelStore.keyAuthBaseURLString: authBaseURL.absoluteString,
        TunnelStore.keyAccountId: accountId,
        TunnelStore.keyApiURLString: apiURL.absoluteString,
        TunnelStore.keyLogFilter: logFilter,
      ]
    case .signedIn(let authBaseURL, let accountId, let apiURL, let logFilter, let tokenReference):
      protocolConfiguration.providerConfiguration = [
        TunnelStore.keyAuthBaseURLString: authBaseURL.absoluteString,
        TunnelStore.keyAccountId: accountId,
        TunnelStore.keyApiURLString: apiURL.absoluteString,
        TunnelStore.keyLogFilter: logFilter,
      ]
      protocolConfiguration.passwordReference = tokenReference
    }

    return protocolConfiguration
  }

  func authBaseURL() -> URL {
    switch self {
    case .tunnelUninitialized, .accountNotSetup:
      return Settings().authBaseURL
    case .signedOut(let authBaseURL, _, _, _):
      return authBaseURL
    case .signedIn(let authBaseURL, _, _, _, _):
      return authBaseURL
    }
  }

  func accountId() -> String {
    switch self {
    case .tunnelUninitialized, .accountNotSetup:
      return Settings().accountId
    case .signedOut(_, let accountId, _, _):
      return accountId
    case .signedIn(_, let accountId, _, _, _):
      return accountId
    }
  }

  func apiURL() -> URL {
    switch self {
    case .tunnelUninitialized, .accountNotSetup:
      return Settings().apiURL
    case .signedOut(_, _, let apiURL, _):
      return apiURL
    case .signedIn(_, _, let apiURL, _, _):
      return apiURL
    }
  }

  func logFilter() -> String {
    switch self {
    case .tunnelUninitialized, .accountNotSetup:
      return Settings().logFilter
    case .signedOut(_, _, _, let logFilter):
      return logFilter
    case .signedIn(_, _, _, let logFilter, _):
      return logFilter
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
