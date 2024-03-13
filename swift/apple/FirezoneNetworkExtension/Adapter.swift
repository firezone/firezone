//  Adapter.swift
//  (c) 2024 Firezone, Inc.
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
}

/// Enum representing internal state of the  adapter
private enum AdapterState: CustomStringConvertible {
  case tunnelStarted(session: WrappedSession)
  case tunnelStopped

  var description: String {
    switch self {
    case .tunnelStarted: return "tunnelStarted"
    case .tunnelStopped: return "tunnelStopped"
    }
  }
}

// Loosely inspired from WireGuardAdapter from WireGuardKit
class Adapter {

  typealias StartTunnelCompletionHandler = ((AdapterError?) -> Void)

  private let logger: AppLogger

  private var callbackHandler: CallbackHandler

  /// Network settings
  private var networkSettings: NetworkSettings?

  /// Packet tunnel provider.
  private weak var packetTunnelProvider: PacketTunnelProvider?

  /// Network routes monitor.
  private var networkMonitor: NWPathMonitor?

  /// Used to avoid path update callback cycles on iOS
  #if os(iOS)
    private var gateways: [Network.NWEndpoint] = []
  #endif

  /// Track our last fetched DNS resolvers to know whether to tell connlib they've updated
  private var lastFetchedResolvers: [String] = []

  /// Used to avoid needlessly sending reconnects to connlib
  private var primaryInterfaceName: String?

  /// Private queue used to ensure consistent ordering among path update and connlib callbacks
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
  private var apiURL: String
  private var token: String

  private let logFilter: String
  private let connlibLogFolderPath: String

  init(
    apiURL: String,
    token: String,
    logFilter: String,
    packetTunnelProvider: PacketTunnelProvider
  ) {
    self.apiURL = apiURL
    self.token = token
    self.packetTunnelProvider = packetTunnelProvider
    self.callbackHandler = CallbackHandler(logger: packetTunnelProvider.logger)
    self.state = .tunnelStopped
    self.logFilter = logFilter
    self.connlibLogFolderPath = SharedAccess.connlibLogFolderURL?.path ?? ""
    self.logger = packetTunnelProvider.logger
    self.networkSettings = nil
  }

  // Could happen abruptly if the process is killed.
  deinit {
    logger.log("Adapter.deinit")
    
    // Cancel network monitor
    networkMonitor?.cancel()

    // Shutdown the tunnel
    if case .tunnelStarted(let session) = self.state {
      logger.log("Adapter.deinit: Shutting down connlib")
      session.disconnect()
    }
  }

  /// Start the tunnel.
  /// - Parameters:
  ///   - completionHandler: completion handler.
  public func start(completionHandler: @escaping (AdapterError?) -> Void) throws {
    logger.log("Adapter.start")
    guard case .tunnelStopped = self.state else {
      logger.error("\(#function): Invalid Adapter state")
      completionHandler(.invalidState)
      return
    }

    callbackHandler.delegate = self

    if connlibLogFolderPath.isEmpty {
      logger.error("Cannot get shared log folder for connlib")
    }

    self.logger.log("Adapter.start: Starting connlib")
    do {
      let session =
        try WrappedSession.connect(
          apiURL,
          token,
          DeviceMetadata.getOrCreateFirezoneId(logger: self.logger),
          DeviceMetadata.getDeviceName(),
          DeviceMetadata.getOSVersion(),
          connlibLogFolderPath,
          logFilter,
          callbackHandler
        )
      self.state = .tunnelStarted(session: session)
      beginPathMonitoring()
      completionHandler(nil)
    } catch let error {
      logger.error("\(#function): Adapter.start: Error: \(error)")
      state = .tunnelStopped
      completionHandler(AdapterError.connlibConnectError(error))
    }
  }

  /// Final callback called by packetTunnelProvider when tunnel is to be stopped.
  /// Can happen due to:
  ///  - User toggles VPN off in Settings.app
  ///  - User signs out
  ///  - User clicks "Disconnect and Quit" (macOS)
  ///  - connlib sends onDisconnect
  ///
  ///  This can happen before the tunnel is in the tunnelReady state, such as if the portal
  ///  is slow to send the init.
  public func stop() {
    logger.log("Adapter.stop")

    if case .tunnelStarted(let session) = state {
      state = .tunnelStopped

      // user-initiated, tell connlib to shut down
      session.disconnect()
    }

    networkMonitor?.cancel()
    networkMonitor = nil
  }

