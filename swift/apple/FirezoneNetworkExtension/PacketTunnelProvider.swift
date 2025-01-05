//
//  PacketTunnelProvider.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKit
import NetworkExtension
import System
import os

enum PacketTunnelProviderError: Error {
  case savedProtocolConfigurationIsInvalid(String)
  case tokenNotFoundInKeychain
}

class PacketTunnelProvider: NEPacketTunnelProvider {
  private var adapter: Adapter?

  enum LogExportState {
    case inProgress(TunnelLogArchive)
    case idle
  }

  private var logExportState: LogExportState = .idle

  override init() {
    // Initialize Telemetry as early as possible
    Telemetry.start()

    super.init()
  }

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    super.startTunnel(options: options, completionHandler: completionHandler)
    Log.log("\(#function)")

    Task {
      do {
        // Can be removed after all clients >= 1.4.0
        try FirezoneId.migrate()

        // The tunnel can come up without the app having been launched first, so
        // initialize the id here too.
        let id = try FirezoneId.createIfMissing()

        // Hydrate the telemetry userId with our firezone id
        Telemetry.firezoneId = id.uuid.uuidString

        let passedToken = options?["token"] as? String
        let keychainToken = try Token.load()

        // Use the provided token or try loading one from the Keychain
        guard let token = Token(passedToken) ?? keychainToken
        else {
          completionHandler(PacketTunnelProviderError.tokenNotFoundInKeychain)

          return
        }

        // Save the token back to the Keychain
        try token.save()

        // Now we should have a token, so continue connecting
        guard let apiURL = protocolConfiguration.serverAddress
        else {
          completionHandler(
            PacketTunnelProviderError.savedProtocolConfigurationIsInvalid("serverAddress"))
          return
        }

        // Reconfigure our Telemetry environment now that we know the API URL
        Telemetry.setEnvironmentOrClose(apiURL)

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

        // Hydrate telemetry account slug
        Telemetry.accountSlug = providerConfiguration[TunnelManagerKeys.accountSlug]

        let internetResourceEnabled: Bool = if let internetResourceEnabledJSON = providerConfiguration[TunnelManagerKeys.internetResourceEnabled]?.data(using: .utf8) {
          (try? JSONDecoder().decode(Bool.self, from: internetResourceEnabledJSON )) ?? false
        } else {
          false
        }

        let adapter = Adapter(
          apiURL: apiURL, token: token, logFilter: logFilter, internetResourceEnabled: internetResourceEnabled, packetTunnelProvider: self)
        self.adapter = adapter


        try await adapter.start()

        // Tell the system the tunnel is up, moving the tunnel manager status to
        // `connected`.
        completionHandler(nil)
      } catch {
        Log.error(error)
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
    Log.log("stopTunnel: Reason: \(reason)")

    if case .authenticationCanceled = reason {
      Task {
        do {
          // This was triggered from onDisconnect, so clear our token
          try Token.delete()

          // There's no good way to send data like this from the
          // Network Extension to the GUI, so save it to a file for the GUI to read upon
          // either status change or the next launch.
          try String(reason.rawValue).write(
            to: SharedAccess.providerStopReasonURL, atomically: true, encoding: .utf8)
        } catch {
          Log.error(
            SharedAccess.Error.unableToWriteToFile(
              SharedAccess.providerStopReasonURL,
              error
            )
          )
        }
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

  // TODO: It would be helpful to be able to encapsulate Errors here. To do that
  // we need to update TunnelMessage to encode/decode Result to and from Data.
  override func handleAppMessage(_ message: Data, completionHandler: ((Data?) -> Void)? = nil) {
    guard let tunnelMessage =  try? PropertyListDecoder().decode(TunnelMessage.self, from: message) else { return }

    switch tunnelMessage {
    case .internetResourceEnabled(let value):
      adapter?.setInternetResourceEnabled(value)
    case .signOut:
      do {
        try Token.delete()
      } catch {
        Log.error(error)
      }
    case .getResourceList(let value):
      adapter?.getResourcesIfVersionDifferentFrom(hash: value) {
        resourceListJSON in
        completionHandler?(resourceListJSON?.data(using: .utf8))
      }
    case .clearLogs:
      clearLogs(completionHandler)
    case .getLogFolderSize:
      getLogFolderSize(completionHandler)
    case .exportLogs:
      exportLogs(completionHandler!)

    case .consumeStopReason:
      consumeStopReason(completionHandler!)
    }
  }

  func clearLogs(_ completionHandler: ((Data?) -> Void)? = nil) {
    do {
      try Log.clear(in: SharedAccess.logFolderURL)
    } catch {
      Log.error(error)
    }

    completionHandler?(nil)
  }

  func getLogFolderSize(_ completionHandler: ((Data?) -> Void)? = nil) {
    guard let logFolderURL = SharedAccess.logFolderURL
    else {
      completionHandler?(nil)

      return
    }

    Task {
      let size = await Log.size(of: logFolderURL)
      let data = withUnsafeBytes(of: size) { Data($0) }

      completionHandler?(data)
    }
  }

  func exportLogs(_ completionHandler: @escaping (Data?) -> Void) {
    func sendChunk(_ tunnelLogArchive: TunnelLogArchive) {
      do {
        let chunk = try tunnelLogArchive.readChunk()
        completionHandler(chunk)
      } catch {
        Log.error(error)

        completionHandler(nil)
      }
    }

    switch self.logExportState {

    case .inProgress(let tunnelLogArchive):
      sendChunk(tunnelLogArchive)

    case .idle:
      guard let logFolderURL = SharedAccess.logFolderURL,
            let logFolderPath = FilePath(logFolderURL)
      else {
        completionHandler(nil)

        return
      }

      let tunnelLogArchive = TunnelLogArchive(source: logFolderPath)

      do {
        try tunnelLogArchive.archive()
      } catch {
        Log.error(error)
        completionHandler(nil)

        return
      }

      self.logExportState = .inProgress(tunnelLogArchive)
      sendChunk(tunnelLogArchive)
    }
  }

  func consumeStopReason(_ completionHandler: (Data?) -> Void) {
    guard let data = try? Data(contentsOf: SharedAccess.providerStopReasonURL)
    else {
      completionHandler(nil)

      return
    }

    try? FileManager.default
      .removeItem(at: SharedAccess.providerStopReasonURL)

    completionHandler(data)
  }
}

extension NEProviderStopReason: @retroactive CustomStringConvertible {
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
    case .internalError: return "Internal error"
    @unknown default: return "Unknown"
    }
  }
}
