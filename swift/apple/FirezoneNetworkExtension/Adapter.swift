//  Adapter.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//
import FirezoneKit
import Foundation
import NetworkExtension
import OSLog

#if os(iOS)
  import UIKit.UIDevice
#endif

public enum AdapterError: Error {
  /// Failure to perform an operation in such state.
  case invalidState

  /// connlib failed to start
  case connlibConnectError(Error)

  /// connlib fatal error
  case connlibFatalError(String)

  /// No network settings were provided
  case noNetworkSettings

  /// Failure to set network settings.
  case setNetworkSettings(Error)

  /// stop() called before the tunnel became ready
  case stoppedByRequestWhileStarting
}

/// Enum representing internal state of the  adapter
private enum AdapterState: CustomStringConvertible {
  case startingTunnel(session: WrappedSession, onStarted: Adapter.StartTunnelCompletionHandler?)
  case tunnelReady(session: WrappedSession)
  case stoppingTunnel(session: WrappedSession, onStopped: Adapter.StopTunnelCompletionHandler?)
  case stoppedTunnel
  case stoppingTunnelTemporarily(
    session: WrappedSession, onStopped: Adapter.StopTunnelCompletionHandler?)
  case stoppedTunnelTemporarily

  var description: String {
    switch self {
    case .startingTunnel: return "startingTunnel"
    case .tunnelReady: return "tunnelReady"
    case .stoppingTunnel: return "stoppingTunnel"
    case .stoppedTunnel: return "stoppedTunnel"
    case .stoppingTunnelTemporarily: return "stoppingTunnelTemporarily"
    case .stoppedTunnelTemporarily: return "stoppedTunnelTemporarily"
    }
  }
}

// Loosely inspired from WireGuardAdapter from WireGuardKit
class Adapter {

  typealias StartTunnelCompletionHandler = ((AdapterError?) -> Void)
  typealias StopTunnelCompletionHandler = (() -> Void)

  private let logger = Logger.make(category: "packet-tunnel")

  private var callbackHandler: CallbackHandler

  /// Network settings
  private var networkSettings: NetworkSettings?

  /// Packet tunnel provider.
  private weak var packetTunnelProvider: PacketTunnelProvider?

  /// Network routes monitor.
  private var networkMonitor: NWPathMonitor?

  /// Private queue used to synchronize access to `WireGuardAdapter` members.
  private let workQueue = DispatchQueue(label: "FirezoneAdapterWorkQueue")

  /// Adapter state.
  private var state: AdapterState {
    didSet {
      logger.log("Adapter state changed to: \(self.state, privacy: .public)")
    }
  }

  /// Keep track of resources
  private var displayableResources = DisplayableResources()

  /// Starting parameters
  private var controlPlaneURLString: String
  private var token: String

  private let logFilter: String
  private let connlibLogFolderPath: String
  private let firezoneIdFileURL: URL

  init(
    controlPlaneURLString: String, token: String,
    logFilter: String, packetTunnelProvider: PacketTunnelProvider
  ) {
    self.controlPlaneURLString = controlPlaneURLString
    self.token = token
    self.packetTunnelProvider = packetTunnelProvider
    self.callbackHandler = CallbackHandler()
    self.state = .stoppedTunnel
    self.logFilter = logFilter
    self.connlibLogFolderPath = SharedAccess.connlibLogFolderURL?.path ?? ""
    self.firezoneIdFileURL = SharedAccess.baseFolderURL.appendingPathComponent("firezone-id")
  }

  deinit {
    self.logger.log("Adapter.deinit")
    // Cancel network monitor
    networkMonitor?.cancel()

    // Shutdown the tunnel
    if case .tunnelReady(let session) = self.state {
      logger.log("Adapter.deinit: Shutting down connlib")
      session.disconnect()
    }
  }

