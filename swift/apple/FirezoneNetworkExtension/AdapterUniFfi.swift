//
//  AdapterUniFfi.swift
//  FirezoneNetworkExtension
//
//  Adapter implementation using UniFFI polling pattern instead of callbacks
//

import CryptoKit
import FirezoneKit
import Foundation
import Network
import NetworkExtension
import OSLog

enum AdapterError: LocalizedError {
  case invalidSession
  case connlibConnectError(String)
  case setDnsError(String)

  var errorDescription: String? {
    switch self {
    case .invalidSession:
      return "Session is invalid or not initialized"
    case .connlibConnectError(let error):
      return "Failed to connect: \(error)"
    case .setDnsError(let error):
      return "Failed to set DNS: \(error)"
    }
  }
}

/// Adapter using UniFFI polling-based event handling
class AdapterUniFfi: @unchecked Sendable {
  // Configuration constants
  private static let tunSetupMaxAttempts = 10
  private static let tunSetupRetryDelayMilliseconds: UInt64 = 100  // 100ms
  private static let eventPollingLogInterval = 100  // Log every N poll attempts

  private var session: Session?
  private var eventTask: Task<Void, Never>?
  private weak var packetTunnelProvider: PacketTunnelProvider?

  // TUN setup completion tracking
  private var tunSetupCompletion: ((Bool) -> Void)?

  // Network monitoring components
  private var networkMonitor: NWPathMonitor?
  private var lastPath: Network.NWPath?
  private let workQueue = DispatchQueue(label: "AdapterUniFfiWorkQueue")

  // Internet resource toggle state
  private var internetResourceEnabled: Bool = false
  private var internetResource: Resource?
  private var resourceListJSON: String?

  init(packetTunnelProvider: PacketTunnelProvider) {
    self.packetTunnelProvider = packetTunnelProvider
  }

  /// Set a completion handler to be called when TUN device setup completes
  func onTunSetupComplete(_ completion: @escaping (Bool) -> Void) {
    self.tunSetupCompletion = completion
  }

