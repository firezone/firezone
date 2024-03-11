//
//  PacketTunnelProvider.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import FirezoneKit
import NetworkExtension
import os

enum PacketTunnelProviderError: Error {
  case savedProtocolConfigurationIsInvalid(String)
  case tokenNotFoundInKeychain
  case couldNotSetNetworkSettings
}

class PacketTunnelProvider: NEPacketTunnelProvider {
  let logger = AppLogger(process: .tunnel, folderURL: SharedAccess.tunnelLogFolderURL)

  private var adapter: Adapter?

  override func startTunnel(
    options _: [String: NSObject]? = nil,
    completionHandler: @escaping (Error?) -> Void
  ) {
    logger.log("\(#function)")

    guard let controlPlaneURLString = protocolConfiguration.serverAddress else {
      logger.error("serverAddress is missing")
      self.handleTunnelShutdown(
        dueTo: .badTunnelConfiguration,
        errorMessage: "serverAddress is missing")
      completionHandler(
        PacketTunnelProviderError.savedProtocolConfigurationIsInvalid("serverAddress"))
      return
    }

    guard let tokenRef = protocolConfiguration.passwordReference else {
      logger.error("passwordReference is missing")
      self.handleTunnelShutdown(
        dueTo: .badTunnelConfiguration,
        errorMessage: "passwordReference is missing")
      completionHandler(
        PacketTunnelProviderError.savedProtocolConfigurationIsInvalid("passwordReference"))
      return
    }

    let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration

    guard let connlibLogFilter = providerConfig?[TunnelProviderKeys.keyConnlibLogFilter] as? String
    else {
      logger.error("connlibLogFilter is missing")
      self.handleTunnelShutdown(
        dueTo: .badTunnelConfiguration,
        errorMessage: "connlibLogFilter is missing")
      completionHandler(
        PacketTunnelProviderError.savedProtocolConfigurationIsInvalid("connlibLogFilter"))
      return
    }

    Task {
      let keychain = Keychain()
      guard let token = await keychain.load(persistentRef: tokenRef) else {
        self.handleTunnelShutdown(
          dueTo: .tokenNotFound,
          errorMessage: "Token not found in keychain")
        completionHandler(PacketTunnelProviderError.tokenNotFoundInKeychain)
        return
      }

      let adapter = Adapter(
        controlPlaneURLString: controlPlaneURLString, token: token, logFilter: connlibLogFilter,
        packetTunnelProvider: self)
      self.adapter = adapter
      do {
        try adapter.start { error in
          if let error {
            self.logger.error("Error in adapter.start: \(error)")
          }
          completionHandler(error)
        }
      } catch {
        completionHandler(error)
      }
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason, completionHandler: @escaping () -> Void
  ) {
    logger.log("stopTunnel: Reason: \(reason)")
    adapter?.stop(reason: reason) {
      completionHandler()
      #if os(macOS)
        // HACK: This is a filthy hack to work around Apple bug 32073323
        exit(0)
      #endif
    }
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
    let query = String(data: messageData, encoding: .utf8) ?? ""
    adapter?.getDisplayableResourcesIfVersionDifferentFrom(referenceVersionString: query) {
      displayableResources in
      completionHandler?(displayableResources?.toData())
    }
  }

  func handleTunnelShutdown(dueTo reason: TunnelShutdownEvent.Reason, errorMessage: String) {
    TunnelShutdownEvent.saveToDisk(reason: reason, errorMessage: errorMessage, logger: self.logger)

    #if os(iOS)
      if reason.action == .signoutImmediately {
        SessionNotificationHelper.showSignedOutNotificationiOS(logger: self.logger)
      }
    #endif
  }
}

extension NEProviderStopReason: CustomStringConvertible {
  public var description: String {
    switch self {
    case .none: return "None"
    case .userInitiated: return "User-initiated"
    case .providerFailed: return "Provider failed"
    case .noNetworkAvailable: return "No network available"
    case .unrecoverableNetworkChange: return "Unrecoverable network change"
    case .providerDisabled: return "Provider disabled"
    case .authenticationCanceled: return "Authentication cancelled"
    case .configurationFailed: return "Configuration failed"
    case .idleTimeout: return "Idle timeout"
    case .configurationDisabled: return "Configuration disabled"
    case .configurationRemoved: return "Configuration removed"
    case .superceded: return "Superceded"
    case .userLogout: return "User logged out"
    case .userSwitch: return "User switched"
    case .connectionFailed: return "Connection failed"
    case .sleep: return "Sleep"
    case .appUpdate: return "App update"
    @unknown default: return "Unknown"
    }
  }
}