  /// Get the current set of resources in the completionHandler.
  /// If unchanged since referenceVersionString, call completionHandler(nil).
  public func getDisplayableResourcesIfVersionDifferentFrom(
    referenceVersionString: String, completionHandler: @escaping (DisplayableResources?) -> Void
  ) {
    workQueue.async { [weak self] in
      guard let self = self else { return }
      
      if referenceVersionString == displayableResources.versionString {
        completionHandler(nil)
      } else {
        completionHandler(displayableResources)
      }
    }
  }
}

// MARK: Responding to path updates

extension Adapter {
  private func beginPathMonitoring() {
    self.logger.log("Beginning path monitoring")
    let networkMonitor = NWPathMonitor()
    networkMonitor.pathUpdateHandler = { [weak self] path in
      self?.didReceivePathUpdate(path: path)
    }
    networkMonitor.start(queue: self.workQueue)
  }

  /// Primary callback we receive whenever:
  /// - Network connectivity changes
  /// - System DNS servers change, including when we set them
  /// - Routes change, including when we set them
  ///
  /// Apple doesn't give us very much info in this callback, so we don't know which of the
  /// events above triggered the callback.
  ///
  /// On iOS this creates a problem:
  ///
  /// We have no good way to get the System's default resolvers. We use a workaround which
  /// involves reading the resolvers from Bind (i.e. /etc/resolv.conf) but this will be set to connlib's
  /// DNS sentinel while the tunnel is active, which isn't helpful to us. To get around this, we can
  /// very briefly update the Tunnel's matchDomains config to *not* be the catch-all [""], which
  /// causes iOS to write the actual system resolvers into /etc/resolv.conf, which we can then read.
  /// The issue is that this in itself causes a didReceivePathUpdate callback, which makes it hard to
  /// differentiate between us changing the DNS configuration and the system actually receiving new
  /// default resolvers.
  ///
  /// So we solve this problem by only doing this DNS dance if the gateways available to the path have
  /// changed. This means we only call setDns when the physical network has changed, and therefore
  /// we're blind to path updates where only the DNS resolvers have changed. That will happen in two
  /// cases most commonly:
  /// - New DNS servers were set by DHCP
  /// - The user manually changed the DNS servers in the system settings
  ///
  /// For now, this will break DNS if the old servers connlib is using are no longer valid, and
  /// can only be fixed with a sign out and sign back in which restarts the NetworkExtension.
  ///
  /// On macOS, Apple has exposed the SystemConfiguration framework which makes this easy and
  /// doesn't suffer from this issue.
  ///
  /// See the following issues for discussion around the above issue:
  /// - https://github.com/firezone/firezone/issues/3302
  /// - https://github.com/firezone/firezone/issues/3343
  /// - https://github.com/firezone/firezone/issues/3235
  /// - https://github.com/firezone/firezone/issues/3175
  private func didReceivePathUpdate(path: Network.NWPath) {
    guard case .tunnelStarted(let session) = state else { return }

    if path.status == .unsatisfied {
      logger.log("\(#function): Detected network change: Offline.")

      // Check if we need to set reasserting, avoids OS log spam and potentially other side effects
      if packetTunnelProvider?.reasserting == false {
        // Tell the UI we're not connected
        packetTunnelProvider?.reasserting = true
      }
    } else {
      self.logger.log("\(#function): Detected network change: Online.")

      // Hint to connlib we're back online, but only do so if our primary interface changes,
      // and therefore we need to bump sockets. On darwin, this is needed to send packets
      // out of a different interface even when 0.0.0.0 is used as the source.
      // If our primary interface changes, we can be certain the old socket shouldn't be
      // used anymore.
      if (path.availableInterfaces.first?.name != primaryInterfaceName) {
        session.reconnect()
        primaryInterfaceName = path.availableInterfaces.first?.name
      }

      if shouldFetchSystemResolvers(path: path) {
        // Spawn a new thread to avoid blocking the UI on iOS
        Task {
          let resolvers = getSystemDefaultResolvers(interfaceName: path.availableInterfaces.first?.name)

          if lastFetchedResolvers != resolvers {
            session.setDns(
              try! String(
                decoding: JSONEncoder().encode(resolvers),
                as: UTF8.self
              ).intoRustString()
            )

            lastFetchedResolvers = resolvers
          }
        }
      }

      if packetTunnelProvider?.reasserting == true {
        packetTunnelProvider?.reasserting = false
      }
    }
  }

