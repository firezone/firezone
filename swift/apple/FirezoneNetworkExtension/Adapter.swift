//
//  Adapter.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// TODO: Refactor to fix file length

import CryptoKit
import FirezoneKit
import Foundation
import NetworkExtension
import OSLog

enum AdapterError: Error {
  /// Failure to perform an operation in such state.
  case invalidSession(WrappedSession?)

  /// connlib failed to start
  case connlibConnectError(String)

  case setDnsError(String)

  var localizedDescription: String {
    switch self {
    case .invalidSession(let session):
      let message = session == nil ? "Session is disconnected" : "Session is still connected"
      return message
    case .connlibConnectError(let error):
      return "connlib failed to start: \(error)"
    case .setDnsError(let error):
      return "failed to set new DNS serversn: \(error)"
  }
}

// Loosely inspired from WireGuardAdapter from WireGuardKit
class Adapter {
  typealias StartTunnelCompletionHandler = ((AdapterError?) -> Void)

  private var callbackHandler: CallbackHandler

  private var session: WrappedSession?

  // Our local copy of the accountSlug
  private var accountSlug: String

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

  #if os(macOS)
    /// Used for finding system DNS resolvers on macOS when network conditions have changed.
    private let systemConfigurationResolvers = SystemConfigurationResolvers()
  #endif

  /// Remembers the last _relevant_ path update.
  /// A path update is considered relevant if certain properties change that require us to reset connlib's
  /// network state.
  private var lastPath: Network.NWPath?

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
  /// The issue is that this in itself causes a path update callback, which makes it hard to
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

    if path.status == .unsatisfied {
      // Check if we need to set reasserting, avoids OS log spam and potentially other side effects
      if self.packetTunnelProvider?.reasserting == false {
        // Tell the UI we're not connected
        self.packetTunnelProvider?.reasserting = true
      }
    } else {
      if self.packetTunnelProvider?.reasserting == true {
        self.packetTunnelProvider?.reasserting = false
      }

      if path.connectivityDifferentFrom(path: lastPath) {
        // Tell connlib to reset network state and DNS resolvers, but only do so if our connectivity has
        // meaningfully changed. On darwin, this is needed to send packets
        // out of a different interface even when 0.0.0.0 is used as the source.
        // If our primary interface changes, we can be certain the old socket shouldn't be
        // used anymore.
        session?.reset("primary network path changed")
      }

      setSystemDefaultResolvers(path)

      lastPath = path
    }
  }

  /// Currently disabled resources
  private var internetResourceEnabled: Bool

  /// Cache of internet resource
  private var internetResource: Resource?

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
    accountSlug: String,
    internetResourceEnabled: Bool,
    packetTunnelProvider: PacketTunnelProvider
  ) {
    self.apiURL = apiURL
    self.token = token
    self.id = id
    self.packetTunnelProvider = packetTunnelProvider
    self.callbackHandler = CallbackHandler()
    self.logFilter = logFilter
    self.accountSlug = accountSlug
    self.connlibLogFolderPath = SharedAccess.connlibLogFolderURL?.path ?? ""
    self.networkSettings = nil
    self.internetResourceEnabled = internetResourceEnabled
  }

  // Could happen abruptly if the process is killed.
  deinit {
    Log.log("Adapter.deinit")

    // Cancel network monitor
    networkMonitor?.cancel()
  }

  /// Start the tunnel.
  func start() throws {
    Log.log("Adapter.start")

    guard session == nil else {
      throw AdapterError.invalidSession(session)
    }

    callbackHandler.delegate = self

    Log.log("Adapter.start: Starting connlib")
    do {
      let jsonEncoder = JSONEncoder()
      jsonEncoder.keyEncodingStrategy = .convertToSnakeCase

      // Grab a session pointer
      session = try WrappedSession.connect(
        apiURL,
        "\(token)",
        "\(id)",
        accountSlug,
        DeviceMetadata.getDeviceName(),
        DeviceMetadata.getOSVersion(),
        connlibLogFolderPath,
        logFilter,
        callbackHandler,
        String(data: jsonEncoder.encode(DeviceMetadata.deviceInfo()), encoding: .utf8)!
      )
    } catch let error {
      // `toString` needed to deep copy the string and avoid a possible dangling pointer
      let msg = (error as? RustString)?.toString() ?? "Unknown error"
      throw AdapterError.connlibConnectError(msg)
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
  func stop() {
    Log.log("Adapter.stop")

    // Assigning `nil` will invoke `Drop` on the Rust side
    session = nil

    networkMonitor?.cancel()
    networkMonitor = nil
  }

  /// Get the current set of resources in the completionHandler, only returning
  /// them if the resource list has changed.
  func getResourcesIfVersionDifferentFrom(
    hash: Data, completionHandler: @escaping (String?) -> Void
  ) {
    // This is async to avoid blocking the main UI thread
    workQueue.async { [weak self] in
      guard let self = self else { return }

      if hash == Data(SHA256.hash(data: Data((resourceListJSON ?? "").utf8))) {
        // nothing changed
        completionHandler(nil)
      } else {
        completionHandler(resourceListJSON)
      }
    }
  }

  func reset(reason: String, path: Network.NWPath? = nil) {
    session?.reset(reason)

    if let path = (path ?? lastPath) {
      setSystemDefaultResolvers(path)
    }
  }

  func resources() -> [Resource] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let resourceList = resourceListJSON else { return [] }
    return (try? decoder.decode([Resource].self, from: resourceList.data(using: .utf8)!)) ?? []
  }

  func setInternetResourceEnabled(_ enabled: Bool) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.internetResourceEnabled = enabled
      self.resourcesUpdated()
    }
  }

  func resourcesUpdated() {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    session?.setInternetResourceState(internetResourceEnabled)
  }
}

