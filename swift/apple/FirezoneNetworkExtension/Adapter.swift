import CryptoKit
//  Adapter.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
import FirezoneKit
import Foundation
import NetworkExtension
import OSLog

enum AdapterError: Error {
  /// Failure to perform an operation in such state.
  case invalidState(AdapterState)

  /// connlib failed to start
  case connlibConnectError(String)

  var localizedDescription: String {
    switch self {
    case .invalidState(let state):
      return "Adapter is in an invalid state: \(state)"
    case .connlibConnectError(let error):
      return "connlib failed to start: \(error)"
    }
  }
}

/// Enum representing internal state of the  adapter
enum AdapterState: CustomStringConvertible {
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

  /// Remembers the last _relevant_ path update.
  /// A path update is considered relevant if certain properties change that require us to reset connlib's network state.
  private var lastRelevantPath: Network.NWPath?

  /// Private queue used to ensure consistent ordering among path update and connlib callbacks
  /// This is the primary async primitive used in this class.
  private let workQueue = DispatchQueue(label: "FirezoneAdapterWorkQueue")

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
  private lazy var pathUpdateHandler: (Network.NWPath) -> Void = { [weak self] path in
    guard let self else { return }

    // Ignore path updates if we're not started. Prevents responding to path updates
    // we may receive when shutting down.
    guard case .tunnelStarted(let session) = self.state else { return }

    if path.status == .unsatisfied {
      // Check if we need to set reasserting, avoids OS log spam and potentially other side effects
      if self.packetTunnelProvider?.reasserting == false {
        // Tell the UI we're not connected
        self.packetTunnelProvider?.reasserting = true
      }
    } else {
      // Tell connlib to reset network state, but only do so if our connectivity has
      // meaningfully changed. On darwin, this is needed to send packets
      // out of a different interface even when 0.0.0.0 is used as the source.
      // If our primary interface changes, we can be certain the old socket shouldn't be
      // used anymore.
      if lastRelevantPath?.connectivityDifferentFrom(path: path) != false {
        lastRelevantPath = path
        session.reset()
      }

      if shouldFetchSystemResolvers(path: path) {
        let resolvers = getSystemDefaultResolvers(
          interfaceName: path.availableInterfaces.first?.name)

        if self.lastFetchedResolvers != resolvers,
           let jsonResolvers = try? String(
            decoding: JSONEncoder().encode(resolvers), as: UTF8.self
           ).intoRustString()
        {

          // Update connlib DNS
          session.setDns(jsonResolvers)

          // Update our state tracker
          self.lastFetchedResolvers = resolvers
        }
      }

      if self.packetTunnelProvider?.reasserting == true {
        self.packetTunnelProvider?.reasserting = false
      }
    }
  }

  /// Currently disabled resources
  private var internetResourceEnabled: Bool = false

  /// Cache of internet resource
  private var internetResource: Resource?

  /// Adapter state.
  private var state: AdapterState {
    didSet {
      Log.log("Adapter state changed to: \(self.state)")
    }
  }

  /// Keep track of resources
  private var resourceListJSON: String?

  /// Starting parameters
  private let apiURL: String
  private let token: Token
  private let id: String
  private let logFilter: String
  private let connlibLogFolderPath: String

  init(
    apiURL: String,
    token: Token,
    id: String,
    logFilter: String,
    internetResourceEnabled: Bool,
    packetTunnelProvider: PacketTunnelProvider
  ) {
    self.apiURL = apiURL
    self.token = token
    self.id = id
    self.packetTunnelProvider = packetTunnelProvider
    self.callbackHandler = CallbackHandler()
    self.state = .tunnelStopped
    self.logFilter = logFilter
    self.connlibLogFolderPath = SharedAccess.connlibLogFolderURL?.path ?? ""
    self.networkSettings = nil
    self.internetResourceEnabled = internetResourceEnabled
  }

