//
//  Adapter.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//
import Foundation
import NetworkExtension
import os.log

public enum AdapterError: Error {
  /// Failure to perform an operation in such state.
  case invalidState

  /// Failure to set network settings.
  case setNetworkSettings(Error)
}

/// Enum representing internal state of the `WireGuardAdapter`
private enum State {
  /// The tunnel is stopped
  case stopped

  /// The tunnel is up and running
  case started(_ handle: WrappedSession)

  /// The tunnel is temporarily shutdown due to device going offline
  case temporaryShutdown
}

// Loosely inspired from WireGuardAdapter from WireGuardKit
public class Adapter {
  private let logger = Logger(subsystem: "dev.firezone.firezone", category: "packet-tunnel")

  // Maintain a handle to the currently instantiated tunnel adapter 🤮
  public static var currentAdapter: Adapter?

  // Maintain a reference to the initialized callback handler
  public static var callbackHandler: CallbackHandler?

  // Latest applied NETunnelProviderNetworkSettings
  public var lastNetworkSettings: NEPacketTunnelNetworkSettings?

  /// Packet tunnel provider.
  private weak var packetTunnelProvider: NEPacketTunnelProvider?

  /// Network routes monitor.
  private var networkMonitor: NWPathMonitor?

  /// Private queue used to synchronize access to `WireGuardAdapter` members.
  private let workQueue = DispatchQueue(label: "FirezoneAdapterWorkQueue")

  /// Adapter state.
  private var state: State = .stopped

  public init(with packetTunnelProvider: NEPacketTunnelProvider) {
    self.packetTunnelProvider = packetTunnelProvider

    // There must be a better way than making this a static class var...
    Self.currentAdapter = self
    Self.callbackHandler = CallbackHandler(adapter: self)
  }

  deinit {
    // Remove static var reference
    Self.currentAdapter = nil

    // Cancel network monitor
    networkMonitor?.cancel()

    // Shutdown the tunnel
    if case .started(let wrappedSession) = self.state {
      self.logger.log(level: .debug, "\(#function)")
      wrappedSession.disconnect()
    }
  }

  /// Start the tunnel tunnel.
  /// - Parameters:
  ///   - completionHandler: completion handler.
  public func start(completionHandler: @escaping (AdapterError?) -> Void) throws {
    workQueue.async {
      guard case .stopped = self.state else {
        completionHandler(.invalidState)
        return
      }

      let networkMonitor = NWPathMonitor()
      networkMonitor.pathUpdateHandler = { [weak self] path in
        self?.didReceivePathUpdate(path: path)
      }
      networkMonitor.start(queue: self.workQueue)

      do {
        try self.setNetworkSettings(self.generateNetworkSettings(ipv4Routes: [], ipv6Routes: []))

        self.state = .started(
          WrappedSession.connect(
            "http://localhost:4568",
            "test-token",
            Self.callbackHandler!
          )
        )
        self.networkMonitor = networkMonitor
        completionHandler(nil)
      } catch let error as AdapterError {
        networkMonitor.cancel()
        completionHandler(error)
      } catch {
        fatalError()
      }
    }
  }

  public func stop(completionHandler: @escaping (AdapterError?) -> Void) {
    workQueue.async {
      switch self.state {
      case .started(let wrappedSession):
        wrappedSession.disconnect()
      case .temporaryShutdown:
        break

      case .stopped:
        completionHandler(.invalidState)
        return
      }

      self.networkMonitor?.cancel()
      self.networkMonitor = nil

      self.state = .stopped

      completionHandler(nil)
    }
  }

