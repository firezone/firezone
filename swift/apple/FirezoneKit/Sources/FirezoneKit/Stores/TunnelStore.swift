//
//  TunnelStore.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import NetworkExtension
import OSLog

// TODO: Can this file be removed since we're managing the tunnel in connlib?

final class TunnelStore: ObservableObject {
  private static let logger = Logger.make(for: TunnelStore.self)

  var tunnel: NETunnelProviderManager {
    didSet { setupTunnelObservers() }
  }

  @Published private(set) var status: NEVPNStatus = .invalid {
    didSet { TunnelStore.logger.info("status changed: \(self.status.description)") }
  }

  @Published private(set) var isEnabled = false {
    didSet { TunnelStore.logger.info("isEnabled changed: \(self.isEnabled.description)") }
  }

  @Published private(set) var resources = DisplayableResources()

  private var resourcesTimer: Timer? {
    didSet(oldValue) { oldValue?.invalidate() }
  }

  private var tunnelObservingTasks: [Task<Void, Never>] = []

  init(tunnel: NETunnelProviderManager) {
    self.tunnel = tunnel
    tunnel.isEnabled = true
    setupTunnelObservers()
  }

  static func loadOrCreate() async throws -> NETunnelProviderManager {
    logger.trace("\(#function)")

    let managers = try await NETunnelProviderManager.loadAllFromPreferences()

    if let tunnel = managers.first {
      return tunnel
    }

    let tunnel = makeManager()
    try await tunnel.saveToPreferences()
    try await tunnel.loadFromPreferences()

    return tunnel
  }

  func start(authResponse: AuthResponse) async throws {
    TunnelStore.logger.trace("\(#function)")

    // make sure we have latest preferences before starting
    try await tunnel.loadFromPreferences()

    tunnel.protocolConfiguration = Self.makeProtocolConfiguration(authResponse: authResponse)
    tunnel.isEnabled = true
    try await tunnel.saveToPreferences()

    let session = tunnel.connection as! NETunnelProviderSession
    try session.startTunnel()
  }

  func stop() {
    TunnelStore.logger.trace("\(#function)")
    let session = tunnel.connection as! NETunnelProviderSession
    session.stopTunnel()
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
    let session = tunnel.connection as! NETunnelProviderSession
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

    let proto = makeProtocolConfiguration()
    manager.protocolConfiguration = proto
    manager.isEnabled = true

    return manager
  }

  private static func makeProtocolConfiguration(authResponse: AuthResponse? = nil) -> NETunnelProviderProtocol {
    let proto = NETunnelProviderProtocol()

    proto.providerBundleIdentifier = Bundle.main.bundleIdentifier.map {
      "\($0).network-extension"
    }
    if let authResponse = authResponse {
      proto.providerConfiguration = [
        // TODO: We should really be storing the portalURL as "authURL" and "controlPlaneURL" explicitly
        // instead of making the assumption the portalURL base is the control plane URL
        "portalURL": authResponse.portalURL.baseURL?.absoluteString,
        "token": authResponse.token
      ]
    }
    proto.serverAddress = "Firezone addresses"
    return proto
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
          guard let session = notification.object as? NETunnelProviderSession,
                let tunnelProvider = session.manager as? NETunnelProviderManager
          else {
            return
          }
          self.status = tunnelProvider.connection.status
        }
      }
    )
  }

  func removeProfile() async throws {
    TunnelStore.logger.trace("\(#function)")

    try await tunnel.removeFromPreferences()
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
    case .connecting: return "Connecting"
    case .disconnecting: return "Disconnecting"
    case .reasserting: return "Reconnecting"
    @unknown default: return "Unknown"
    }
  }
}