  #if os(iOS)
    private func shouldFetchSystemResolvers(path: Network.NWPath) -> Bool {
      if path.gateways != gateways {
        gateways = path.gateways
        return true
      }

      return false
    }
  #else
    private func shouldFetchSystemResolvers(path _: Network.NWPath) -> Bool {
      return true
    }
  #endif
}

// MARK: Implementing CallbackHandlerDelegate

extension Adapter: CallbackHandlerDelegate {
  public func onSetInterfaceConfig(
    tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddresses: [String]
  ) {
    workQueue.async { [weak self] in
      guard let self = self else { return }
      if networkSettings == nil {
        // First time receiving this callback
        networkSettings = NetworkSettings(packetTunnelProvider: packetTunnelProvider, logger: logger)
      }

      logger.log(
        "\(#function): \(tunnelAddressIPv4) \(tunnelAddressIPv6) \(dnsAddresses)")

      switch state {
      case .tunnelStarted(session: _):
        guard let networkSettings = networkSettings else { return }
        networkSettings.tunnelAddressIPv4 = tunnelAddressIPv4
        networkSettings.tunnelAddressIPv6 = tunnelAddressIPv6
        networkSettings.dnsAddresses = dnsAddresses
        networkSettings.apply()
      case .tunnelStopped:
        logger.error(
          "\(#function): Unexpected state: \(self.state)")
      }
    }
  }

  public func onUpdateRoutes(routeList4: String, routeList6: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }
      guard let networkSettings = networkSettings
      else {
        fatalError("onUpdateRoutes called before network settings was initialized!")
      }

      logger.log("\(#function): \(routeList4) \(routeList6)")

      networkSettings.routes4 = try! JSONDecoder().decode(
        [NetworkSettings.Cidr].self, from: routeList4.data(using: .utf8)!
      ).compactMap { $0.asNEIPv4Route }
      networkSettings.routes6 = try! JSONDecoder().decode(
        [NetworkSettings.Cidr].self, from: routeList6.data(using: .utf8)!
      ).compactMap { $0.asNEIPv6Route }

      networkSettings.apply()
    }
  }

  public func onUpdateResources(resourceList: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      logger.log("\(#function)")

      let networkResources = try! JSONDecoder().decode(
        [NetworkResource].self, from: resourceList.data(using: .utf8)!)

      // Update resource list
      displayableResources.update(resources: networkResources.map { $0.displayableResource })
    }
  }

  public func onDisconnect(error: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }
      logger.log("\(#function)")

      var reason: NEProviderStopReason = .connectionFailed

      // connlib-initiated; session is already disconnected, move directly to .tunnelStopped
      // provider will call our stop() at the end.
      state = .tunnelStopped

      // HACK: Define more connlib error types across the FFI so we can switch on them
      // directly and not just sign the user out every time this is called.
      if error.contains("401 Unauthorized") {
        reason = .authenticationCanceled
      }

      self.packetTunnelProvider?.stopTunnel(with: reason) {}
    }
  }

  private func getSystemDefaultResolvers(interfaceName: String? = nil) -> [String] {
    #if os(macOS)
      let resolvers = SystemConfigurationResolvers(logger: logger).getDefaultDNSServers(
        interfaceName: interfaceName)
    #elseif os(iOS)
      let resolvers =
        if case .tunnelStarted = state {
          resetToSystemDNSGettingBindResolvers()
        } else {
          // NetworkSettings isn't applied yet, so we can grab them directly
          BindResolvers().getservers().map(BindResolvers.getnameinfo)
        }
    #endif

    logger.log("\(#function): \(resolvers)")

    return resolvers
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
      guard let networkSettings = networkSettings
      else {
        // Network Settings hasn't been applied yet, so our sentinal isn't
        // the system's resolver and we can grab it directly.
        // If we try to continue below without valid tunnel addresses assigned
        // to the interface, we'll crash.
        return BindResolvers().getservers().map(BindResolvers.getnameinfo)
      }

      var resolvers: [String] = []
      let semaphore = DispatchSemaphore(value: 0)

      // Set tunnel's matchDomains to a dummy string that will never match any name
      networkSettings.matchDomains = ["firezone-fd0020211111"]

      // Call apply to populate /etc/resolv.conf with the system's default resolvers
      networkSettings.apply {
        guard let networkSettings = self.networkSettings else { return }
        // Only now can we get the system resolvers
        resolvers = BindResolvers().getservers().map(BindResolvers.getnameinfo)

        // Restore connlib's DNS resolvers
        networkSettings.matchDomains = [""]
        networkSettings.apply { semaphore.signal() }
      }

      semaphore.wait()
      return resolvers
    }
  }
#endif
