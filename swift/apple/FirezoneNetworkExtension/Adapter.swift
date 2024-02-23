//  Adapter.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//
import FirezoneKit
import Foundation
import NetworkExtension
import OSLog

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
  private var networkSettings: NetworkSettings

  /// Packet tunnel provider.
  private weak var packetTunnelProvider: PacketTunnelProvider?

  /// Network routes monitor.
  private var networkMonitor: NWPathMonitor?

  /// Private queue used to synchronize access to `WireGuardAdapter` members.
  private let workQueue = DispatchQueue(label: "FirezoneAdapterWorkQueue")

  /// Adapter state.
  private var state: AdapterState {
    didSet {
      logger.log("Adapter state changed to: \(self.state)")
    }
  }

  /// Keep track of resources
  private var displayableResources = DisplayableResources()

  /// Starting parameters
  private var controlPlaneURLString: String
  private var token: String

  private let logFilter: String
  private let connlibLogFolderPath: String

  init(
    controlPlaneURLString: String,
    token: String,
    logFilter: String,
    packetTunnelProvider: PacketTunnelProvider
  ) {
    self.controlPlaneURLString = controlPlaneURLString
    self.token = token
    self.packetTunnelProvider = packetTunnelProvider
    self.callbackHandler = CallbackHandler(logger: packetTunnelProvider.logger)
    self.state = .stoppedTunnel
    self.logFilter = logFilter
    self.connlibLogFolderPath = SharedAccess.connlibLogFolderURL?.path ?? ""
    self.logger = packetTunnelProvider.logger
    self.networkSettings = NetworkSettings(
      packetTunnelProvider: packetTunnelProvider, logger: packetTunnelProvider.logger)
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
        self.state = .startingTunnel(
          session: try WrappedSession.connect(
            self.controlPlaneURLString,
            self.token,
            DeviceMetadata.getOrCreateFirezoneId(logger: self.logger),
            DeviceMetadata.getDeviceName(),
            DeviceMetadata.getOSVersion(),
            self.connlibLogFolderPath,
            self.logFilter,
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
        self.logger.error("\(#function): Unexpected state")
        break
      case .tunnelReady(let session):
        self.logger.log("\(#function): Shutting down connlib")
        session.disconnect()
        self.state = .stoppedTunnel
      case .startingTunnel(let session, let onStarted):
        self.logger.log("\(#function): Shutting down connlib before tunnel ready")
        session.disconnect()
        onStarted?(nil)
        self.state = .stoppedTunnel
      }

      completionHandler()

      self.networkMonitor?.cancel()
      self.networkMonitor = nil
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

// MARK: Responding to path updates

extension Adapter {
  private func beginPathMonitoring() {
    self.logger.log("Beginning path monitoring")
    let networkMonitor = NWPathMonitor(prohibitedInterfaceTypes: [.loopback])
    networkMonitor.pathUpdateHandler = { [weak self] path in
      self?.didReceivePathUpdate(path: path)
    }
    networkMonitor.start(queue: self.workQueue)
  }

  // Connlib already handles network changes gracefully using timeouts.
  // This is simply for updating the icon and tunnel status visible to the user.
  private func didReceivePathUpdate(path: Network.NWPath) {
    // Will be invoked in the workQueue by the path monitor
    if path.status == .unsatisfied {
      self.logger.log("\(#function): Detected network change. Temporarily offline.")
      self.packetTunnelProvider?.reasserting = true
    } else {
      self.logger.log(
        "\(#function): Detected network change. Now online.")
      self.packetTunnelProvider?.reasserting = false
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
      case .startingTunnel(let session, let onStarted):
        networkSettings.tunnelAddressIPv4 = tunnelAddressIPv4
        networkSettings.tunnelAddressIPv6 = tunnelAddressIPv6
        networkSettings.dnsAddresses = dnsAddresses
        // Add DNS sentinels to routes as a start
        networkSettings.routes4 = dnsAddresses.reduce([]) {
          $0
            + (IPv4Address($1) != nil
              ? [NEIPv4Route(destinationAddress: $1, subnetMask: "255.255.255.0")] : [])
        }
        networkSettings.routes6 = dnsAddresses.reduce([]) {
          $0
            + (IPv6Address($1) != nil
              ? [NEIPv6Route(destinationAddress: $1, networkPrefixLength: 128)] : [])
        }

        networkSettings.apply {
          self.state = .tunnelReady(session: session)
          onStarted?(nil)
          self.beginPathMonitoring()
        }
      case .tunnelReady:
        networkSettings.tunnelAddressIPv4 = tunnelAddressIPv4
        networkSettings.tunnelAddressIPv6 = tunnelAddressIPv6
        networkSettings.dnsAddresses = dnsAddresses
        networkSettings.apply()
      case .stoppedTunnel:
        self.logger.error(
          "\(#function): Unexpected state: \(self.state)")
      }
    }
  }

  public func onUpdateRoutes(routeList4: String, routeList6: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onUpdateRoutes")

      let routes4 = try! JSONDecoder().decode([String].self, from: routeList4.data(using: .utf8)!)
      let routes6 = try! JSONDecoder().decode([String].self, from: routeList6.data(using: .utf8)!)

      networkSettings.routes4 = NetworkSettings.parseRoutes4(routes4: routes4)
      networkSettings.routes6 = NetworkSettings.parseRoutes6(routes6: routes6)

      networkSettings.apply()
    }
  }

  public func onUpdateResources(resourceList: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onUpdateResources")

      let networkResources = try! JSONDecoder().decode(
        [NetworkResource].self, from: resourceList.data(using: .utf8)!)

      // Update resource list
      self.displayableResources.update(resources: networkResources.map { $0.displayableResource })
    }
  }

  public func onDisconnect(error: String?) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("\(#function)")

      // Unexpected disconnect initiated by connlib. Typically for 401s.
      if let error = error {
        self.logger.error(
          "Connlib disconnected with unrecoverable error: \(error)")
        self.packetTunnelProvider?.handleTunnelShutdown(
          dueTo: .connlibDisconnected,
          errorMessage: error)
        self.packetTunnelProvider?.cancelTunnelWithError(
          AdapterError.connlibFatalError(error))
      }
    }
  }

  public func getSystemDefaultResolvers() -> String {
    #if os(macOS)
      let resolvers = SystemConfigurationResolvers(logger: self.logger).getDefaultDNSServers()
    #elseif os(iOS)
      let resolvers = resetToSystemDNSGettingBindResolvers()
    #endif

    logger.log("\(#function): \(resolvers)")

    return try! String(
      decoding: JSONEncoder().encode(resolvers),
      as: UTF8.self
    )
  }
}

