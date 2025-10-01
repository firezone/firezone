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

  case setDnsError(String)

  case setDisabledResourcesError(String)

  case tunSetupFailed

  var localizedDescription: String {
    switch self {
    case .invalidSession(let session):
      let message = session == nil ? "Session is disconnected" : "Session is still connected"
      return message
    case .connlibConnectError(let error):
      return "connlib failed to start: \(error)"
    case .setDnsError(let error):
      return "failed to set new DNS serversn: \(error)"
    case .setDisabledResourcesError(let error):
      return "failed to set new disabled resources: \(error)"
    case .tunSetupFailed:
      return "TUN device setup failed after all retry attempts"
    }
  }
}

// Loosely inspired from WireGuardAdapter from WireGuardKit
/// Adapter using UniFFI polling-based event handling
class Adapter: @unchecked Sendable {
  // Configuration constants
  private static let tunSetupMaxAttempts = 10
  private static let tunSetupRetryDelayMilliseconds: UInt64 = 100  // 100ms

  private var sessionManager: SessionManager?
  /// Packet tunnel provider.
  private weak var packetTunnelProvider: PacketTunnelProvider?

  /// Network routes monitor.
  private var networkMonitor: NWPathMonitor?

  #if os(macOS)
    /// Used for finding system DNS resolvers on macOS when network conditions have changed.
    private let systemConfigurationResolvers = SystemConfigurationResolvers()
  #endif
  init(packetTunnelProvider: PacketTunnelProvider) {
    self.packetTunnelProvider = packetTunnelProvider
  }

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
        self.sessionManager?.sendCommand(.reset("primary network path changed"))
      }

      setSystemDefaultResolvers(path)

      lastPath = path
    }
  }

  /// Currently disabled resources
  private var internetResourceEnabled: Bool = false

  /// Cache of internet resource
  private var internetResource: Resource?

  /// Keep track of resources
  private var resourceListJSON: String?

  /// Trigger TUN device setup (called after network interface is configured)
  /// This should be called from onSetInterfaceConfig after applying network settings
  func setupTunDevice() {
    // Try to set TUN with retry logic like Android
    Task {
      var tunSetSuccessfully = false
      for attempt in 1...Self.tunSetupMaxAttempts {
        do {
          try await sessionManager?.setTunFromSearch()
          Log.log("TUN device set successfully on attempt \(attempt)")
          tunSetSuccessfully = true
          break
        } catch {
          Log.warning("TUN setup attempt \(attempt) failed: \(error)")
          if attempt < Self.tunSetupMaxAttempts {
            try await Task.sleep(nanoseconds: Self.tunSetupRetryDelayMilliseconds * 1_000_000)
          }
        }
      }

      if !tunSetSuccessfully {
        Log.error(AdapterError.tunSetupFailed)
      }
    }
  }

  func start(
    apiUrl: String,
    token: Token,
    deviceId: String,
    accountSlug: String,
    logFilter: String
  ) throws {
    Log.log("Adapter.start: Creating session manager for account: \(accountSlug)")

    // Create session manager with event handler
    let manager = SessionManager { [weak self] event in
      await self?.handleEvent(event)
    }

    self.sessionManager = manager

    // Start the session (async call)
    Task {
      do {
        try await manager.start(
          apiUrl: apiUrl,
          token: token,
          deviceId: deviceId,
          accountSlug: accountSlug,
          logFilter: logFilter
        )
      } catch {
        Log.error(error)
        throw error
      }
    }

    // Configure DNS and path monitoring
    startNetworkPathMonitoring()

    Log.log("Adapter.start: Session started successfully")
  }

  // Could happen abruptly if the process is killed.
  deinit {
    Log.log("Adapter.deinit")

    // Cancel network monitor
    networkMonitor?.cancel()
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

    // Stop session manager
    Task {
      await sessionManager?.stop()
    }
    sessionManager = nil

    // Stop network monitoring
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

  /// Reset the session and optionally update DNS resolvers
  func reset(reason: String, path: Network.NWPath? = nil) {
    sessionManager?.sendCommand(.reset(reason))

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

    internetResource = resources().filter { $0.isInternetResource() }.first

    var disablingResources: Set<String> = []
    if let internetResource = internetResource, !internetResourceEnabled {
      disablingResources.insert(internetResource.id)
    }

    guard let currentlyDisabled = try? JSONEncoder().encode(disablingResources),
      let toSet = String(data: currentlyDisabled, encoding: .utf8)
    else {
      fatalError("Should be able to encode 'disablingResources'")
    }

    sessionManager?.sendCommand(.setDisabledResources(toSet))
  }

  // MARK: - Event handling

  private func handleEvent(_ event: Event) async {
    switch event {
    case .tunInterfaceUpdated(
      let ipv4, let ipv6, let dns, let searchDomain, let ipv4Routes, let ipv6Routes):
      Log.log("Received TunInterfaceUpdated event")

      // Parse DNS servers from JSON
      let dnsAddresses: [String]
      if let data = dns.data(using: .utf8),
        let parsed = try? JSONDecoder().decode([String].self, from: data)
      {
        dnsAddresses = parsed
      } else {
        dnsAddresses = []
      }

      // Apply network settings directly
      guard let provider = packetTunnelProvider else {
        Log.error(AdapterError.invalidSession(nil))
        return
      }

      Log.log("Applying network settings...")

      // Just call onSetInterfaceConfig which handles everything
      // It creates NetworkSettings internally and applies them
      provider.onSetInterfaceConfig(
        tunnelAddressIPv4: ipv4,
        tunnelAddressIPv6: ipv6,
        searchDomain: searchDomain,
        dnsAddresses: dnsAddresses,
        routeListv4: ipv4Routes,
        routeListv6: ipv6Routes
      )

    case .resourcesUpdated(let resources):
      Log.log("Received ResourcesUpdated event with \(resources.count) bytes")

      // Store resource list and update disabled resources based on toggle state
      workQueue.async { [weak self] in
        guard let self = self else { return }

        self.resourceListJSON = resources
        self.resourcesUpdated()
      }

      guard let provider = packetTunnelProvider else {
        Log.error(AdapterError.invalidSession(nil))
        return
      }
      provider.onUpdateResources(resourceList: resources)

    case .disconnected(let error):
      let errorMessage = error.message()
      Log.info("Received Disconnected event: \(errorMessage)")

      guard let provider = packetTunnelProvider else {
        Log.error(AdapterError.invalidSession(nil))
        return
      }

      // If auth expired/is invalid, delete stored token and save the reason why so the GUI can act upon it.
      if error.isAuthenticationError() {
        // Delete stored token and save the reason for the GUI
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
      } else {
        Log.warning("Disconnected with error: \(errorMessage)")
      }

      provider.onDisconnect(error: errorMessage)
    }
  }

  private func startNetworkPathMonitoring() {
    networkMonitor = NWPathMonitor()
    networkMonitor?.pathUpdateHandler = self.pathUpdateHandler
    networkMonitor?.start(queue: workQueue)
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
    Log.log("Sending resolvers to connlib: \(jsonResolvers)")
    sessionManager?.sendCommand(.setDns(jsonResolvers))
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
