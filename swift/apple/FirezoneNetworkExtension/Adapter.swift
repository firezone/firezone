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
  private var commandSender: Sender<SessionCommand>?

  /// Task handles wrapped in CancellableTask for automatic cleanup via RAII.
  private var eventLoopTask: CancellableTask?
  private var eventConsumerTask: CancellableTask?
  private var pathMonitorTask: CancellableTask?

  // Our local copy of the accountSlug
  private let accountSlug: String

  /// Current network settings for tunnel configuration.
  private var networkSettings = NetworkSettings()

  /// Tracks whether we have applied any network settings
  private var hasAppliedSettings: Bool = false

  /// Command sender for communicating with PacketTunnelProvider.
  private let providerCommandSender: Sender<ProviderCommand>

  /// Continuation to signal tunnel is ready after receiving first tunInterfaceUpdated event.
  private var startContinuation: CheckedContinuation<Void, Error>?

  /// Used for finding system DNS resolvers when network conditions have changed.
  private let systemConfigurationResolvers: SystemConfigurationResolvers

  /// Remembers the last _relevant_ path update.
  /// A path update is considered relevant if certain properties change that require us to reset connlib's
  /// network state.
  private var lastPath: Network.NWPath?

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
  private func handlePathUpdate(_ path: Network.NWPath) async {
    let isReasserting = await getReasserting()

    if path.status == .unsatisfied {
      // Check if we need to set reasserting, avoids OS log spam and potentially other side effects
      if !isReasserting {
        // Tell the UI we're not connected
        providerCommandSender.send(.setReasserting(true))
      }
    } else {
      if isReasserting {
        providerCommandSender.send(.setReasserting(false))
      }

      if path.connectivityDifferentFrom(path: lastPath) {
        // Tell connlib to reset network state and DNS resolvers, but only do so if our connectivity has
        // meaningfully changed. On darwin, this is needed to send packets
        // out of a different interface even when 0.0.0.0 is used as the source.
        // If our primary interface changes, we can be certain the old socket shouldn't be
        // used anymore.
        sendCommand(.reset("primary network path changed"))
      }

      await setSystemDefaultResolvers(path)

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
    providerCommandSender: Sender<ProviderCommand>
  ) throws {
    self.apiURL = apiURL
    self.token = token
    self.deviceId = deviceId
    self.logFilter = logFilter
    self.accountSlug = accountSlug
    self.internetResourceEnabled = internetResourceEnabled
    self.providerCommandSender = providerCommandSender
    self.systemConfigurationResolvers = try SystemConfigurationResolvers()
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
    eventLoopTask = CancellableTask { @Sendable in
      defer {
        Log.log("Adapter: Event loop finished, session dropped")
      }

      await runSessionEventLoop(
        session: session,
        commandReceiver: commandReceiver,
        eventSender: eventSender
      )
    }

    // Start event consumer - consumes events from receiver (Rust pattern: receiver outside)
    eventConsumerTask = CancellableTask { @Sendable [weak self] in
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

    // Start path monitoring - uses AsyncStream with RAII cleanup via onTermination
    pathMonitorTask = CancellableTask { @Sendable [weak self] in
      for await path in networkPathUpdates() {
        guard let self else { break }
        await self.handlePathUpdate(path)
      }
    }

    // Wait for tunnel to be ready (first tunInterfaceUpdated event)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.startContinuation = continuation
      }
    } onCancel: {
      Task { await self.cancelStartContinuation() }
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

    // Cancel any pending start continuation
    cancelStartContinuation()

    sendCommand(.disconnect)

    // Close command channel immediately - ensures event loop sees channel close
    commandSender = nil

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

    let encoded: Data
    do {
      encoded = try PropertyListEncoder().encode(firezoneResources)
    } catch {
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

  // MARK: - Network settings

  /// Apply network settings via channel to PacketTunnelProvider.
  /// Returns `true` if settings were applied successfully, `false` otherwise.
  private func applyNetworkSettings(_ payload: NetworkSettings.Payload) async -> Bool {
    let (responseSender, responseReceiver): (Sender<String?>, Receiver<String?>) = Channel.create()
    providerCommandSender.send(.applyNetworkSettings(payload, responseSender))

    // Wait for single response
    for await errorMessage in responseReceiver.stream {
      if let errorMessage {
        Log.warning("Failed to apply network settings: \(errorMessage)")
        return false
      }
      return true
    }

    Log.warning("applyNetworkSettings: response channel closed unexpectedly")
    return false
  }

  // MARK: - Event handling

  private func resumeStartContinuation() {
    guard let continuation = startContinuation else { return }
    startContinuation = nil
    continuation.resume()
  }

  private func cancelStartContinuation() {
    guard let continuation = startContinuation else { return }
    startContinuation = nil
    continuation.resume(throwing: CancellationError())
  }

  private func handleEvent(_ event: Event) async {
    switch event {
    case .tunInterfaceUpdated(
      let ipv4, let ipv6, let dns, let searchDomain, let ipv4Routes, let ipv6Routes):
      Log.log("Received TunInterfaceUpdated event")

      let firstStart = !hasAppliedSettings

      // Convert UniFFI types to Cidr
      let routes4 = ipv4Routes.map {
        NetworkSettings.Cidr(address: $0.address, prefix: Int($0.prefix))
      }
      let routes6 = ipv6Routes.map {
        NetworkSettings.Cidr(address: $0.address, prefix: Int($0.prefix))
      }

      Log.log("Setting interface config")

      // Update network settings mutably - returns payload if changed
      let payload = networkSettings.updateTunInterface(
        ipv4: ipv4,
        ipv6: ipv6,
        dnsServers: dns,
        searchDomain: searchDomain,
        routes4: routes4,
        routes6: routes6
      )

      var applySucceeded = true
      if let payload {
        Log.log("Applying interface config - settings changed")
        applySucceeded = await applyNetworkSettings(payload)
      } else {
        Log.log("Skipping interface config apply - no changes")
      }

      // Only mark as applied if we succeeded (or didn't need to apply)
      if applySucceeded {
        hasAppliedSettings = true
      }

      if firstStart {
        if applySucceeded {
          resumeStartContinuation()
          providerCommandSender.send(.startLogCleanupTask)
        } else {
          // Settings failed to apply on first start - signal error
          Log.warning("Failed to apply network settings on first start")
          cancelStartContinuation()
        }
      }

    case .resourcesUpdated(let resourceList):
      Log.log("Received ResourcesUpdated event with \(resourceList.count) resources")

      // Store resource list (actor-isolated, no dispatch needed)
      resources = resourceList

      // Update DNS resource addresses to trigger network settings apply when they change
      // This flushes the DNS cache so new DNS resources are immediately resolvable
      let dnsAddresses = resourceList.compactMap { resource in
        if case .dns(let dnsResource) = resource {
          return dnsResource.address
        }
        return nil
      }

      // Only apply if DNS resources actually changed
      if let payload = networkSettings.updateDnsResources(newDnsResources: dnsAddresses) {
        Log.log("Reapplying network settings to flush DNS cache after resource update")
        // Failure here is non-critical - DNS cache flush is best-effort
        _ = await applyNetworkSettings(payload)
      }

    case .disconnected(let error):
      let errorMessage = error.message()
      Log.info("Received Disconnected event: \(errorMessage)")

      if error.isAuthenticationError() {
        #if os(iOS)
          // iOS notifications should be shown from the tunnel process
          SessionNotification.showSignedOutNotificationiOS()
        #endif

        let sendableError = SendableError(errorMessage, isAuthenticationError: true)
        providerCommandSender.send(.cancelWithError(sendableError))
      } else {
        providerCommandSender.send(.cancelWithError(nil))
      }
    }
  }

  private func setSystemDefaultResolvers(_ path: Network.NWPath) async {
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

  // MARK: - Provider command helpers

  /// Query reasserting state from PacketTunnelProvider via channel.
  private func getReasserting() async -> Bool {
    let (responseSender, responseReceiver): (Sender<Bool>, Receiver<Bool>) = Channel.create()
    providerCommandSender.send(.getReasserting(responseSender))

    for await value in responseReceiver.stream {
      return value
    }
    return false  // Channel closed without response
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
