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
}

class PacketTunnelProvider: NEPacketTunnelProvider {
  let logger = AppLogger(category: .tunnel, folderURL: SharedAccess.tunnelLogFolderURL)

  private var adapter: Adapter?

  override func startTunnel(
    options _: [String: NSObject]? = nil,
    completionHandler: @escaping (Error?) -> Void
  ) {
    logger.log("\(#function)")

    guard let apiURL = protocolConfiguration.serverAddress,
      let tokenRef = protocolConfiguration.passwordReference,
      let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?
        .providerConfiguration as? [String: String],
      let logFilter = providerConfiguration[TunnelStoreKeys.logFilter]
    else {
      completionHandler(
        PacketTunnelProviderError.savedProtocolConfigurationIsInvalid("serverAddress"))
      return
    }

    Task {
      let keychain = Keychain()
      guard let token = await keychain.load(persistentRef: tokenRef) else {
        logger.error("\(#function): No token found in Keychain")
        completionHandler(PacketTunnelProviderError.tokenNotFoundInKeychain)
        return
      }

      let adapter = Adapter(
        apiURL: apiURL,
        token: token,
        logFilter: logFilter,
        packetTunnelProvider: self)
      self.adapter = adapter
      do {
        try adapter.start { error in
          if let error {
            self.logger.error("\(#function): \(error)")
          }
          completionHandler(error)
        }
      } catch {
        completionHandler(error)
      }
    }
  }

  // This can be called by the system, or initiated by connlib.
  // When called by the system, we call Adapter.stop() from here.
  // When initiated by connlib, we've already called stop() there.
  override func stopTunnel(
    with reason: NEProviderStopReason, completionHandler: @escaping () -> Void
  ) {
    logger.log("stopTunnel: Reason: \(reason)")

    if case .authenticationCanceled = reason {
      do {
        // Remove the passwordReference from our configuration so that it's not used again
        // if the app is re-launched. There's no good way to send data like this from the
        // Network Extension to the GUI, so save it to a file for the GUI to read later.
        try String(reason.rawValue).write(to: SharedAccess.providerStopReasonURL, atomically: true, encoding: .utf8)
      } catch {
        logger.error("\(#function): Couldn't write provider stop reason to file. Notification won't work.")
      }
      #if os(iOS)
        // iOS notifications should be shown from the tunnel process
        SessionNotificationHelper.showSignedOutNotificationiOS(logger: self.logger)
      #endif
    }

    // handles both connlib-initiated and user-initiated stops
    adapter?.stop()

    cancelTunnelWithError(nil)
  }

  // TODO: Use a message format to allow requesting different types of data.
  // This currently assumes we're requesting resources.
  override func handleAppMessage(_ hash: Data, completionHandler: ((Data?) -> Void)? = nil) {
    adapter?.getResourcesIfVersionDifferentFrom(hash: hash) {
      resourceListJSON in
      completionHandler?(resourceListJSON?.data(using: .utf8))
    }
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
    case .authenticationCanceled: return "Authentication canceled"
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
