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

/// Thread-safe wrapper for mutable state using NSLock.
/// Provides similar API to OSAllocatedUnfairLock but compatible with iOS 15+.
/// We can't use OSAllocatedUnfairLock as it requires iOS 16+.
final class LockedState<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: Value

  init(initialState: Value) {
    _value = initialState
  }

  func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&_value)
  }
}

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
class Adapter: @unchecked Sendable {

  /// Command sender for sending commands to the session
  private var commandSender: Sender<SessionCommand>?

  /// Task handles for explicit cancellation during cleanup
  private var eventLoopTask: Task<Void, Never>?
  private var eventConsumerTask: Task<Void, Never>?

  /// Task handle for path monitoring - uses CancellableTask for RAII cleanup
  private var pathMonitorTask: CancellableTask?

  // Our local copy of the accountSlug
  private let accountSlug: String

  /// Network settings for tunnel configuration.
  private var networkSettings: NetworkSettings

  /// Tracks whether we have applied any network settings
  private var hasAppliedSettings: Bool = false

  /// Packet tunnel provider.
  private weak var packetTunnelProvider: PacketTunnelProvider?

  /// Start completion handler, used to signal to the system the interface is ready to use.
  private var startCompletionHandler: (Error?) -> Void

  /// Used for finding system DNS resolvers when network conditions have changed.
  private let systemConfigurationResolvers: SystemConfigurationResolvers

  /// Remembers the last _relevant_ path update.
  /// A path update is considered relevant if certain properties change that require us to reset connlib's
  /// network state.
  private var lastPath: Network.NWPath?

  /// Private queue used to ensure consistent ordering among path update and connlib callbacks
  /// This is the primary async primitive used in this class.
  private let workQueue = DispatchQueue(label: "FirezoneAdapterWorkQueue")

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
  /// On macOS, we use the SystemConfiguration framework to read the system's DNS resolvers directly.
  ///
  /// On iOS, we use dlsym to access the `dns_configuration_copy` function which
  /// returns scoped resolvers that aren't shadowed by our tunnel's DNS settings.
  ///
  /// See the following issues for background:
  /// - https://github.com/firezone/firezone/issues/3302
  /// - https://github.com/firezone/firezone/issues/3343
  /// - https://github.com/firezone/firezone/issues/3235
  /// - https://github.com/firezone/firezone/issues/3175
  private func handlePathUpdate(_ path: Network.NWPath) {
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
        self.sendCommand(.reset("primary network path changed"))
      }

      setSystemDefaultResolvers(path)