// MARK: Responding to path updates

extension Adapter {
  private func beginPathMonitoring() {
    let networkMonitor = NWPathMonitor()
    networkMonitor.pathUpdateHandler = self.pathUpdateHandler
    networkMonitor.start(queue: self.workQueue)
  }
}

// MARK: Implementing CallbackHandlerDelegate

extension Adapter: CallbackHandlerDelegate {
  func onSetInterfaceConfig(
    tunnelAddressIPv4: String,
    tunnelAddressIPv6: String,
    searchDomain: String?,
    dnsAddresses: [String],
    routeListv4: String,
    routeListv6: String
  ) {
    // This is a queued callback to ensure ordering
    workQueue.async { [weak self] in
      guard let self = self else { return }

      let networkSettings =
        networkSettings ?? NetworkSettings(packetTunnelProvider: packetTunnelProvider)

      guard let data4 = routeListv4.data(using: .utf8),
        let data6 = routeListv6.data(using: .utf8),
        let decoded4 = try? JSONDecoder().decode([NetworkSettings.Cidr].self, from: data4),
        let decoded6 = try? JSONDecoder().decode([NetworkSettings.Cidr].self, from: data6)
      else {
        fatalError("Could not decode route list from connlib")
      }

      let routes4 = decoded4.compactMap({ $0.asNEIPv4Route })
      let routes6 = decoded6.compactMap({ $0.asNEIPv6Route })

      networkSettings.tunnelAddressIPv4 = tunnelAddressIPv4
      networkSettings.tunnelAddressIPv6 = tunnelAddressIPv6
      networkSettings.dnsAddresses = dnsAddresses
      networkSettings.routes4 = routes4
      networkSettings.routes6 = routes6
      networkSettings.setSearchDomain(domain: searchDomain)
      self.networkSettings = networkSettings

      // Now that we have our interface configured, start listening for events. The first one will be us applying
      // our network settings in the call below. We need the physical interface name macOS chooses for us in order
      // to get the correct DNS resolvers on macOS. For that, we need the path parameter from the path update callback.
      beginPathMonitoring()

      networkSettings.apply()
    }
  }

  func onUpdateResources(resourceList: String) {
    // This is a queued callback to ensure ordering
    workQueue.async { [weak self] in
      guard let self = self else { return }

      if resourceListJSON != resourceList, let networkSettings = self.networkSettings {
        // Update resource List. We don't care what's inside.
        resourceListJSON = resourceList

        // Apply network settings to flush DNS cache when resources change
        // This ensures new DNS resources are immediately resolvable
        Log.log("Reapplying network settings to flush DNS cache after resource update")
        networkSettings.apply()
      }

      self.resourcesUpdated()
    }
  }

  func onDisconnect(error: DisconnectError) {
    // Since connlib has already shutdown by this point, we queue this callback
    // to ensure that we can clean up even if connlib exits before we are done.
    workQueue.async { [weak self] in
      guard let self = self else { return }

      // Immediately invalidate our session pointer to prevent workQueue items from trying to use it.
      // Assigning to `nil` will invoke `Drop` on the Rust side.
      // This must happen asynchronously and not as part of the callback to allow Rust to break
      // cyclic dependencies between the runtime and the task that is executing the callback.
      self.session = nil

      // If auth expired/is invalid, delete stored token and save the reason why so the GUI can act upon it.
      if error.isAuthenticationError() {
        do {
          try Token.delete()
          let reason: NEProviderStopReason = .authenticationCanceled
          try String(reason.rawValue).write(
            to: SharedAccess.providerStopReasonURL, atomically: true, encoding: .utf8)
        } catch {
          Log.error(error)
        }
        #if os(iOS)
          // iOS notifications should be shown from the tunnel process
          SessionNotification.showSignedOutNotificationiOS()
        #endif
      }

      // Tell the system to shut us down
      self.packetTunnelProvider?.cancelTunnelWithError(nil)
    }
  }

