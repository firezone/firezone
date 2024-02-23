//  Adapter.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//
import FirezoneKit
import Foundation
import NetworkExtension
import OSLog

#if os(iOS)
  import UIKit.UIDevice
#endif

public enum AdapterError: Error {
  /// Failure to perform an operation in such state.
  case invalidState

  /// connlib failed to start
  case connlibConnectError(Error)

  /// connlib fatal error
  case connlibFatalError(String)

  /// No network settings were provided
  case noNetworkSettings

  /// Failure to set network settings.
  case setNetworkSettings(Error)

  /// stop() called before the tunnel became ready
  case stoppedByRequestWhileStarting
}

/// Enum representing internal state of the  adapter
private enum AdapterState: CustomStringConvertible {
  case startingTunnel(session: WrappedSession, onStarted: Adapter.StartTunnelCompletionHandler?)
  case tunnelReady(session: WrappedSession)
  case stoppedTunnel

  var description: String {
    switch self {
    case .startingTunnel: return "startingTunnel"
    case .tunnelReady: return "tunnelReady"
    case .stoppedTunnel: return "stoppedTunnel"
    }
  }
}

// Loosely inspired from WireGuardAdapter from WireGuardKit
class Adapter {

  typealias StartTunnelCompletionHandler = ((AdapterError?) -> Void)
  typealias StopTunnelCompletionHandler = (() -> Void)

  private let logger: AppLogger

  private var callbackHandler: CallbackHandler

  /// Network settings
  private var networkSettings: NetworkSettings?

  /// Packet tunnel provider.
  private weak var packetTunnelProvider: PacketTunnelProvider

  /// Network routes monitor.
  private var networkMonitor: NWPathMonitor?

  /// Control when we receive path updates
  private var temporarilyDisablePathMonitor = false

  /// Private queue used to synchronize access to `WireGuardAdapter` members.
  private let workQueue = DispatchQueue(label: "FirezoneAdapterWorkQueue")

  /// Adapter state.
  private var state: AdapterState {
    didSet {
      logger.log("Adapter state changed to: \(self.state)")
    }
  }

  // Keep track of system's default DNS servers
  private var systemDefaultResolvers: [String] = []

  /// Keep track of resources
  private var displayableResources = DisplayableResources()

  /// Starting parameters
  private var controlPlaneURLString: String
  private var token: String

  private let logFilter: String
  private let connlibLogFolderPath: String

  init(
    controlPlaneURLString: String, token: String,
    logFilter: String, packetTunnelProvider: PacketTunnelProvider
  ) {
    self.controlPlaneURLString = controlPlaneURLString
    self.token = token
    self.packetTunnelProvider = packetTunnelProvider
    self.callbackHandler = CallbackHandler(logger: packetTunnelProvider.logger)
    self.state = .stoppedTunnel
    self.logFilter = logFilter
    self.connlibLogFolderPath = SharedAccess.connlibLogFolderURL?.path ?? ""
    self.logger = packetTunnelProvider.logger
  }

  deinit {
    self.logger.log("Adapter.deinit")

    // Cancel network monitor
    networkMonitor?.cancel()

    // Shutdown the tunnel
    switch self.state {
    case .tunnelReady(let session):
      logger.log("Adapter.deinit: Shutting down connlib")
      session.disconnect()
    case .startingTunnel(let session, let onStarted):
      logger.log("Adapter.deinit: Shutting down connlib")
      session.disconnect()
      onStarted?(nil)
    case .stoppedTunnel:
      logger.log("Adapter.deinit: Already stopped")
    // Perfect!
    }
  }

