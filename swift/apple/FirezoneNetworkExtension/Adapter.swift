//
//  Adapter.swift
//  (c) 2024-2025 Firezone, Inc.
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
  case invalidSession(Session?)

  /// connlib failed to start
  case connlibConnectError(String)

  var localizedDescription: String {
    switch self {
    case .invalidSession(let session):
      let message = session == nil ? "Session is disconnected" : "Session is still connected"
      return message
    case .connlibConnectError(let error):
      return "connlib failed to start: \(error)"
    }
  }
}

/// Sendable callbacks for tunnel operations.
///
/// This struct captures closures from PacketTunnelProvider, allowing the Adapter actor
/// to interact with the provider. The closures capture `[weak self]` to avoid retain cycles.
///
/// Thread-safety: This type is marked `@unchecked Sendable` because the captured closures
/// reference PacketTunnelProvider, which cannot be made Sendable (NEPacketTunnelProvider
/// predates Swift concurrency and its methods are nonisolated). This is safe because:
/// - The closures capture weak references, preventing retain cycles
/// - PacketTunnelProvider lifecycle is managed by NetworkExtension framework (single instance)
/// - The closures only call system-provided methods that handle their own synchronisation
struct TunnelCallbacks: @unchecked Sendable {
  /// Cancel the tunnel with an optional error.
  let cancelWithError: (Error?) -> Void

  /// Set the reasserting state (indicates network transition).
  let setReassserting: (Bool) -> Void

  /// Get the current reasserting state.
  let getReassserting: () -> Bool

  /// Apply network settings to the tunnel.
  let applyNetworkSettings:
    (
      NEPacketTunnelNetworkSettings,
      @escaping @Sendable (Error?) -> Void
    ) -> Void
}

