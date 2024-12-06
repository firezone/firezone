//
//  PacketTunnelProvider.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKit
import NetworkExtension
import os

enum PacketTunnelProviderError: Error {
  case savedProtocolConfigurationIsInvalid(String)
  case tokenNotFoundInKeychain
}

class PacketTunnelProvider: NEPacketTunnelProvider {
  private var adapter: Adapter?

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    super.startTunnel(options: options, completionHandler: completionHandler)
    Log.tunnel.log("\(#function)")

    Task {
      do {
        var token = options?["token"] as? String
        let keychain = Keychain()
        let tokenRef = await keychain.search()

        if let token = token {
          // 1. If we're passed a token, save it to keychain

          // Apple recommends updating Keychain items in place if possible
          // In reality this won't happen unless there's some kind of race condition
          // because we would have deleted the item upon sign out.
          if tokenRef != nil {
            try await keychain.update(token: token)
          } else {
            try await keychain.add(token: token)
          }

        } else {

          // 2. Otherwise, load it from the keychain
          guard let tokenRef = tokenRef
          else {
            completionHandler(PacketTunnelProviderError.tokenNotFoundInKeychain)
            return
          }

          token = await keychain.load(persistentRef: tokenRef)
        }

        // 3. Now we should have a token, so connect
        guard let apiURL = protocolConfiguration.serverAddress
        else {
          completionHandler(
            PacketTunnelProviderError.savedProtocolConfigurationIsInvalid("serverAddress"))
          return
        }

        guard
          let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration as? [String: String],
          let logFilter = providerConfiguration[TunnelManagerKeys.logFilter]
        else {
          completionHandler(
            PacketTunnelProviderError.savedProtocolConfigurationIsInvalid(
              "providerConfiguration.logFilter"))
          return
        }

        guard let token = token
        else {
          completionHandler(PacketTunnelProviderError.tokenNotFoundInKeychain)
          return
        }

        let internetResourceEnabled: Bool = if let internetResourceEnabledJSON = providerConfiguration[TunnelManagerKeys.internetResourceEnabled]?.data(using: .utf8) {
          (try? JSONDecoder().decode(Bool.self, from: internetResourceEnabledJSON )) ?? false
        } else {
          false
        }

        let adapter = Adapter(
          apiURL: apiURL, token: token, logFilter: logFilter, internetResourceEnabled: internetResourceEnabled, packetTunnelProvider: self)
        self.adapter = adapter


        try adapter.start()

        // Tell the system the tunnel is up, moving the tunnelManager status to
        // `connected`.
        completionHandler(nil)
      } catch {
        Log.tunnel.error("\(#function): Error! \(error)")
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
    Log.tunnel.log("stopTunnel: Reason: \(reason)")

    if case .authenticationCanceled = reason {
      do {
        // This was triggered from onDisconnect, so clear our token
        Task { await clearToken() }

        // There's no good way to send data like this from the
        // Network Extension to the GUI, so save it to a file for the GUI to read upon
        // either status change or the next launch.
        try String(reason.rawValue).write(
          to: SharedAccess.providerStopReasonURL, atomically: true, encoding: .utf8)
      } catch {
        Log.tunnel.error(
          "\(#function): Couldn't write provider stop reason to file. Notification won't work.")
      }
      #if os(iOS)
        // iOS notifications should be shown from the tunnel process
        SessionNotification.showSignedOutNotificationiOS()
      #endif
    }

    // handles both connlib-initiated and user-initiated stops
    adapter?.stop()

    cancelTunnelWithError(nil)
    super.stopTunnel(with: reason, completionHandler: completionHandler)
    completionHandler()
  }

  override func handleAppMessage(_ message: Data, completionHandler: ((Data?) -> Void)? = nil) {
    guard let tunnelMessage =  try? PropertyListDecoder().decode(TunnelMessage.self, from: message) else { return }

    switch tunnelMessage {
    case .internetResourceEnabled(let value):
      adapter?.setInternetResourceEnabled(value)
    case .signOut:
      Task {
          await clearToken()
      }
    case .getResourceList(let value):
      adapter?.getResourcesIfVersionDifferentFrom(hash: value) {
        resourceListJSON in
        completionHandler?(resourceListJSON?.data(using: .utf8))
      }
    }
  }

  enum TokenError: Error {
    case TokenNotFound
  }

  private func clearToken() async {
    do {
      let keychain = Keychain()
      guard let ref = await keychain.search() else {
        throw TokenError.TokenNotFound
      }
      try await keychain.delete(persistentRef: ref)
    } catch {
      Log.tunnel.error("\(#function): Error: \(error)")
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