  /// Start the tunnel.
  /// - Parameters:
  ///   - completionHandler: completion handler.
  public func start(completionHandler: @escaping (AdapterError?) -> Void) throws {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.start")
      guard case .stoppedTunnel = self.state else {
        packetTunnelProvider?.handleTunnelShutdown(
          dueTo: .invalidAdapterState,
          errorMessage: "Adapter is in invalid state")
        completionHandler(.invalidState)
        return
      }

      self.callbackHandler.delegate = self

      if self.connlibLogFolderPath.isEmpty {
        self.logger.error("Cannot get shared log folder for connlib")
      }

      self.logger.log("Adapter.start: Starting connlib")
      do {

        self.systemDefaultResolvers = Resolv().getservers().map(Resolv.getnameinfo)
        let dnsServers = try! String(
          decoding: JSONEncoder().encode(self.systemDefaultResolvers),
          as: UTF8.self
        )
        self.state = .startingTunnel(
          session: try WrappedSession.connect(
            self.controlPlaneURLString,
            self.token,
            DeviceMetadata.getOrCreateFirezoneId(logger: self.logger),
            DeviceMetadata.getDeviceName(),
            DeviceMetadata.getOSVersion(),
            self.connlibLogFolderPath,
            self.logFilter,
            dnsServers,
            self.callbackHandler
          ),
          onStarted: completionHandler
        )
      } catch let error {
        self.logger.error("Adapter.start: Error: \(error)")
        packetTunnelProvider?.handleTunnelShutdown(
          dueTo: .connlibConnectFailure,
          errorMessage: error.localizedDescription)
        self.state = .stoppedTunnel
        completionHandler(AdapterError.connlibConnectError(error))
      }
    }
  }

  /// Stop the tunnel
  public func stop(reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    workQueue.async { [weak self] in
      guard let self = self else { return }
      self.logger.log("Adapter.stop")

      packetTunnelProvider?.handleTunnelShutdown(
        dueTo: .stopped(reason),
        errorMessage: "\(reason)")

      switch self.state {
      case .stoppedTunnel:
        break
      case .tunnelReady(let session):
        self.logger.log("Adapter.stop: Shutting down connlib")
        session.disconnect()
      case .startingTunnel(let session, let onStarted):
        self.logger.log("Adapter.stop: Shutting down connlib before tunnel ready")
        session.disconnect()
        onStarted?(nil)
      }
    }
  }

  /// Get the current set of resources in the completionHandler.
  /// If unchanged since referenceVersionString, call completionHandler(nil).
  public func getDisplayableResourcesIfVersionDifferentFrom(
    referenceVersionString: String, completionHandler: @escaping (DisplayableResources?) -> Void
  ) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      if referenceVersionString == self.displayableResources.versionString {
        completionHandler(nil)
      } else {
        completionHandler(self.displayableResources)
      }
    }
  }
}

// MARK: Device metadata

extension Adapter {

}

// MARK: Responding to path updates

extension Adapter {
  private func maybeUpdateSessionWithNewResolvers(session: WrappedSession, completion: () -> Void) {
    let resolvers = Resolv().getservers().map(Resolv.getnameinfo)
    if resolvers != systemDefaultResolvers {
      self.systemDefaultResolvers = resolvers
      session.update(
        try! String(
          decoding: JSONEncoder().encode(self.systemDefaultResolvers),
          as: UTF8.self
        ))
      // session.update will call onTunnelReady where we unpause path monitoring
    } else {
      // Revert back to connlib right away
      completion()
    }
  }

  private func updateTunnelDNS(session: WrappedSession) {
    // Setting this to anything but an empty string will populate /etc/resolv.conf with
    // the default interface's DNS servers, which we read later from connlib
    // during tunnel setup.
    self.networkSettings?.setMatchDomains(["firezone-fd0020211111"])

    // Apply the changes, so that /etc/resolv.conf will be populated with the system's
    // default resolvers
    applyNetworkSettings(
      beforeHandler: { self.pausePathMonitoring() },
      completionHandler: { error in
        if let error = error {
          self.logger.error("\(#function): Error: \(error)")
        } else {
          self.maybeUpdateSessionWithNewResolvers(
            session: session,
            completion: {
              self.networkSettings?.setMatchDomains([""])
              self.applyNetworkSettings(
                beforeHandler: nil,
                completionHandler: { _ in self.resumePathMonitoring() }
              )
            })
        }
      })
  }

  private func applyNetworkSettings(
    beforeHandler: (() -> Void)?, completionHandler: ((Error?) -> Void)?
  ) {
    self.networkSettings?.apply(
      on: self.packetTunnelProvider,
      beforeHandler: beforeHandler,
      logger: self.logger,
      completionHandler: completionHandler
    )
  }

  private func resumePathMonitoring() {
    self.logger.log("\(#function): Resuming path monitoring at \(Date.now)")
    self.temporarilyDisablePathMonitor = false
  }

  private func pausePathMonitoring() {
    self.logger.log("\(#function): Pausing path monitoring at \(Date.now)")
    self.temporarilyDisablePathMonitor = true
  }