// Loosely inspired from WireGuardAdapter from WireGuardKit
actor Adapter {

  /// Command sender for sending commands to the session
  private var commandSender: Sender<SessionCommand>?

  /// Task handles wrapped in CancellableTask for automatic cleanup via RAII.
  private var eventLoopTask: CancellableTask?
  private var eventConsumerTask: CancellableTask?
  private var pathMonitorTask: CancellableTask?

  // Our local copy of the accountSlug
  private let accountSlug: String

  /// Network settings for tunnel configuration.
  private var networkSettings: NetworkSettings?

  /// Callbacks for interacting with the PacketTunnelProvider.
  private let callbacks: TunnelCallbacks

  /// Continuation to signal tunnel is ready after receiving first tunInterfaceUpdated event.
  private var startContinuation: CheckedContinuation<Void, Error>?

  #if os(macOS)
    /// Used for finding system DNS resolvers on macOS when network conditions have changed.
    private let systemConfigurationResolvers = SystemConfigurationResolvers()
  #endif

  /// Remembers the last _relevant_ path update.
  /// A path update is considered relevant if certain properties change that require us to reset connlib's
  /// network state.
  private var lastPath: Network.NWPath?

  /// Internet resource enabled state
  private var internetResourceEnabled: Bool

  /// Keep track of resources for UI
  private var resources: [Resource]?

  /// Starting parameters
  private let apiURL: String
  private let token: Token
  private let deviceId: String
  private let logFilter: String

  init(
    apiURL: String,
    token: Token,
    deviceId: String,
    logFilter: String,
    accountSlug: String,
    internetResourceEnabled: Bool,
    callbacks: TunnelCallbacks
  ) {
    self.apiURL = apiURL
    self.token = token
    self.deviceId = deviceId
    self.logFilter = logFilter
    self.accountSlug = accountSlug
    self.internetResourceEnabled = internetResourceEnabled
    self.callbacks = callbacks
  }

  func start() async throws {
    Log.log("Adapter.start: Starting session for account: \(accountSlug)")

    // Get device metadata from MainActor
    #if os(iOS)
      let (deviceName, identifierForVendor) = await MainActor.run {
        (DeviceMetadata.getDeviceName(), DeviceMetadata.getIdentifierForVendor())
      }
      let deviceInfo = DeviceInfo(
        firebaseInstallationId: nil,
        deviceUuid: nil,
        deviceSerial: nil,
        identifierForVendor: identifierForVendor
      )
    #else
      let deviceName = await MainActor.run {
        DeviceMetadata.getDeviceName()
      }
      let deviceInfo = DeviceInfo(
        firebaseInstallationId: nil,
        deviceUuid: getDeviceUuid(),
        deviceSerial: getDeviceSerial(),
        identifierForVendor: nil
      )
    #endif

    let osVersion = DeviceMetadata.getOSVersion()
    let logDir = SharedAccess.connlibLogFolderURL?.path ?? "/tmp/firezone"

    // Create the session
    let session: Session
    do {
      session = try Session.newApple(
        apiUrl: apiURL,
        token: token.description,
        deviceId: deviceId,
        accountSlug: accountSlug,
        deviceName: deviceName,
        osVersion: osVersion,
        logDir: logDir,
        logFilter: logFilter,
        deviceInfo: deviceInfo,
        isInternetResourceActive: internetResourceEnabled
      )
    } catch {
      throw AdapterError.connlibConnectError(String(describing: error))
    }

    // Create channels - following Rust pattern with separate sender/receiver
    let (commandSender, commandReceiver): (Sender<SessionCommand>, Receiver<SessionCommand>) =
      Channel.create()
    self.commandSender = commandSender

    let (eventSender, eventReceiver): (Sender<Event>, Receiver<Event>) = Channel.create()

    // Start event loop - owns session, receives commands, sends events
    eventLoopTask = CancellableTask(
      Task {
        defer {
          Log.log("Adapter: Event loop finished, session dropped")
        }

        await runSessionEventLoop(
          session: session,
          commandReceiver: commandReceiver,
          eventSender: eventSender
        )
      })

    // Start event consumer - consumes events from receiver (Rust pattern: receiver outside)
    eventConsumerTask = CancellableTask(
      Task { [weak self] in
        for await event in eventReceiver.stream {
          // Check self on each iteration - if Adapter is deallocated, stop processing events
          guard let self = self else {
            Log.log("Adapter: Event consumer stopping - Adapter deallocated")
            break
          }

          await self.handleEvent(event)
        }

        Log.log("Adapter: Event consumer finished")
      })

    // Start path monitoring - uses AsyncStream with RAII cleanup via onTermination
    pathMonitorTask = CancellableTask(
      Task { [weak self] in
        for await path in networkPathUpdates() {
          guard let self else { break }
          await self.handlePathUpdate(path)
        }
      })

    // Wait for tunnel to be ready (first tunInterfaceUpdated event)
    try await withCheckedThrowingContinuation { continuation in
      self.startContinuation = continuation
    }

    Log.log("Adapter.start: Session started successfully")
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
  func stop() async {
    Log.log("Adapter.stop")

    sendCommand(.disconnect)

    // Cancel path monitoring - triggers CancellableTask.deinit -> Task cancellation
    // -> onTermination -> monitor.cancel()
    pathMonitorTask = nil

    // Tasks will finish naturally after disconnect command is processed
    // No need to cancel them here - they'll clean up via their defer blocks
  }

  /// Get the current set of resources, only returning them if the resource list has changed.
  /// Returns `nil` if resources haven't changed (hash matches) or if encoding fails.
  func getResourcesIfVersionDifferentFrom(hash: Data) -> Data? {
    // Convert uniffi resources to FirezoneKit resources and encode with PropertyList
    guard let uniffiResources = resources else {
      return nil
    }

    let firezoneResources = uniffiResources.map { convertResource($0) }

    guard let encoded = try? PropertyListEncoder().encode(firezoneResources) else {
      Log.log("Failed to encode resources as PropertyList")
      return nil
    }

    if hash == Data(SHA256.hash(data: encoded)) {
      return nil
    } else {
      return encoded
    }
  }

  func reset(reason: String, path: Network.NWPath? = nil) async {
    sendCommand(.reset(reason))

    if let path = (path ?? lastPath) {
      await setSystemDefaultResolvers(path)
    }
  }

  func setInternetResourceEnabled(_ enabled: Bool) async {
    internetResourceEnabled = enabled
    sendCommand(.setInternetResourceState(enabled))
  }

  // MARK: - Event handling

  private func resumeStartContinuation() {
    startContinuation?.resume()
    startContinuation = nil
  }

  private func handleEvent(_ event: Event) async {
    switch event {
    case .tunInterfaceUpdated(
      let ipv4, let ipv6, let dns, let searchDomain, let ipv4Routes, let ipv6Routes):
      Log.log("Received TunInterfaceUpdated event")

      let firstStart = self.networkSettings == nil

      // Convert UniFFI types to NetworkExtension types
      let routes4 = ipv4Routes.compactMap { cidr in
        NetworkSettings.Cidr(address: cidr.address, prefix: Int(cidr.prefix)).asNEIPv4Route
      }
      let routes6 = ipv6Routes.compactMap { cidr in
        NetworkSettings.Cidr(address: cidr.address, prefix: Int(cidr.prefix)).asNEIPv6Route
      }

      Log.log("Setting interface config")

      let networkSettings = NetworkSettings(applySettings: callbacks.applyNetworkSettings)
      networkSettings.tunnelAddressIPv4 = ipv4
      networkSettings.tunnelAddressIPv6 = ipv6
      networkSettings.dnsAddresses = dns
      networkSettings.routes4 = routes4
      networkSettings.routes6 = routes6
      networkSettings.setSearchDomain(domain: searchDomain)
      self.networkSettings = networkSettings

      // The apply completion handler runs on an arbitrary queue, not actor-isolated.
      // We use Task to bridge back to actor isolation for resumeStartContinuation().
      networkSettings.apply { [weak self] in
        guard let self else { return }
        if firstStart {
          Task {
            await self.resumeStartContinuation()
          }
        }
      }

    case .resourcesUpdated(let resourceList):
      Log.log("Received ResourcesUpdated event with \(resourceList.count) resources")

      // Store resource list (actor-isolated, no dispatch needed)
      resources = resourceList

      // Apply network settings to flush DNS cache when resources change
      // This ensures new DNS resources are immediately resolvable
      if let networkSettings = networkSettings {
        Log.log("Reapplying network settings to flush DNS cache after resource update")
        networkSettings.apply()
      }

    case .disconnected(let error):
      let errorMessage = error.message()
      Log.info("Received Disconnected event: \(errorMessage)")

      if error.isAuthenticationError() {
        #if os(iOS)
          // iOS notifications should be shown from the tunnel process
          SessionNotification.showSignedOutNotificationiOS()
        #endif

        let error = FirezoneKit.ConnlibError.sessionExpired(errorMessage)

        callbacks.cancelWithError(error)
      } else {
        callbacks.cancelWithError(nil)
      }
    }
  }

  private func setSystemDefaultResolvers(_ path: Network.NWPath) async {
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
      let resolvers = await resetToSystemDNSGettingBindResolvers()
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

    // Step 3: Send to connlib
    Log.log("Sending resolvers to connlib: \(parsedResolvers)")
    sendCommand(.setDns(parsedResolvers))
  }

  /// Handles network path updates from NWPathMonitor.
  ///
  /// This callback is invoked whenever:
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
  private func handlePathUpdate(_ path: Network.NWPath) async {
    if path.status == .unsatisfied {
      // Check if we need to set reasserting, avoids OS log spam and potentially other side effects
      if !callbacks.getReassserting() {
        // Tell the UI we're not connected
        callbacks.setReassserting(true)
      }
    } else {
      if callbacks.getReassserting() {
        callbacks.setReassserting(false)
      }

      // Tell connlib to reset network state and DNS resolvers, but only do so if our connectivity has
      // meaningfully changed. On darwin, this is needed to send packets
      // out of a different interface even when 0.0.0.0 is used as the source.
      // If our primary interface changes, we can be certain the old socket shouldn't be
      // used anymore.
      if path.connectivityDifferentFrom(path: lastPath) {
        sendCommand(.reset("primary network path changed"))
      }

      await setSystemDefaultResolvers(path)

      lastPath = path
    }
  }

  private func sendCommand(_ command: SessionCommand) {
    commandSender?.send(command)
  }

  // MARK: - Resource conversion (uniffi → FirezoneKit)

  private func convertResource(_ resource: Resource) -> FirezoneKit.Resource {
    switch resource {
    case .dns(let dnsResource):
      return FirezoneKit.Resource(
        id: dnsResource.id,
        name: dnsResource.name,
        address: dnsResource.address,
        addressDescription: dnsResource.addressDescription,
        status: convertResourceStatus(dnsResource.status),
        sites: dnsResource.sites.map { convertSite($0) },
        type: .dns
      )
    case .cidr(let cidrResource):
      return FirezoneKit.Resource(
        id: cidrResource.id,
        name: cidrResource.name,
        address: cidrResource.address,
        addressDescription: cidrResource.addressDescription,
        status: convertResourceStatus(cidrResource.status),
        sites: cidrResource.sites.map { convertSite($0) },
        type: .cidr
      )
    case .internet(let internetResource):
      return FirezoneKit.Resource(
        id: internetResource.id,
        name: internetResource.name,
        address: nil,
        addressDescription: nil,
        status: convertResourceStatus(internetResource.status),
        sites: internetResource.sites.map { convertSite($0) },
        type: .internet
      )
    }
  }

  private func convertSite(_ site: Site) -> FirezoneKit.Site {
    return FirezoneKit.Site(
      id: site.id,
      name: site.name
    )
  }

  private func convertResourceStatus(_ status: ResourceStatus) -> FirezoneKit.ResourceStatus {
    switch status {
    case .unknown:
      return .unknown
    case .online:
      return .online
    case .offline:
      return .offline
    }
  }

}

// MARK: Getting System Resolvers on iOS
#if os(iOS)
  extension Adapter {
    /// When the tunnel is up, we can only get the system's default resolvers
    /// by reading /etc/resolv.conf when matchDomains is set to a non-empty string.
    /// If matchDomains is an empty string, /etc/resolv.conf will contain connlib's
    /// sentinel, which isn't helpful to us.
    private func resetToSystemDNSGettingBindResolvers() async -> [String] {
      guard let networkSettings else {
        // Network Settings hasn't been applied yet, so our sentinel isn't
        // the system's resolver and we can grab the system resolvers directly.
        // If we try to continue below without valid tunnel addresses assigned
        // to the interface, we'll crash.
        return BindResolvers.getServers()
      }

      // Set tunnel's matchDomains to a dummy string that will never match any name
      networkSettings.setDummyMatchDomain()

      // Call apply to populate /etc/resolv.conf with the system's default resolvers
      await withCheckedContinuation { continuation in
        networkSettings.apply {
          continuation.resume()
        }
      }

      // Only now can we get the system resolvers
      let resolvers = BindResolvers.getServers()

      // Restore connlib's DNS resolvers
      networkSettings.clearDummyMatchDomain()

      await withCheckedContinuation { continuation in
        networkSettings.apply {
          continuation.resume()
        }
      }

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