  /// Trigger TUN device setup (called after network interface is configured)
  func setupTunDevice() {
    guard let session = session else {
      Log.error(AdapterError.invalidSession)
      tunSetupCompletion?(false)
      tunSetupCompletion = nil
      return
    }

    // Try to set TUN with retry logic like Android
    Task {
      var tunSetSuccessfully = false
      for attempt in 1...Self.tunSetupMaxAttempts {
        do {
          try session.setTunFromSearch()
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
        Log.error(AdapterError.invalidSession)
      }

      // Call the completion handler to signal TUN setup is done
      if let completion = self.tunSetupCompletion {
        Log.log("Calling TUN setup completion handler with success: \(tunSetSuccessfully)")
        completion(tunSetSuccessfully)
        self.tunSetupCompletion = nil  // Clear it after calling
      }
    }
  }

  func start(
    apiUrl: String,
    token: String,
    deviceId: String,
    accountSlug: String,
    logFilter: String
  ) throws {
    Log.log("AdapterUniFfi.start: Creating session for account: \(accountSlug)")

    // Get device metadata
    let deviceName = DeviceMetadata.getDeviceName()
    let osVersion = DeviceMetadata.getOSVersion()
    let deviceInfo = try JSONEncoder().encode(DeviceMetadata.deviceInfo())
    let deviceInfoStr = String(data: deviceInfo, encoding: .utf8) ?? "{}"
    let logDir = SharedAccess.connlibLogFolderURL?.path ?? "/tmp/firezone"

    // Create the session
    do {
      session = try Session.newIos(
        apiUrl: apiUrl,
        token: token,
        deviceId: deviceId,
        accountSlug: accountSlug,
        deviceName: deviceName,
        osVersion: osVersion,
        logDir: logDir,
        logFilter: logFilter,
        deviceInfo: deviceInfoStr
      )
    } catch {
      Log.error(error)
      throw AdapterError.connlibConnectError(String(describing: error))
    }

    // Configure DNS and path monitoring
    startNetworkPathMonitoring()

    // Start the event polling loop
    startEventPolling()

    Log.log("AdapterUniFfi.start: Session started successfully")
  }

  private func startEventPolling() {
    if let existingTask = eventTask {
      existingTask.cancel()
    }

    eventTask = Task {
      guard let session = session else {
        Log.log("No session available for event polling")
        return
      }

      Log.log("Starting event polling loop")
      var eventCount = 0
      var pollAttempts = 0

      while !Task.isCancelled {
        pollAttempts += 1

        do {
          // Poll for next event
          if let event = try await session.nextEvent() {
            eventCount += 1
            Log.log("Event received: \(String(describing: event))")
            await handleEvent(event)
          }
          // If no event, continue polling immediately
        } catch {
          Log.error(error)
          // On error, stop polling gracefully like Android does
          break
        }

        // Log periodically to show we're still active
        if pollAttempts % Self.eventPollingLogInterval == 0 {
          Log.log("Event polling active: \(eventCount) events processed")
        }
      }

      Log.log("Event polling ended after \(eventCount) events")
    }
  }

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
        Log.error(AdapterError.invalidSession)
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

      // Store resource list and immediately apply toggle state
      workQueue.async { [weak self] in
        guard let self = self else { return }

        let isFirstResourceUpdate = self.resourceListJSON == nil
        self.resourceListJSON = resources

        // Always update disabled resources to ensure backend knows current toggle state
        self.updateDisabledResourcesFromToggle()

        if isFirstResourceUpdate {
          Log.info("First resource update received, applied initial toggle state")
        }
      }

      guard let provider = packetTunnelProvider else {
        Log.error(AdapterError.invalidSession)
        return
      }
      provider.onUpdateResources(resourceList: resources)

    case .disconnected(let error):
      let errorMessage = error.message()
      Log.info("Received Disconnected event: \(errorMessage)")

      guard let provider = packetTunnelProvider else {
        Log.error(AdapterError.invalidSession)
        return
      }

      // On auth failure, handle properly like the old Adapter did
      if error.isAuthenticationError() {
        // Clear cached resource data, but do NOT reset internetResourceEnabled
        // The user's preference should persist across reconnects
        internetResource = nil
        resourceListJSON = nil
        Log.info("Auth error: Clearing token and saving stop reason")

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

  func stop() {
    Log.log("AdapterUniFfi.stop")

    // Cancel event polling
    eventTask?.cancel()
    eventTask = nil

    // Stop network monitoring
    networkMonitor?.cancel()
    networkMonitor = nil

    // Disconnect the session
    if let session = session {
      do {
        try session.disconnect()
      } catch {
        Log.error(error)
      }
    }

    session = nil
  }

  func setDns(servers: String) throws {
    guard let session = session else {
      throw AdapterError.invalidSession
    }

    do {
      try session.setDns(dnsServers: servers)
    } catch {
      throw AdapterError.setDnsError(String(describing: error))
    }
  }

  func reset(reason: String) {
    guard let session = session else {
      Log.log("Cannot reset: no session")
      return
    }

    session.reset(reason: reason)
  }

  func setDisabledResources(_ resources: String) throws {
    guard let session = session else {
      throw AdapterError.invalidSession
    }

    try session.setDisabledResources(disabledResources: resources)
  }

  // MARK: - Internet Resource Toggle Feature

  func setInternetResourceEnabled(_ enabled: Bool) throws {
    Log.info("setInternetResourceEnabled called with: \(enabled)")
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.internetResourceEnabled = enabled
      Log.info("Internet resource enabled state updated to: \(enabled)")

      // Update disabled resources based on current resource list
      self.updateDisabledResourcesFromToggle()
    }
  }

  private func updateDisabledResourcesFromToggle() {
    Log.info(
      "updateDisabledResourcesFromToggle called, internetResourceEnabled: \(internetResourceEnabled)"
    )
    // Find internet resource from current resource list
    if let resourceList = resourceListJSON,
      let data = resourceList.data(using: .utf8)
    {
      do {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let resources = try decoder.decode([Resource].self, from: data)

        // Find the internet resource
        internetResource = resources.first { $0.isInternetResource() }

        if let internetResource = internetResource {
          Log.info("Found internet resource with ID: \(internetResource.id)")
        } else {
          Log.info("No internet resource found in resource list")
        }

        // Build disabled resources set
        var disabledResourceIds: Set<String> = []
        if let internetResource = internetResource, !internetResourceEnabled {
          disabledResourceIds.insert(internetResource.id)
          Log.info("Internet resource is DISABLED, adding ID to disabled set")
        } else {
          Log.info("Internet resource is ENABLED or not found, disabled set is empty")
        }

        // Convert to JSON and send to session
        let jsonData = try JSONSerialization.data(withJSONObject: Array(disabledResourceIds))
        if let jsonString = String(data: jsonData, encoding: .utf8) {
          Log.info("Sending disabled resources to session: \(jsonString)")
          try session?.setDisabledResources(disabledResources: jsonString)
        }
      } catch {
        Log.error(error)
      }
    } else {
      Log.warning("No resource list available to update disabled resources")
    }
  }

  // MARK: - Network Path Monitoring

  private func startNetworkPathMonitoring() {
    networkMonitor = NWPathMonitor()

    networkMonitor?.pathUpdateHandler = { [weak self] path in
      self?.workQueue.async {
        self?.handleNetworkPathUpdate(path: path)
      }
    }

    networkMonitor?.start(queue: workQueue)
  }

  private func handleNetworkPathUpdate(path: Network.NWPath) {
    // UI state management with reasserting
    if path.status == .unsatisfied {
      // Check if we need to set reasserting, avoids OS log spam
      if packetTunnelProvider?.reasserting == false {
        packetTunnelProvider?.reasserting = true
      }
    } else {
      if packetTunnelProvider?.reasserting == true {
        packetTunnelProvider?.reasserting = false
      }
    }

    // Check for meaningful connectivity changes for DNS updates
    guard path.connectivityDifferentFrom(path: lastPath) else {
      return
    }

    Log.log("Network path changed - Status: \(path.status)")
    setSystemDefaultResolvers(path)

    // Reset connlib network state for meaningful changes
    if let session = session {
      session.reset(reason: "primary network path changed")
    }

    lastPath = path
  }

  // MARK: - DNS Resolution Methods

  private func setSystemDefaultResolvers(_ path: Network.NWPath) {
    // Step 1: Get system default resolvers
    #if os(macOS)
      let resolvers = getSystemResolversViaSysConfig(path: path)
    #elseif os(iOS)
      let resolvers = getSystemResolversViaBindResolvers()
    #endif

    // Step 2: Validate and strip scope suffixes
    var parsedResolvers: [String] = []

    for stringAddress in resolvers {
      // Simple IP validation - more robust than old implementation
      if isValidIPAddress(stringAddress) && !isWithinSentinelRange(stringAddress) {
        parsedResolvers.append(stringAddress)
      }
    }

    // Step 3: JSON encode for connlib
    guard !parsedResolvers.isEmpty else {
      Log.log("WARNING: No valid DNS resolvers found")
      return
    }

    do {
      let jsonData = try JSONSerialization.data(withJSONObject: parsedResolvers)
      let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

      try session?.setDns(dnsServers: jsonString)
    } catch {
      Log.error(error)
    }
  }

  #if os(macOS)
    private func getSystemResolversViaSysConfig(path: Network.NWPath) -> [String] {
      let systemConfigResolvers = SystemConfigurationResolvers()
      let resolvers = systemConfigResolvers.getDefaultDNSServers(
        interfaceName: path.availableInterfaces.first?.name)

      return resolvers
    }
  #endif

  #if os(iOS)
    private func getSystemResolversViaBindResolvers() -> [String] {
      // iOS approach using BindResolvers
      let resolvers = BindResolvers.getServers()

      return resolvers
    }
  #endif

  // Helper functions for DNS validation
  private func isValidIPAddress(_ address: String) -> Bool {
    // Simple validation - try to create IP address objects
    return IPv4Address(address) != nil || IPv6Address(address) != nil
  }

  private func isWithinSentinelRange(_ address: String) -> Bool {
    // Basic sentinel range check - could be more sophisticated
    // For now, avoid obvious sentinel ranges
    if let ipv4 = IPv4Address(address) {
      // Avoid common test/sentinel ranges
      // rawValue is Data type, need to extract bytes
      let addrBytes = ipv4.rawValue
      guard addrBytes.count == 4 else { return false }
      let firstByte = addrBytes[0]
      return firstByte == 100  // 100.x.x.x (RFC 6598)
        || firstByte == 127  // 127.x.x.x (loopback)
    }

    if IPv6Address(address) != nil {
      // Basic IPv6 sentinel avoidance - could be enhanced
      return address.hasPrefix("::1") || address.hasPrefix("fe80::")
    }

    return false
  }

  /// Reset the session and optionally update DNS resolvers
  func reset(reason: String, path: Network.NWPath? = nil) {
    session?.reset(reason: reason)

    if let path = path ?? lastPath {
      setSystemDefaultResolvers(path)
    }
  }

  /// Get the current resource list only if it has changed from the provided hash
  func getResourcesIfVersionDifferentFrom(
    hash: Data, completionHandler: @escaping (String?) -> Void
  ) {
    // This is async to avoid blocking the main UI thread
    workQueue.async { [weak self] in
      guard let self = self else { return }

      let currentResourceData = Data((self.resourceListJSON ?? "").utf8)
      let currentHash = Data(SHA256.hash(data: currentResourceData))

      if hash == currentHash {
        // Resources haven't changed
        completionHandler(nil)
      } else {
        // Resources have changed, return them
        completionHandler(self.resourceListJSON)
      }
    }
  }

}

extension Network.NWPath {
  func connectivityDifferentFrom(path: Network.NWPath?) -> Bool {
    guard let path = path else { return true }

    // We define a path as different if key connectivity properties change
    return path.supportsIPv4 != self.supportsIPv4 || path.supportsIPv6 != self.supportsIPv6
      || path.supportsDNS != self.supportsDNS || path.status != self.status
      || path.availableInterfaces.first != self.availableInterfaces.first
      || path.gateways != self.gateways
  }
}