  private func beginPathMonitoring() {
    self.logger.log("Beginning path monitoring")
    let networkMonitor = NWPathMonitor(prohibitedInterfaceTypes: [.loopback])
    networkMonitor.pathUpdateHandler = { [weak self] path in
      self?.didReceivePathUpdate(path: path)
    }
    networkMonitor.start(queue: self.workQueue)
  }

  private func didReceivePathUpdate(path: Network.NWPath) {
    // Will be invoked in the workQueue by the path monitor
    if self.temporarilyDisablePathMonitor {
      self.logger.log("\(#function): Ignoring path update while responding to a previous path update.")
    } else {
      switch self.state {
      case .tunnelReady(let session):
        if path.status == .unsatisfied {
          self.logger.log("\(#function): Detected network change. Temporarily offline.")
          self.packetTunnelProvider?.reasserting = true
        } else {
          self.logger.log("\(#function): Detected network change. Now online. Potentially updating tunnel DNS.")
          self.packetTunnelProvider?.reasserting = false
          updateTunnelDNS(session: session)
        }

      case .startingTunnel:
        self.logger.log("\(#function): Ignoring path updates while starting tunnel.")

      case .stoppedTunnel:
        self.logger.error("\(#function): Unexpected state: \(self.state)")
      }
    }
  }
}

// MARK: Implementing CallbackHandlerDelegate

extension Adapter: CallbackHandlerDelegate {
  public func onSetInterfaceConfig(
    tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddresses: [String]
  ) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onSetInterfaceConfig")

      switch self.state {
      case .startingTunnel:
        self.networkSettings = NetworkSettings(
          tunnelAddressIPv4: tunnelAddressIPv4, tunnelAddressIPv6: tunnelAddressIPv6,
          dnsAddresses: dnsAddresses)
      case .tunnelReady:
        self.applyNetworkSettings(beforeHandler: { self.pausePathMonitoring() }, completionHandler: { _ in self.resumePathMonitoring() })
      case .stoppedTunnel:
        self.logger.error(
          "Adapter.onTunnelReady: Unexpected state: \(self.state)")
      }
    }
  }

  public func onAddRoute(_ route: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onAddRoute(\(route))")
      guard let networkSettings = self.networkSettings else {
        self.logger.error("Adapter.onAddRoute: No network settings")
        return
      }

      networkSettings.addRoute(route)
      if case .tunnelReady = self.state {
        applyNetworkSettings(
          beforeHandler: { self.pausePathMonitoring() },
          completionHandler: { _ in
            self.logger.log("\(#function): Enabling path monitor")
            self.temporarilyDisablePathMonitor = false
          }
        )
      }
    }
  }

  public func onRemoveRoute(_ route: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onRemoveRoute(\(route))")
      guard let networkSettings = self.networkSettings else {
        self.logger.error("Adapter.onRemoveRoute: No network settings")
        return
      }
      networkSettings.removeRoute(route)
      if case .tunnelReady = self.state {
        applyNetworkSettings(
          beforeHandler: { self.pausePathMonitoring() },
          completionHandler: { _ in
            self.logger.log("\(#function): Enabling path monitor")
            self.temporarilyDisablePathMonitor = false
          }
        )
      }
    }
  }

  public func onUpdateResources(resourceList: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onUpdateResources")
      let jsonString = resourceList
      guard let jsonData = jsonString.data(using: .utf8) else {
        return
      }
      guard let networkResources = try? JSONDecoder().decode([NetworkResource].self, from: jsonData)
      else {
        return
      }

      // Update resource list
      self.displayableResources.update(resources: networkResources.map { $0.displayableResource })
    }
  }

  public func onDisconnect() {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.networkMonitor!.cancel()
      self.networkMonitor = nil
  }

  public func onDisconnect(error: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onDisconnect: \(error)")

      self.networkMonitor!.cancel()
      self.networkMonitor = nil

      self.logger.error(
        "Connlib disconnected with unrecoverable error: \(error)")
      packetTunnelProvider.handleTunnelShutdown(
        dueTo: .connlibDisconnected,
        errorMessage: error)
      self.packetTunnelProvider.cancelTunnelWithError(
        AdapterError.connlibFatalError(error))
      self.state = .stoppedTunnel

      self.logger.log("Connlib disconnected")
      self.state = .stoppedTunnel
    }
  }

  public func getSystemDefaultResolvers() -> RustString {
    return try! String(
      decoding: JSONEncoder().encode(self.systemDefaultResolvers),
      as: UTF8.self
    ).intoRustString()
  }
}