  /// Start the tunnel tunnel.
  /// - Parameters:
  ///   - completionHandler: completion handler.
  public func start(completionHandler: @escaping (AdapterError?) -> Void) throws {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.start")
      guard case .stoppedTunnel = self.state else {
        packetTunnelProvider?.handleTunnelShutdown(
          dueTo: .invalidAdapterState,
          errorMessage: "Adapter is in invalid state")
        completionHandler(.invalidState)
        return
      }

      self.callbackHandler.delegate = self

      if self.connlibLogFolderPath.isEmpty {
        self.logger.error("Cannot get shared log folder for connlib")
      }

      self.logger.log("Adapter.start: Starting connlib")
      do {
        // We can only get the system's default resolvers before connlib starts, and then they'll
        // be overwritten by the ones from connlib. So cache them here for getSystemDefaultResolvers
        // to retrieve them later.
        self.callbackHandler.setSystemDefaultResolvers(
          resolvers: Resolv().getservers().map(Resolv.getnameinfo)
        )
        self.state = .startingTunnel(
          session: try WrappedSession.connect(
            self.controlPlaneURLString,
            self.token,
            self.getOrCreateFirezoneId(from: self.firezoneIdFileURL),
            self.getDeviceName(),
            self.getOSVersion(),
            self.connlibLogFolderPath,
            self.logFilter,
            self.callbackHandler
          ),
          onStarted: completionHandler
        )
      } catch let error {
        self.logger.error("Adapter.start: Error: \(error, privacy: .public)")
        packetTunnelProvider?.handleTunnelShutdown(
          dueTo: .connlibConnectFailure,
          errorMessage: error.localizedDescription)
        self.state = .stoppedTunnel
        completionHandler(AdapterError.connlibConnectError(error))
      }
    }
  }

  /// Stop the tunnel
  public func stop(reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.stop")

      packetTunnelProvider?.handleTunnelShutdown(
        dueTo: .stopped(reason),
        errorMessage: "\(reason)")

      switch self.state {
      case .stoppedTunnel, .stoppingTunnel:
        break
      case .tunnelReady(let session):
        self.logger.log("Adapter.stop: Shutting down connlib")
        self.state = .stoppingTunnel(session: session, onStopped: completionHandler)
        session.disconnect()
      case .startingTunnel(let session, let onStarted):
        self.logger.log("Adapter.stop: Shutting down connlib before tunnel ready")
        self.state = .stoppingTunnel(
          session: session,
          onStopped: {
            onStarted?(AdapterError.stoppedByRequestWhileStarting)
            completionHandler()
          })
        session.disconnect()
      case .stoppingTunnelTemporarily(let session, let onStopped):
        self.state = .stoppingTunnel(
          session: session,
          onStopped: {
            onStopped?()
            completionHandler()
          })
      case .stoppedTunnelTemporarily:
        self.state = .stoppedTunnel
        completionHandler()
      }

      self.networkMonitor?.cancel()
      self.networkMonitor = nil
    }
  }

  /// Get the current set of resources in the completionHandler.
  /// If unchanged since referenceVersionString, call completionHandler(nil).
  public func getDisplayableResourcesIfVersionDifferentFrom(
    referenceVersionString: String, completionHandler: @escaping (DisplayableResources?) -> Void
  ) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      if referenceVersionString == self.displayableResources.versionString {
        completionHandler(nil)
      } else {
        completionHandler(self.displayableResources)
      }
    }
  }
}

// MARK: Device metadata

extension Adapter {
  func getDeviceName() -> String? {
    // Returns a generic device name on iOS 16 and higher
    // See https://github.com/firezone/firezone/issues/3034
    #if os(iOS)
      return UIDevice.current.name
    #else
      // Fallback to connlib's gethostname()
      return nil
    #endif
  }

  func getOSVersion() -> String? {
    // Returns the OS version
    // See https://github.com/firezone/firezone/issues/3034
    #if os(iOS)
      return UIDevice.current.systemVersion
    #else
      // Fallback to connlib's osinfo
      return nil
    #endif
  }

  // Returns the Firezone ID as cached by the application or generates and persists a new one
  // if that doesn't exist. The Firezone ID is a UUIDv4 that is used to dedup this device
  // for upsert and identification in the admin portal.
  func getOrCreateFirezoneId(from fileURL: URL) -> String {
    do {
      return try String(contentsOf: fileURL, encoding: .utf8)
    } catch {
      // Handle the error if the file doesn't exist or isn't readable
      // Recreate the file, save a new UUIDv4, and return it
      let newUUIDString = UUID().uuidString

      do {
        try newUUIDString.write(to: fileURL, atomically: true, encoding: .utf8)
      } catch {
        self.logger.error(
          "Adapter.getOrCreateFirezoneId: Could not save \(fileURL, privacy: .public)! Error: \(error, privacy: .public)"
        )
      }

      return newUUIDString
    }
  }
}

