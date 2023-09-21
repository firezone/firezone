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

  @Published private var tunnel: NETunnelProviderManager?
  @Published private(set) var tunnelAuthStatus: TunnelAuthStatus = TunnelAuthStatus(protocolConfiguration: nil)

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
    self.tunnelAuthStatus = TunnelAuthStatus(protocolConfiguration: nil)
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
        self.tunnelAuthStatus = TunnelAuthStatus(protocolConfiguration: tunnel.protocolConfiguration as? NETunnelProviderProtocol)
      } else {
        let tunnel = NETunnelProviderManager()
        tunnel.localizedDescription = "Firezone"
        tunnel.protocolConfiguration = TunnelAuthStatus.accountNotSetup.toProtocolConfiguration()
        try await tunnel.saveToPreferences()
        Self.logger.log("\(#function): Tunnel created")
        self.tunnel = tunnel
        self.tunnelAuthStatus = .accountNotSetup
      }
      setupTunnelObservers()
      Self.logger.log("\(#function): TunnelStore initialized")
    } catch {
      Self.logger.error("Error (\(#function)): \(error)")
    }
  }

  func setAuthStatus(_ tunnelAuthStatus: TunnelAuthStatus) async throws {
    guard let tunnel = tunnel else {
      fatalError("Tunnel not initialized yet")
    }

    let wasConnected = (tunnel.connection.status == .connected || tunnel.connection.status == .connecting)
    if wasConnected {
      stop()
    }
    tunnel.protocolConfiguration = tunnelAuthStatus.toProtocolConfiguration()
    try await tunnel.saveToPreferences()
    self.tunnelAuthStatus = tunnelAuthStatus
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

    let session = tunnel.connection as! NETunnelProviderSession
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
    let session = tunnel.connection as! NETunnelProviderSession
    session.stopTunnel()
  }

  func stopAndSignOut() async throws -> Keychain.PersistentRef? {
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): TunnelStore is not initialized")
      return nil
    }

    TunnelStore.logger.trace("\(#function)")
    let session = tunnel.connection as! NETunnelProviderSession
    session.stopTunnel()

    if case .signedIn(let authBaseURL, let accountId, let tokenReference) = self.tunnelAuthStatus {
      try await setAuthStatus(.signedOut(authBaseURL: authBaseURL, accountId: accountId))
      return tokenReference
    }

    return nil
  }

  func beginUpdatingResources() {
    self.updateResources()
    let timer = Timer(timeInterval: 1 /*second*/, repeats: true) { [weak self] _ in
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

  private func updateResources() {
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): TunnelStore is not initialized")
      return
    }

    let session = tunnel.connection as! NETunnelProviderSession
    guard session.status == .connected else {
      self.resources = DisplayableResources()
      return
    }
    let resourcesQuery = resources.versionStringToData()
    do {
      try session.sendProviderMessage(resourcesQuery) { [weak self] reply in
        if let reply = reply { // If reply is nil, then the resources have not changed
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

    tunnelObservingTasks.forEach { $0.cancel() }
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

enum TunnelAuthStatus {
  case tunnelUninitialized
  case accountNotSetup
  case signedOut(authBaseURL: URL, accountId: String)
  case signedIn(authBaseURL: URL, accountId: String, tokenReference: Data)

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
        guard let urlString = providerConfig?[TunnelStore.keyAuthBaseURLString] as? String else { return nil }
        return URL(string: urlString)
      }()
      let accountId = providerConfig?[TunnelStore.keyAccountId] as? String
      let tokenRef = protocolConfiguration.passwordReference
      if let authBaseURL = authBaseURL, let accountId = accountId {
        if let tokenRef = tokenRef {
          self = .signedIn(authBaseURL: authBaseURL, accountId: accountId, tokenReference: tokenRef)
        } else {
          self = .signedOut(authBaseURL: authBaseURL, accountId: accountId)
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
    protocolConfiguration.serverAddress = Self.getControlPlaneURLFromInfoPlist().absoluteString

    switch self {
      case .tunnelUninitialized, .accountNotSetup:
        break
      case .signedOut(let authBaseURL, let accountId):
        protocolConfiguration.providerConfiguration = [
          TunnelStore.keyAuthBaseURLString: authBaseURL.absoluteString,
          TunnelStore.keyAccountId: accountId
        ]
      case .signedIn(let authBaseURL, let accountId, let tokenReference):
        protocolConfiguration.providerConfiguration = [
          TunnelStore.keyAuthBaseURLString: authBaseURL.absoluteString,
          TunnelStore.keyAccountId: accountId
        ]
        protocolConfiguration.passwordReference = tokenReference
    }

    return protocolConfiguration
  }

  func accountId() -> String? {
    switch self {
      case .tunnelUninitialized, .accountNotSetup:
        return nil
      case .signedOut(_, let accountId):
        return accountId
      case .signedIn(_, let accountId, _):
        return accountId
    }
  }

  static func getControlPlaneURLFromInfoPlist() -> URL {
    let infoPlistDictionary = Bundle.main.infoDictionary
    guard let urlScheme = (infoPlistDictionary?["ControlPlaneURLScheme"] as? String), !urlScheme.isEmpty else {
      fatalError("AuthURLScheme missing in Info.plist. Please define AUTH_URL_SCHEME, AUTH_URL_HOST, CONTROL_PLANE_URL_SCHEME, and CONTROL_PLANE_URL_HOST in Server.xcconfig.")
    }
    guard let urlHost = (infoPlistDictionary?["ControlPlaneURLHost"] as? String), !urlHost.isEmpty else {
      fatalError("AuthURLHost missing in Info.plist. Please define AUTH_URL_SCHEME, AUTH_URL_HOST, CONTROL_PLANE_URL_SCHEME, and CONTROL_PLANE_URL_HOST in Server.xcconfig.")
    }
    let urlString = "\(urlScheme)://\(urlHost)/"
    guard let url = URL(string: urlString) else {
      fatalError("Cannot form valid URL from string: \(urlString)")
    }
    return url
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