  public func generateNetworkSettings(
    addresses4: [String] = ["100.100.111.2"], addresses6: [String] = ["fd00:0222:2011:1111::2"],
    ipv4Routes: [NEIPv4Route], ipv6Routes: [NEIPv6Route]
  )
    -> NEPacketTunnelNetworkSettings
  {
    // The destination IP that connlib will assign our DNS proxy to.
    let dnsSentinel = "1.1.1.1"

    // We can probably do better than this; see https://www.rfc-editor.org/info/rfc4821
    // But stick with something simple for now. 1280 is the minimum that will work for IPv6.
    let mtu = 1280

    // TODO: replace these with IPs returned from the connect call to portal
    let subnetmask = "255.192.0.0"
    let networkPrefixLength = NSNumber(value: 64)

    /* iOS requires a tunnel endpoint, whereas in WireGuard it's valid for
       * a tunnel to have no endpoint, or for there to be many endpoints, in
       * which case, displaying a single one in settings doesn't really
       * make sense. So, we fill it in with this placeholder, which is not
       * a valid IP address that will actually route over the Internet.
       */
    let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let dnsSettings = NEDNSSettings(servers: [dnsSentinel])

    // All DNS queries must first go through the tunnel's DNS
    dnsSettings.matchDomains = [""]
    networkSettings.dnsSettings = dnsSettings
    networkSettings.mtu = NSNumber(value: mtu)

    let ipv4Settings = NEIPv4Settings(
      addresses: addresses4,
      subnetMasks: [subnetmask])
    ipv4Settings.includedRoutes = ipv4Routes
    networkSettings.ipv4Settings = ipv4Settings

    let ipv6Settings = NEIPv6Settings(
      addresses: addresses6,
      networkPrefixLengths: [networkPrefixLength])
    ipv6Settings.includedRoutes = ipv6Routes
    networkSettings.ipv6Settings = ipv6Settings

    return networkSettings
  }

  public func setNetworkSettings(_ networkSettings: NEPacketTunnelNetworkSettings) throws {
    var systemError: Error?
    let condition = NSCondition()

    // Activate the condition
    condition.lock()
    defer { condition.unlock() }

    self.packetTunnelProvider?.setTunnelNetworkSettings(networkSettings) { error in
      systemError = error
      condition.signal()
    }

    // Packet tunnel's `setTunnelNetworkSettings` times out in certain
    // scenarios & never calls the given callback.
    let setTunnelNetworkSettingsTimeout: TimeInterval = 5  // seconds

    if condition.wait(until: Date().addingTimeInterval(setTunnelNetworkSettingsTimeout)) {
      if let systemError = systemError {
        throw AdapterError.setNetworkSettings(systemError)
      }
    }

    // Save the latest applied network settings if there was no error.
    if systemError != nil {
      self.lastNetworkSettings = networkSettings
    }
  }

  /// Update runtime configuration.
  /// - Parameters:
  ///   - ipv4Routes: IPv4 routes to send through the tunnel.
  ///   - ipv6Routes: IPv6 routes to send through the tunnel.
  ///   - completionHandler: completion handler.
  public func update(
    ipv4Routes: [NEIPv4Route], ipv6Routes: [NEIPv6Route],
    completionHandler: @escaping (AdapterError?) -> Void
  ) {
    workQueue.async {
      if case .stopped = self.state {
        completionHandler(.invalidState)
        return
      }

      // Tell the system that the tunnel is going to reconnect using new WireGuard
      // configuration.
      // This will broadcast the `NEVPNStatusDidChange` notification to the GUI process.
      self.packetTunnelProvider?.reasserting = true
      defer {
        self.packetTunnelProvider?.reasserting = false
      }

      do {
        try self.setNetworkSettings(
          self.generateNetworkSettings(ipv4Routes: ipv4Routes, ipv6Routes: ipv6Routes))

        switch self.state {
        case .started(let wrappedSession):
          self.state = .started(wrappedSession)

        case .temporaryShutdown:
          self.state = .temporaryShutdown

        case .stopped:
          fatalError()
        }

        completionHandler(nil)
      } catch let error as AdapterError {
        completionHandler(error)
      } catch {
        fatalError()
      }
    }
  }

  private func didReceivePathUpdate(path: Network.NWPath) {
    #if os(macOS)
      if case .started(let wrappedSession) = self.state {
        wrappedSession.bumpSockets()
      }
    #elseif os(iOS)
      switch self.state {
      case .started(let wrappedSession):
        if path.status == .satisfied {
          wrappedSession.disableSomeRoamingForBrokenMobileSemantics()
          wrappedSession.bumpSockets()
        } else {
          //self.logger.log(.debug, "Connectivity offline, pausing backend.")
          self.state = .temporaryShutdown
          wrappedSession.disconnect()
        }

      case .temporaryShutdown:
        guard path.status == .satisfied else { return }

        self.logger.log(level: .debug, "Connectivity online, resuming backend.")

        do {
          try self.setNetworkSettings(self.lastNetworkSettings!)

          self.state = .started(
            try WrappedSession.connect("http://localhost:4568", "test-token", Self.callbackHandler!)
          )
        } catch {
          self.logger.log(level: .debug, "Failed to restart backend: \(error.localizedDescription)")
        }

      case .stopped:
        // no-op
        break
      }
    #else
      #error("Unsupported")
    #endif
  }
}