      lastPath = path
    }
  }

  /// Internet resource enabled state
  private var internetResourceEnabled: Bool

  /// Keep track of resources for UI
  private var resources: [Resource]?  // swiftlint:disable:this discouraged_optional_collection

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
    packetTunnelProvider: PacketTunnelProvider,
    startCompletionHandler: @escaping (Error?) -> Void
  ) throws {
    self.apiURL = apiURL
    self.token = token
    self.deviceId = deviceId
    self.logFilter = logFilter
    self.accountSlug = accountSlug
    self.internetResourceEnabled = internetResourceEnabled
    self.packetTunnelProvider = packetTunnelProvider
    self.startCompletionHandler = startCompletionHandler
    self.networkSettings = NetworkSettings()
    self.systemConfigurationResolvers = try SystemConfigurationResolvers()
  }

  // Could happen abruptly if the process is killed.
  deinit {
    Log.log("Adapter.deinit")

    // Cancel all Tasks - this triggers cooperative cancellation
    // Event loop checks Task.isCancelled in its polling loop
    // Event consumer will exit when eventSender.deinit closes the stream
    eventLoopTask?.cancel()
    eventConsumerTask?.cancel()

    // pathMonitorTask cleanup is handled automatically by CancellableTask.deinit
    // which cancels the Task, triggering onTermination -> monitor.cancel()
  }

  func start() async throws {
    Log.log("Adapter.start: Starting session for account: \(accountSlug)")

    // Get device metadata - asynchronously get values from MainActor
    let deviceName: String
    #if os(iOS)
      let identifierForVendor: String?
      (deviceName, identifierForVendor) = await MainActor.run {
        (DeviceMetadata.getDeviceName(), DeviceMetadata.getIdentifierForVendor())
      }
    #else
      deviceName = await MainActor.run {
        DeviceMetadata.getDeviceName()
      }
    #endif

    let logDir = SharedAccess.connlibLogFolderURL?.path ?? "/tmp/firezone"

    #if os(iOS)
      let deviceInfo = DeviceInfo(
        firebaseInstallationId: nil,
        deviceUuid: nil,
        deviceSerial: nil,
        identifierForVendor: identifierForVendor
      )
    #else
      let deviceInfo = DeviceInfo(
        firebaseInstallationId: nil,
        deviceUuid: getDeviceUuid(),
        deviceSerial: getDeviceSerial(),
        identifierForVendor: nil
      )
    #endif

    // Create the session
    let session: Session
    do {
      session = try Session.newApple(
        apiUrl: apiURL,
        token: token.description,
        deviceId: deviceId,
        accountSlug: accountSlug,
        deviceName: deviceName,
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
  func stop() {
    Log.log("Adapter.stop")

    sendCommand(.disconnect)

    // Cancel path monitoring - CancellableTask.deinit triggers Task cancellation
    // -> onTermination -> monitor.cancel()
    pathMonitorTask = nil

    // Tasks will finish naturally after disconnect command is processed
    // No need to cancel them here - they'll clean up via their defer blocks
  }

  /// Get the current set of resources in the completionHandler, only returning
  /// them if the resource list has changed.
  func getResourcesIfVersionDifferentFrom(
    hash: Data, completionHandler: @escaping @Sendable (Data?) -> Void
  ) {
    Task { [weak self] in
      guard let self = self else {
        completionHandler(nil)
        return
      }

      // Convert uniffi resources to FirezoneKit resources and encode with PropertyList
      guard let uniffiResources = self.resources
      else {
        completionHandler(nil)
        return
      }

      let firezoneResources = uniffiResources.map { self.convertResource($0) }

      guard let encoded = try? PropertyListEncoder().encode(firezoneResources)
      else {
        Log.log("Failed to encode resources as PropertyList")
        completionHandler(nil)
        return
      }

      if hash == Data(SHA256.hash(data: encoded)) {
        // nothing changed
        completionHandler(nil)
      } else {
        completionHandler(encoded)
      }
    }
  }

  func reset(reason: String, path: Network.NWPath? = nil) {
    workQueue.async { [weak self] in
      guard let self = self else { return }
      self.sendCommand(.reset(reason))

      if let path = (path ?? self.lastPath) {
        self.setSystemDefaultResolvers(path)
      }
    }
  }

  func setInternetResourceEnabled(_ enabled: Bool) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.internetResourceEnabled = enabled
      self.sendCommand(.setInternetResourceState(enabled))
    }
  }

  // MARK: - Network settings

  private func applyNetworkSettings(
    _ tunnelNetworkSettings: NEPacketTunnelNetworkSettings?,
    completionHandler: (@Sendable () -> Void)? = nil
  ) {
    guard let tunnelNetworkSettings = tunnelNetworkSettings else {
      Log.log("Skipping network settings apply; settings unchanged")
      completionHandler?()
      return
    }

    guard let provider = packetTunnelProvider else {
      Log.error(AdapterError.invalidSession(nil))
      completionHandler?()
      return
    }

    Log.log("Applying network settings; settings changed")

    provider.setTunnelNetworkSettings(tunnelNetworkSettings) { [weak self] error in
      if let error = error {
        Log.error(error)
      } else {
        // Mark that we have applied settings successfully
        self?.hasAppliedSettings = true
      }
      completionHandler?()
    }
  }

  // MARK: - Event handling

  private func handleEvent(_ event: Event) async {
    switch event {
    case .tunInterfaceUpdated(
      let ipv4, let ipv6, let dns, let searchDomain, let ipv4Routes, let ipv6Routes):
      Log.log("Received TunInterfaceUpdated event")

      workQueue.async { [weak self] in
        guard let self = self else { return }

        let firstStart = !self.hasAppliedSettings

        // Convert UniFFI types to NetworkExtension types
        let routes4 = ipv4Routes.compactMap { cidr in
          NetworkSettings.Cidr(address: cidr.address, prefix: Int(cidr.prefix)).asNEIPv4Route
        }
        let routes6 = ipv6Routes.compactMap { cidr in
          NetworkSettings.Cidr(address: cidr.address, prefix: Int(cidr.prefix)).asNEIPv6Route
        }

        Log.log("Setting interface config")

        let tunnelNetworkSettings = self.networkSettings.updateTunInterface(
          ipv4: ipv4,
          ipv6: ipv6,
          dnsServers: dns,
          searchDomain: searchDomain,
          routes4: routes4,
          routes6: routes6
        )

        self.applyNetworkSettings(tunnelNetworkSettings) {
          if firstStart {
            self.startCompletionHandler(nil)
            self.packetTunnelProvider?.startLogCleanupTask()
          }
        }
      }

    case .resourcesUpdated(let resourceList):
      Log.log("Received ResourcesUpdated event with \(resourceList.count) resources")

      workQueue.async { [weak self] in
        guard let self = self else { return }
        self.resources = resourceList

        // Update DNS resource addresses to trigger network settings apply when they change
        // This flushes the DNS cache so new DNS resources are immediately resolvable
        let dnsAddresses = resourceList.compactMap { resource in
          if case .dns(let dnsResource) = resource {
            return dnsResource.address
          }
          return nil
        }
        let tunnelNetworkSettings = self.networkSettings.updateDnsResources(
          newDnsResources: dnsAddresses)
        self.applyNetworkSettings(tunnelNetworkSettings)
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
    // Start path monitoring using AsyncStream with RAII cleanup via CancellableTask
    pathMonitorTask = CancellableTask { [weak self] in
      for await path in networkPathUpdates() {
        guard let self else { break }
        // Dispatch to workQueue for thread safety with other Adapter operations
        self.workQueue.async { [weak self] in
          self?.handlePathUpdate(path)
        }
      }
    }
  }

  private func setSystemDefaultResolvers(_ path: Network.NWPath) {
    // Step 1: Get system default resolvers
    let resolvers = self.systemConfigurationResolvers.getDefaultDNSServers(
      interfaceName: path.availableInterfaces.first?.name)

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

  private func sendCommand(_ command: SessionCommand) {
    commandSender?.send(command)
  }

  // MARK: - Resource conversion (uniffi → FirezoneKit)

  private func convertResource(_ uniffiResource: Resource) -> FirezoneKit.Resource {
    switch uniffiResource {
    case .dns(let resource):
      FirezoneKit.Resource(
        id: resource.id, name: resource.name, address: resource.address,
        addressDescription: resource.addressDescription,
        status: .init(resource.status), sites: resource.sites.map { .init($0) }, type: .dns)
    case .cidr(let resource):
      FirezoneKit.Resource(
        id: resource.id, name: resource.name, address: resource.address,
        addressDescription: resource.addressDescription,
        status: .init(resource.status), sites: resource.sites.map { .init($0) }, type: .cidr)
    case .internet(let resource):
      FirezoneKit.Resource(
        id: resource.id, name: resource.name, address: nil, addressDescription: nil,
        status: .init(resource.status), sites: resource.sites.map { .init($0) }, type: .internet)
    }
  }
}

// MARK: - UniFFI → FirezoneKit type conversions

extension FirezoneKit.Site {
  init(_ site: Site) {
    self.init(id: site.id, name: site.name)
  }
}

extension FirezoneKit.ResourceStatus {
  init(_ status: ResourceStatus) {
    switch status {
    case .unknown: self = .unknown
    case .online: self = .online
    case .offline: self = .offline
    }
  }
}

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