// MARK: Getting System Resolvers on iOS
#if os(iOS)
  extension Adapter {
    // When the tunnel is up, we can only get the system's default resolvers
    // by reading /etc/resolv.conf when matchDomains is set to a non-empty string.
    // If matchDomains is an empty string, /etc/resolv.conf will contain connlib's
    // sentinel, which isn't helpful to us.
    private func resetToSystemDNSGettingBindResolvers() -> [String] {
      logger.log("\(#function): Getting system default resolvers from Bind")

      switch self.state {
      case .startingTunnel:
        return BindResolvers().getservers().map(BindResolvers.getnameinfo)
      case .tunnelReady:
        var resolvers: [String] = []

        // async / await can't be used here because this is an FFI callback
        let semaphore = DispatchSemaphore(value: 0)

        // Set tunnel's matchDomains to a dummy string that will never match any name
        networkSettings.matchDomains = ["firezone-fd0020211111"]

        // Call apply to populate /etc/resolv.conf with the system's default resolvers
        networkSettings.apply {
          // Only now can we get the system resolvers
          resolvers = BindResolvers().getservers().map(BindResolvers.getnameinfo)

          // Restore connlib's DNS resolvers
          self.networkSettings.matchDomains = [""]
          self.networkSettings.apply { semaphore.signal() }
          semaphore.wait()
        }

        return resolvers
      case .stoppedTunnel:
        logger.error("\(#function): Unexpected state")
        return []
      }
    }
  }
#endif
