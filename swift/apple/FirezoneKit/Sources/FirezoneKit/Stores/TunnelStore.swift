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

final class TunnelStore: ObservableObject {
  private static let logger = Logger.make(for: TunnelStore.self)

  static let shared = TunnelStore()

  @Published private var tunnel: NETunnelProviderManager?
  @Published private(set) var tunnelAuthStatus: TunnelAuthStatus = .tunnelUninitialized

  @Published private(set) var status: NEVPNStatus {
    didSet { TunnelStore.logger.info("status changed: \(self.status.description)") }
  }

  @Published private(set) var resources = DisplayableResources()

  private var resourcesTimer: Timer? {
    didSet(oldValue) { oldValue?.invalidate() }
  }

  private var tunnelObservingTasks: [Task<Void, Never>] = []
  private var startTunnelContinuation: CheckedContinuation<(), Error>?
  private var stopTunnelContinuation: CheckedContinuation<(), Error>?
  private var cancellables = Set<AnyCancellable>()

  init() {
    self.tunnel = nil
    self.tunnelAuthStatus = .tunnelUninitialized
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
        if let protocolConfig = (tunnel.protocolConfiguration as? NETunnelProviderProtocol) {
          Self.logger.log(
            "  serverAddress = \(protocolConfig.serverAddress ?? "")"
          )
          Self.logger.log(
            "  providerConfig = \(protocolConfig.providerConfiguration ?? [:])"
          )
          Self.logger.log(
            "  passwordReference = \(String(describing: protocolConfig.passwordReference))"
          )
        }
        self.tunnel = tunnel
        self.tunnelAuthStatus = tunnel.authStatus()
        self.status = tunnel.connection.status
      } else {
        let tunnel = NETunnelProviderManager()
        tunnel.localizedDescription = "Firezone"
        tunnel.protocolConfiguration = basicProviderProtocol()
        try await tunnel.saveToPreferences()
        Self.logger.log("\(#function): Tunnel created")
        self.tunnel = tunnel
        self.tunnelAuthStatus = .signedOut
      }
      setupTunnelObservers()
      Self.logger.log("\(#function): TunnelStore initialized")
    } catch {
      Self.logger.error("Error (\(#function)): \(error)")
    }
  }

  func saveAuthStatus(_ tunnelAuthStatus: TunnelAuthStatus) async throws {
    Self.logger.log("TunnelStore.\(#function) \(tunnelAuthStatus, privacy: .public)")
    guard let tunnel = tunnel else {
      fatalError("Tunnel not initialized yet")
    }

    let tunnelStatus = tunnel.connection.status
    if tunnelStatus == .connected || tunnelStatus == .connecting {
      throw TunnelStoreError.cannotSaveToTunnelWhenConnected
    }

    try await tunnel.loadFromPreferences()
    try await tunnel.saveAuthStatus(tunnelAuthStatus)
    self.tunnelAuthStatus = tunnelAuthStatus
  }

  func saveAdvancedSettings(_ advancedSettings: AdvancedSettings) async throws {
    Self.logger.log("TunnelStore.\(#function) \(advancedSettings, privacy: .public)")
    guard let tunnel = tunnel else {
      fatalError("Tunnel not initialized yet")
    }

    let tunnelStatus = tunnel.connection.status
    if tunnelStatus == .connected || tunnelStatus == .connecting {
      throw TunnelStoreError.cannotSaveToTunnelWhenConnected
    }

    try await tunnel.loadFromPreferences()
    try await tunnel.saveAdvancedSettings(advancedSettings)
    self.tunnelAuthStatus = tunnel.authStatus()
  }

  func advancedSettings() -> AdvancedSettings? {
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): Tunnel not initialized yet")
      return nil
    }

    return tunnel.advancedSettings()
  }

  func basicProviderProtocol() -> NETunnelProviderProtocol {
    let protocolConfiguration = NETunnelProviderProtocol()
    protocolConfiguration.providerBundleIdentifier = Bundle.main.bundleIdentifier.map {
      "\($0).network-extension"
    }
    protocolConfiguration.serverAddress = AdvancedSettings.defaultValue.apiURLString
    protocolConfiguration.providerConfiguration = [
      TunnelProviderKeys.keyConnlibLogFilter:
        AdvancedSettings.defaultValue.connlibLogFilterString
    ]
    return protocolConfiguration
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

    if tunnel.advancedSettings().connlibLogFilterString.isEmpty {
      tunnel.setConnlibLogFilter(AdvancedSettings.defaultValue.connlibLogFilterString)
    }

    tunnel.isEnabled = true
    try await tunnel.saveToPreferences()
    try await tunnel.loadFromPreferences()

    let session = castToSession(tunnel.connection)
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
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): TunnelStore is not initialized")
      return
    }

    guard self.stopTunnelContinuation == nil else {
      throw TunnelStoreError.stopAlreadyBeingAttempted
    }

    TunnelStore.logger.trace("\(#function)")

    let status = tunnel.connection.status
    if status == .connected || status == .connecting {
      let session = castToSession(tunnel.connection)
      session.stopTunnel()
      try await withCheckedThrowingContinuation { continuation in
        self.stopTunnelContinuation = continuation
      }
    }
  }

  func signOut() async throws -> Keychain.PersistentRef? {
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): TunnelStore is not initialized")
      return nil
    }

    let tunnelStatus = tunnel.connection.status
    if tunnelStatus == .connected || tunnelStatus == .connecting {
      throw TunnelStoreError.cannotSignOutWhenConnected
    }

    if case .signedIn(_, let tokenReference) = self.tunnelAuthStatus {
      do {
        try await saveAuthStatus(.signedOut)
      } catch {
        TunnelStore.logger.trace(
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

  func removeProfile() async throws {
    TunnelStore.logger.trace("\(#function)")
    guard let tunnel = tunnel else {
      Self.logger.log("\(#function): TunnelStore is not initialized")
      return
    }

    try await tunnel.removeFromPreferences()
  }
}

enum TunnelAuthStatus: Equatable, CustomStringConvertible {
  case tunnelUninitialized
  case signedOut
  case signedIn(authBaseURL: URL, tokenReference: Data)

  var isInitialized: Bool {
    switch self {
    case .tunnelUninitialized: return false
    default: return true
    }
  }

  var description: String {
    switch self {
    case .tunnelUninitialized:
      return "tunnel uninitialized"
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

extension NETunnelProviderManager {
  func authStatus() -> TunnelAuthStatus {
    if let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
      let providerConfig = protocolConfiguration.providerConfiguration
    {
      let authBaseURL: URL? = {
        guard let urlString = providerConfig[TunnelProviderKeys.keyAuthBaseURLString] as? String
        else {
          return nil
        }
        return URL(string: urlString)
      }()
      let tokenRef = protocolConfiguration.passwordReference
      if let authBaseURL = authBaseURL {
        if let tokenRef = tokenRef {
          return .signedIn(authBaseURL: authBaseURL, tokenReference: tokenRef)
        } else {
          return .signedOut
        }
      } else {
        return .signedOut
      }
    }
    return .signedOut
  }

  func saveAuthStatus(_ authStatus: TunnelAuthStatus) async throws {
    if let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol {
      var providerConfig: [String: Any] = protocolConfiguration.providerConfiguration ?? [:]

      switch authStatus {
      case .tunnelUninitialized:
        protocolConfiguration.passwordReference = nil
        break
      case .signedOut:
        protocolConfiguration.passwordReference = nil
        break
      case .signedIn(let authBaseURL, let tokenReference):
        providerConfig[TunnelProviderKeys.keyAuthBaseURLString] = authBaseURL.absoluteString
        protocolConfiguration.passwordReference = tokenReference
      }

      protocolConfiguration.providerConfiguration = providerConfig

      ensureTunnelConfigurationIsValid()
      try await saveToPreferences()
    }
  }

  func advancedSettings() -> AdvancedSettings {
    let defaultValue = AdvancedSettings.defaultValue
    if let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol {
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

    return defaultValue
  }

  func setConnlibLogFilter(_ logFiler: String) {
    if let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
      let providerConfiguration = protocolConfiguration.providerConfiguration
    {
      var providerConfig = providerConfiguration
      providerConfig[TunnelProviderKeys.keyConnlibLogFilter] = logFiler
      protocolConfiguration.providerConfiguration = providerConfig
    }
  }

  func saveAdvancedSettings(_ advancedSettings: AdvancedSettings) async throws {
    if let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol {
      var providerConfig: [String: Any] = protocolConfiguration.providerConfiguration ?? [:]

      providerConfig[TunnelProviderKeys.keyAuthBaseURLString] =
        advancedSettings.authBaseURLString
      providerConfig[TunnelProviderKeys.keyConnlibLogFilter] =
        advancedSettings.connlibLogFilterString

      protocolConfiguration.providerConfiguration = providerConfig
      protocolConfiguration.serverAddress = advancedSettings.apiURLString

      ensureTunnelConfigurationIsValid()
      try await saveToPreferences()
    }
  }

  private func ensureTunnelConfigurationIsValid() {
    // Ensure the tunnel config has required values populated, because
    // to even sign out, we need saveToPreferences() to succeed.
    if let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol {
      protocolConfiguration.providerBundleIdentifier = Bundle.main.bundleIdentifier.map {
        "\($0).network-extension"
      }
      if protocolConfiguration.serverAddress?.isEmpty ?? true {
        protocolConfiguration.serverAddress = "unknown-server"
      }
    } else {
      let protocolConfiguration = NETunnelProviderProtocol()
      protocolConfiguration.providerBundleIdentifier = Bundle.main.bundleIdentifier.map {
        "\($0).network-extension"
      }
      protocolConfiguration.serverAddress = "unknown-server"
    }
    if localizedDescription?.isEmpty ?? true {
      localizedDescription = "Firezone"
    }
  }
}