// MARK: Responding to path updates

extension Adapter {
  private func resetToSystemDNS() {
    // Setting this to anything but an empty string will populate /etc/resolv.conf with
    // the default interface's DNS servers, which we read later from connlib
    // during tunnel setup.
    self.networkSettings?.setMatchDomains(["firezone-fd0020211111"])
    self.networkSettings?.apply(
      on: self.packetTunnelProvider,
      logger: self.logger,
      completionHandler: { _ in
        // We can only get the system's default resolvers before connlib starts, and then they'll
        // be overwritten by the ones from connlib. So cache them here for getSystemDefaultResolvers
        // to retrieve them later.
        self.callbackHandler.setSystemDefaultResolvers(
          resolvers: Resolv().getservers().map(Resolv.getnameinfo)
        )
      })
  }

  private func beginPathMonitoring() {
    self.logger.log("Beginning path monitoring")
    let networkMonitor = NWPathMonitor()
    networkMonitor.pathUpdateHandler = { [weak self] path in
      self?.didReceivePathUpdate(path: path)
    }
    networkMonitor.start(queue: self.workQueue)
  }

  private func didReceivePathUpdate(path: Network.NWPath) {
    // Will be invoked in the workQueue by the path monitor
    switch self.state {

    case .startingTunnel(let session, let onStarted):
      if path.status != .satisfied {
        self.logger.log("Adapter.didReceivePathUpdate: Offline. Shutting down connlib.")
        onStarted?(nil)
        resetToSystemDNS()
        self.packetTunnelProvider?.reasserting = true
        self.state = .stoppingTunnelTemporarily(session: session, onStopped: nil)
        session.disconnect()
      }

    case .tunnelReady(let session):
      if path.status != .satisfied {
        self.logger.log("Adapter.didReceivePathUpdate: Offline. Shutting down connlib.")
        resetToSystemDNS()
        self.packetTunnelProvider?.reasserting = true
        self.state = .stoppingTunnelTemporarily(session: session, onStopped: nil)
        session.disconnect()
      }

    case .stoppingTunnelTemporarily:
      break

    case .stoppedTunnelTemporarily:
      guard path.status == .satisfied else { return }

      self.logger.log("Adapter.didReceivePathUpdate: Back online. Starting connlib.")

      do {
        self.state = .startingTunnel(
          session: try WrappedSession.connect(
            controlPlaneURLString,
            token,
            self.getOrCreateFirezoneId(from: self.firezoneIdFileURL),
            self.getDeviceName(),
            self.getOSVersion(),
            self.connlibLogFolderPath,
            self.logFilter,
            self.callbackHandler
          ),
          onStarted: { error in
            if let error = error {
              self.logger.error(
                "Adapter.didReceivePathUpdate: Error starting connlib: \(error, privacy: .public)")
              self.packetTunnelProvider?.cancelTunnelWithError(error)
            } else {
              self.packetTunnelProvider?.reasserting = false
            }
          }
        )
      } catch let error as AdapterError {
        self.logger.error("Adapter.didReceivePathUpdate: Error: \(error, privacy: .public)")
      } catch {
        self.logger.error(
          "Adapter.didReceivePathUpdate: Unknown error: \(error, privacy: .public) (fatal)")
      }

    case .stoppingTunnel, .stoppedTunnel:
      // no-op
      break
    }
  }
}

// MARK: Implementing CallbackHandlerDelegate

extension Adapter: CallbackHandlerDelegate {
  public func onSetInterfaceConfig(
    tunnelAddressIPv4: String, tunnelAddressIPv6: String, dnsAddress: String
  ) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onSetInterfaceConfig")