  // Could happen abruptly if the process is killed.
  deinit {
    Log.log("Adapter.deinit")

    // Cancel network monitor
    networkMonitor?.cancel()

    // Shutdown the tunnel
    if case .tunnelStarted(let session) = self.state {
      Log.log("Adapter.deinit: Shutting down connlib")
      session.disconnect()
    }
  }

  /// Start the tunnel.
  public func start() throws {
    Log.log("Adapter.start")
    guard case .tunnelStopped = self.state else {
      throw AdapterError.invalidState(self.state)
    }

    callbackHandler.delegate = self

    Log.log("Adapter.start: Starting connlib")
    do {
      let jsonEncoder = JSONEncoder()
      jsonEncoder.keyEncodingStrategy = .convertToSnakeCase

      // Grab a session pointer
      let session =
        try WrappedSession.connect(
          apiURL,
          "\(token)",
          "\(id)",
          "\(Telemetry.accountSlug!)",
          DeviceMetadata.getDeviceName(),
          DeviceMetadata.getOSVersion(),
          connlibLogFolderPath,
          logFilter,
          callbackHandler,
          String(data: jsonEncoder.encode(DeviceMetadata.deviceInfo()), encoding: .utf8)!
        )

      // Start listening for network change events. The first few will be our
      // tunnel interface coming up, but that's ok -- it will trigger a `set_dns`
      // connlib.
      beginPathMonitoring()

      // Update state in case everything succeeded
      self.state = .tunnelStarted(session: session)
    } catch let error {
      let msg = error as! RustString
      // `toString` needed to deep copy the string and avoid a possible dangling pointer
      throw AdapterError.connlibConnectError(msg.toString())
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
    Log.log("Adapter.stop")

    if case .tunnelStarted(let session) = state {
      state = .tunnelStopped

      // user-initiated, tell connlib to shut down
      session.disconnect()
    }

    networkMonitor?.cancel()
    networkMonitor = nil
  }

  /// Get the current set of resources in the completionHandler, only returning
  /// them if the resource list has changed.
  public func getResourcesIfVersionDifferentFrom(
    hash: Data, completionHandler: @escaping (String?) -> Void
  ) {
    // This is async to avoid blocking the main UI thread
    workQueue.async { [weak self] in
      guard let self = self else { return }
      guard case .tunnelStarted(let _session) = self.state
      else {
        Log.debug("\(#function): Invalid state \(self.state)")
        return
      }

      if hash == Data(SHA256.hash(data: Data((resourceListJSON ?? "").utf8))) {
        // nothing changed
        completionHandler(nil)
      } else {
        completionHandler(resourceListJSON)
      }
    }
  }

  func resources() -> [Resource] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let resourceList = resourceListJSON else { return [] }
    return (try? decoder.decode([Resource].self, from: resourceList.data(using: .utf8)!)) ?? []
  }

  public func setInternetResourceEnabled(_ enabled: Bool) {
    workQueue.async { [weak self] in
      guard let self = self else { return }
      guard case .tunnelStarted(let _session) = self.state
      else {
        Log.debug("\(#function): Invalid state \(self.state)")
        return
      }

      self.internetResourceEnabled = enabled
      self.resourcesUpdated()
    }
  }

  public func resourcesUpdated() {
    guard case .tunnelStarted(let session) = self.state else { return }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    internetResource = resources().filter{ $0.isInternetResource() }.first

    var disablingResources: Set<String> = []
    if let internetResource = internetResource, !internetResourceEnabled {
      disablingResources.insert(internetResource.id)
    }


    let currentlyDisabled = try! JSONEncoder().encode(disablingResources)
    session.setDisabledResources(String(data: currentlyDisabled, encoding: .utf8)!)
  }
}

// MARK: Responding to path updates

extension Adapter {
  
  private func beginPathMonitoring() {
    Log.log("Beginning path monitoring")
    let networkMonitor = NWPathMonitor()
    networkMonitor.pathUpdateHandler = self.pathUpdateHandler
    networkMonitor.start(queue: self.workQueue)
  }