  private func setSystemDefaultResolvers(_ path: Network.NWPath) {
    // Step 1: Get system default resolvers
    #if os(macOS)
      let resolvers = self.systemConfigurationResolvers.getDefaultDNSServers(
        interfaceName: path.availableInterfaces.first?.name)
    #elseif os(iOS)

      // DNS server updates don't necessarily trigger a connectivity change, but we'll get a path update callback
      // nevertheless. Unfortunately there's no visible difference in instance properties between the two path
      // objects. On macOS this isn't an issue because setting new resolvers here doesn't trigger a change.
      // On iOS, however, we need to prevent path update loops by not reacting to path updates that we ourselves
      // triggered by the network settings apply.

      // TODO: Find a hackier hack to avoid this on iOS
      if !path.connectivityDifferentFrom(path: lastPath) {
        return
      }
      let resolvers = resetToSystemDNSGettingBindResolvers()
    #endif

    // Step 2: Validate and strip scope suffixes
    var parsedResolvers: [String] = []

    for stringAddress in resolvers {
      if let ipv4Address = IPv4Address(stringAddress) {
        if ipv4Address.isWithinSentinelRange() {
          Log.warning(
            "Not adding fetched system resolver because it's within sentinel range: \(ipv4Address)")
        } else {
          parsedResolvers.append("\(ipv4Address)")
        }

        continue
      }

      if let ipv6Address = IPv6Address(stringAddress) {
        if ipv6Address.isWithinSentinelRange() {
          Log.warning(
            "Not adding fetched system resolver because it's within sentinel range: \(ipv6Address)")
        } else {
          parsedResolvers.append("\(ipv6Address)")
        }

        continue
      }

      Log.warning("IP address \(stringAddress) did not parse as either IPv4 or IPv6")
    }

    // Step 3: Encode
    guard let encoded = try? JSONEncoder().encode(parsedResolvers),
      let jsonResolvers = String(data: encoded, encoding: .utf8)
    else {
      Log.warning("jsonResolvers conversion failed: \(parsedResolvers)")
      return
    }

    // Step 4: Send to connlib
    do {
      Log.log("Sending resolvers to connlib: \(jsonResolvers)")
      try session?.setDns(jsonResolvers.intoRustString())
    } catch let error {
      // `toString` needed to deep copy the string and avoid a possible dangling pointer
      let msg = (error as? RustString)?.toString() ?? "Unknown error"
      Log.error(AdapterError.setDnsError(msg))
    }
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
        return BindResolvers.getServers()
      }

      var resolvers: [String] = []

      // The caller is in an async context, so it's ok to block this thread here.
      let semaphore = DispatchSemaphore(value: 0)

      // Set tunnel's matchDomains to a dummy string that will never match any name
      networkSettings.setDummyMatchDomain()

      // Call apply to populate /etc/resolv.conf with the system's default resolvers
      networkSettings.apply {
        guard let networkSettings = self.networkSettings else { return }

        // Only now can we get the system resolvers
        resolvers = BindResolvers.getServers()

        // Restore connlib's DNS resolvers
        networkSettings.clearDummyMatchDomain()
        networkSettings.apply { semaphore.signal() }
      }

      semaphore.wait()
      return resolvers
    }
  }
#endif

extension Network.NWPath {
  func connectivityDifferentFrom(path: Network.NWPath? = nil) -> Bool {
    // We define a path as different from another if the following properties change
    return path?.supportsIPv4 != self.supportsIPv4 || path?.supportsIPv6 != self.supportsIPv6
      || path?.supportsDNS != self.supportsDNS
      || path?.status != self.status
      || path?.availableInterfaces.first != self.availableInterfaces.first
      || path?.gateways != self.gateways
  }
}

extension IPv4Address {
  func isWithinSentinelRange() -> Bool {
    return "\(self)".hasPrefix("100.100.111.")
  }
}

extension IPv6Address {
  func isWithinSentinelRange() -> Bool {
    return "\(self)".hasPrefix("fd00:2021:1111:8000:100:100:111:")
  }
}