      switch self.state {
      case .startingTunnel:
        self.networkSettings = NetworkSettings(
          tunnelAddressIPv4: tunnelAddressIPv4, tunnelAddressIPv6: tunnelAddressIPv6,
          dnsAddress: dnsAddress)
      case .tunnelReady:
        if let networkSettings = self.networkSettings {
          networkSettings.apply(
            on: packetTunnelProvider,
            logger: self.logger,
            completionHandler: nil
          )
        }

      case .stoppingTunnel, .stoppedTunnel, .stoppingTunnelTemporarily, .stoppedTunnelTemporarily:
        // This is not expected to happen
        break
      }
    }
  }

  public func onTunnelReady() {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onTunnelReady")
      guard case .startingTunnel(let session, let onStarted) = self.state else {
        self.logger.error(
          "Adapter.onTunnelReady: Unexpected state: \(self.state, privacy: .public)")
        return
      }
      guard let networkSettings = self.networkSettings else {
        self.logger.error("Adapter.onTunnelReady: No network settings")
        return
      }

      // Connlib's up, set it as the default DNS
      networkSettings.setMatchDomains([""])
      networkSettings.apply(on: packetTunnelProvider, logger: self.logger) { error in
        if let error = error {
          self.packetTunnelProvider?.handleTunnelShutdown(
            dueTo: .networkSettingsApplyFailure,
            errorMessage: error.localizedDescription)
          onStarted?(AdapterError.setNetworkSettings(error))
          self.state = .stoppedTunnel
        } else {
          onStarted?(nil)
          self.state = .tunnelReady(session: session)
          self.beginPathMonitoring()
        }
      }
    }
  }

  public func onAddRoute(_ route: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onAddRoute(\(route, privacy: .public))")
      guard let networkSettings = self.networkSettings else {
        self.logger.error("Adapter.onAddRoute: No network settings")
        return
      }

      networkSettings.addRoute(route)
      if case .tunnelReady = self.state {
        networkSettings.apply(on: packetTunnelProvider, logger: self.logger, completionHandler: nil)
      }
    }
  }

  public func onRemoveRoute(_ route: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onRemoveRoute(\(route, privacy: .public))")
      guard let networkSettings = self.networkSettings else {
        self.logger.error("Adapter.onRemoveRoute: No network settings")
        return
      }
      networkSettings.removeRoute(route)
      if case .tunnelReady = self.state {
        networkSettings.apply(on: packetTunnelProvider, logger: self.logger, completionHandler: nil)
      }
    }
  }

  public func onUpdateResources(resourceList: String) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onUpdateResources")
      let jsonString = resourceList
      guard let jsonData = jsonString.data(using: .utf8) else {
        return
      }
      guard let networkResources = try? JSONDecoder().decode([NetworkResource].self, from: jsonData)
      else {
        return
      }

      // Note down the resources
      self.displayableResources.update(resources: networkResources.map { $0.displayableResource })

      // Update DNS in case resource domains is changing
      guard let networkSettings = self.networkSettings else {
        self.logger.error("Adapter.onUpdateResources: No network settings")
        return
      }
      let updatedResourceDomains = networkResources.compactMap { $0.resourceLocation.domain }
      networkSettings.setResourceDomains(updatedResourceDomains)
      if case .tunnelReady = self.state {
        networkSettings.apply(on: packetTunnelProvider, logger: self.logger, completionHandler: nil)
      }
    }
  }

  public func onDisconnect(error: String?) {
    workQueue.async { [weak self] in
      guard let self = self else { return }

      self.logger.log("Adapter.onDisconnect: \(error ?? "No error", privacy: .public)")
      if let errorMessage = error {
        self.logger.error(
          "Connlib disconnected with unrecoverable error: \(errorMessage, privacy: .public)")
        switch self.state {
        case .stoppingTunnel(session: _, let onStopped):
          onStopped?()
          self.state = .stoppedTunnel
        case .stoppingTunnelTemporarily(session: _, let onStopped):
          onStopped?()
          self.state = .stoppedTunnel
        case .stoppedTunnel:
          // This should not happen
          break
        case .stoppedTunnelTemporarily:
          self.state = .stoppedTunnel
        default:
          packetTunnelProvider?.handleTunnelShutdown(
            dueTo: .connlibDisconnected,
            errorMessage: errorMessage)
          self.packetTunnelProvider?.cancelTunnelWithError(
            AdapterError.connlibFatalError(errorMessage))
          self.state = .stoppedTunnel
        }
      } else {
        self.logger.log("Connlib disconnected")
        switch self.state {
        case .stoppingTunnel(session: _, let onStopped):
          onStopped?()
          self.state = .stoppedTunnel
        case .stoppingTunnelTemporarily(session: _, let onStopped):
          onStopped?()
          self.state = .stoppedTunnelTemporarily
        default:
          self.state = .stoppedTunnel
        }
      }
    }
  }
}