  private func didReceivePathUpdate(path: Network.NWPath) {

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
    tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddresses: [String], routeListv4: String, routeListv6: String
  ) {
    // This is a queued callback to ensure ordering
    workQueue.async { [weak self] in
      guard let self = self else { return }
      guard case .tunnelStarted(let _session) = self.state
      else {
        Log.debug("\(#function): Invalid state \(self.state)")
        return
      }

      let networkSettings = self.networkSettings
      ?? NetworkSettings(packetTunnelProvider: packetTunnelProvider)

      Log.log(
        "\(#function): \(tunnelAddressIPv4) \(tunnelAddressIPv6) \(dnsAddresses) \(routeListv4) \(routeListv6)")

      networkSettings.tunnelAddressIPv4 = tunnelAddressIPv4
      networkSettings.tunnelAddressIPv6 = tunnelAddressIPv6
      networkSettings.dnsAddresses = dnsAddresses
      networkSettings.routes4 = try! JSONDecoder().decode(
      [NetworkSettings.Cidr].self, from: routeListv4.data(using: .utf8)!
      ).compactMap { $0.asNEIPv4Route }
      networkSettings.routes6 = try! JSONDecoder().decode(
      [NetworkSettings.Cidr].self, from: routeListv6.data(using: .utf8)!
      ).compactMap { $0.asNEIPv6Route }

      networkSettings.apply()
    }
  }

  public func onUpdateResources(resourceList: String) {
    // This is a queued callback to ensure ordering
    workQueue.async { [weak self] in
      guard let self = self else { return }
      guard case .tunnelStarted(let _session) = self.state
      else {
        Log.debug("Tried to call \(#function) while state is \(self.state)")
        return
      }

      Log.log("\(#function)")

      // Update resource List. We don't care what's inside.
      resourceListJSON = resourceList

      self.resourcesUpdated()
    }
  }

  public func onDisconnect(error: String) {
    // Since connlib has already shutdown by this point, we queue this callback
    // to ensure that we can clean up even if connlib exits before we are done.
    workQueue.async { [weak self] in
      guard let self = self else { return }
      guard case .tunnelStarted(let _session) = self.state
      else {
        Log.debug("\(#function): Invalid state \(self.state)")
        return
      }
      Log.log("\(#function)")

      // Set a default stop reason. In the future, we may have more to act upon in
      // different ways.
      var reason: NEProviderStopReason = .connectionFailed

      // connlib-initiated -- session is already disconnected, move directly to .tunnelStopped
      // provider will call our stop() at the end.
      state = .tunnelStopped

      // HACK: Define more connlib error types across the FFI so we can switch on them
      // directly and not parse error strings here.
      if error.contains("401 Unauthorized") {
        reason = .authenticationCanceled
      }

      // Start the process of telling the system to shut us down
      self.packetTunnelProvider?.stopTunnel(with: reason) {}
    }
  }

  private func getSystemDefaultResolvers(interfaceName: String?) -> [String] {
    #if os(macOS)
      let resolvers = SystemConfigurationResolvers().getDefaultDNSServers(
        interfaceName: interfaceName)
    #elseif os(iOS)
      let resolvers = resetToSystemDNSGettingBindResolvers()
    #endif

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
        // Network Settings hasn't been applied yet, so our sentinel isn't
        // the system's resolver and we can grab the system resolvers directly.
        // If we try to continue below without valid tunnel addresses assigned
        // to the interface, we'll crash.
        return BindResolvers().getservers().map(BindResolvers.getnameinfo)
      }

      var resolvers: [String] = []

      // The caller is in an async context, so it's ok to block this thread here.
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

extension Network.NWPath {
  func connectivityDifferentFrom(path: Network.NWPath) -> Bool {
    // We define a path as different from another if the following properties change
    return path.supportsIPv4 != self.supportsIPv4 ||
      path.supportsIPv6 != self.supportsIPv6 ||
      path.availableInterfaces.first?.name != self.availableInterfaces.first?.name ||
      // Apple provides no documentation on whether order is meaningful, so assume it isn't.
      Set(self.gateways) != Set(path.gateways)
  }
}
