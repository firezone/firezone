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

// Loosely inspired from WireGuardAdapter from WireGuardKit
actor Adapter {

  /// Command sender for sending commands to the session
  private nonisolated(unsafe) var commandSender: Sender<SessionCommand>?

  /// Task handles for explicit cancellation during cleanup
  private nonisolated(unsafe) var eventLoopTask: Task<Void, Never>?
  private nonisolated(unsafe) var eventConsumerTask: Task<Void, Never>?

  // Our local copy of the accountSlug
  private let accountSlug: String

  /// Network settings for tunnel configuration.
  private var networkSettings: NetworkSettings?

  /// Packet tunnel provider.
  private weak var packetTunnelProvider: PacketTunnelProvider?

  /// Continuation to signal tunnel is ready after receiving first tunInterfaceUpdated event.
  private var startContinuation: CheckedContinuation<Void, Error>?

  /// Network routes monitor.
  private nonisolated(unsafe) var networkMonitor: NWPathMonitor?

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
    packetTunnelProvider: PacketTunnelProvider
  ) {
    self.apiURL = apiURL
    self.token = token
    self.deviceId = deviceId
    self.logFilter = logFilter
    self.accountSlug = accountSlug
    self.internetResourceEnabled = internetResourceEnabled
    self.packetTunnelProvider = packetTunnelProvider
  }

  // Could happen abruptly if the process is killed.
  deinit {
    Log.log("Adapter.deinit")

    // Cancel network monitor
    networkMonitor?.cancel()
    networkMonitor = nil

    // Cancel all Tasks - this triggers cooperative cancellation
    // Event loop checks Task.isCancelled in its polling loop
    // Event consumer will exit when eventSender.deinit closes the stream
    eventLoopTask?.cancel()
    eventConsumerTask?.cancel()
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
    eventLoopTask = Task { [weak self] in
      defer {
        // ALWAYS cleanup, even if event loop crashes
        self?.commandSender = nil
        Log.log("Adapter: Event loop finished, session dropped")
      }

      await runSessionEventLoop(
        session: session,
        commandReceiver: commandReceiver,
        eventSender: eventSender
      )
    }

    // Start event consumer - consumes events from receiver (Rust pattern: receiver outside)
    eventConsumerTask = Task { [weak self] in
      for await event in eventReceiver.stream {
        // Check self on each iteration - if Adapter is deallocated, stop processing events
        guard let self = self else {
          Log.log("Adapter: Event consumer stopping - Adapter deallocated")
          break
        }

        await self.handleEvent(event)
      }

      Log.log("Adapter: Event consumer finished")
    }

    // Configure DNS and path monitoring
    startNetworkPathMonitoring()

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

    networkMonitor?.cancel()
    networkMonitor = nil

    // Tasks will finish naturally after disconnect command is processed
    // No need to cancel them here - they'll clean up via their defer blocks
  }

  /// Get the current set of resources in the completionHandler, only returning
  /// them if the resource list has changed.
  func getResourcesIfVersionDifferentFrom(
    hash: Data, completionHandler: @escaping @Sendable (Data?) -> Void
  ) {
    // Convert uniffi resources to FirezoneKit resources and encode with PropertyList
    guard let uniffiResources = resources else {
      completionHandler(nil)
      return
    }

    let firezoneResources = uniffiResources.map { convertResource($0) }

    guard let encoded = try? PropertyListEncoder().encode(firezoneResources) else {
      Log.log("Failed to encode resources as PropertyList")
      completionHandler(nil)
      return
    }

    if hash == Data(SHA256.hash(data: encoded)) {
      completionHandler(nil)
    } else {
      completionHandler(encoded)
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

      // All decoding succeeded - now apply settings atomically
      guard let provider = packetTunnelProvider else {
        Log.error(AdapterError.invalidSession(nil))
        return
      }

      Log.log("Setting interface config")

      let networkSettings = NetworkSettings(packetTunnelProvider: provider)
      networkSettings.tunnelAddressIPv4 = ipv4
      networkSettings.tunnelAddressIPv6 = ipv6
      networkSettings.dnsAddresses = dns
      networkSettings.routes4 = routes4
      networkSettings.routes6 = routes6
      networkSettings.setSearchDomain(domain: searchDomain)
      self.networkSettings = networkSettings

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

      guard let provider = packetTunnelProvider else {
        Log.error(AdapterError.invalidSession(nil))
        return
      }

      if error.isAuthenticationError() {
        #if os(iOS)
          // iOS notifications should be shown from the tunnel process
          SessionNotification.showSignedOutNotificationiOS()
        #endif

        let error = FirezoneKit.ConnlibError.sessionExpired(errorMessage)

        provider.cancelTunnelWithError(error)
      } else {
        provider.cancelTunnelWithError(nil)
      }
    }
  }

  private func startNetworkPathMonitoring() {
    networkMonitor = NWPathMonitor()
    networkMonitor?.pathUpdateHandler = { [weak self] path in
      Task { [weak self] in
        await self?.handlePathUpdate(path)
      }
    }
    networkMonitor?.start(queue: .global())
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

  private func handlePathUpdate(_ path: Network.NWPath) async {
    if path.status == .unsatisfied {
      if packetTunnelProvider?.reasserting == false {
        packetTunnelProvider?.reasserting = true
      }
    } else {
      if packetTunnelProvider?.reasserting == true {
        packetTunnelProvider?.reasserting = false
      }

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
        return BindResolvers.getServers()
      }

      // Set tunnel's matchDomains to a dummy string that will never match any name
      networkSettings.setDummyMatchDomain()

      // Apply to populate /etc/resolv.conf with the system's default resolvers
      await withCheckedContinuation { continuation in
        networkSettings.apply {
          continuation.resume()
        }
      }

      // Now we can get the system resolvers
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
