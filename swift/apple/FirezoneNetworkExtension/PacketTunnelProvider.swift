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
  case tunnelConfigurationIsInvalid
  case firezoneIdIsInvalid
  case tokenNotFoundInKeychain
}

class PacketTunnelProvider: NEPacketTunnelProvider {
  private var adapter: Adapter?

  enum LogExportState {
    case inProgress(TunnelLogArchive)
    case idle
  }

  private var logExportState: LogExportState = .idle
  private var tunnelConfiguration: TunnelConfiguration?
  private let defaults = UserDefaults.standard

  override init() {
    // Initialize Telemetry as early as possible
    Telemetry.start()

    super.init()

    migrateFirezoneId()
    self.tunnelConfiguration = TunnelConfiguration.tryLoad()
  }

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    super.startTunnel(options: options, completionHandler: completionHandler)

    // Dummy start to get the extension running on macOS after upgrade
    if options?["dryRun"] as? Bool == true {
      completionHandler(nil)
      return
    }

    // If the tunnel starts up before the GUI after an upgrade crossing the 1.4.15 version boundary,
    // the old system settings-based config will still be present and the new configuration will be empty.
    // So handle that edge case gracefully.
    let legacyConfiguration = VPNConfigurationManager.legacyConfiguration(
      protocolConfiguration: protocolConfiguration as? NETunnelProviderProtocol
    )

    do {
      // If we don't have a token, we can't continue.
      guard let token = loadAndSaveToken(from: options)
      else {
        throw PacketTunnelProviderError.tokenNotFoundInKeychain
      }

      // Try to save the token back to the Keychain but continue if we can't
      do { try token.save() } catch { Log.error(error) }

      // The firezone id should be initialized by now
      guard let id = UserDefaults.standard.string(forKey: "firezoneId")
      else {
        throw PacketTunnelProviderError.firezoneIdIsInvalid
      }

      guard let apiURL = legacyConfiguration?["apiURL"] ?? tunnelConfiguration?.apiURL,
            let logFilter = legacyConfiguration?["logFilter"] ?? tunnelConfiguration?.logFilter,
            let accountSlug = legacyConfiguration?["accountSlug"] ?? tunnelConfiguration?.accountSlug
      else {
        throw PacketTunnelProviderError.tunnelConfigurationIsInvalid
      }

      // Configure telemetry
      Telemetry.setEnvironmentOrClose(apiURL)
      Telemetry.accountSlug = accountSlug

      let enabled = legacyConfiguration?["internetResourceEnabled"]
      let internetResourceEnabled =
        enabled != nil ? enabled == "true" : (tunnelConfiguration?.internetResourceEnabled ?? false)

      let adapter = Adapter(
        apiURL: apiURL,
        token: token,
        id: id,
        logFilter: logFilter,
        accountSlug: accountSlug,
        internetResourceEnabled: internetResourceEnabled,
        packetTunnelProvider: self
      )

      try adapter.start()

      self.adapter = adapter

      // Tell the system the tunnel is up, moving the tunnel manager status to
      // `connected`.
      completionHandler(nil)

    } catch {

      Log.error(error)
      completionHandler(error)
    }
  }

  // This can be called by the system, or initiated by connlib.
  // When called by the system, we call Adapter.stop() from here.
  // When initiated by connlib, we've already called stop() there.
  override func stopTunnel(
    with reason: NEProviderStopReason, completionHandler: @escaping () -> Void
  ) {
    Log.log("stopTunnel: Reason: \(reason)")

    do {
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

    if case .authenticationCanceled = reason {
      // This was triggered from onDisconnect, so try to clear our token
      do { try Token.delete() } catch { Log.error(error) }

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

  // It would be helpful to be able to encapsulate Errors here. To do that
  // we need to update ProviderMessage to encode/decode Result to and from Data.
  // TODO: Move to a more abstract IPC protocol
  override func handleAppMessage(_ message: Data, completionHandler: ((Data?) -> Void)? = nil) {
    do {
      let providerMessage = try PropertyListDecoder().decode(ProviderMessage.self, from: message)

      switch providerMessage {

      case .setConfiguration(let tunnelConfiguration):
        tunnelConfiguration.save()
        self.tunnelConfiguration = tunnelConfiguration
        self.adapter?.setInternetResourceEnabled(tunnelConfiguration.internetResourceEnabled)
        completionHandler?(nil)

      case .signOut:
        do {
          try Token.delete()
          Task {
            await stopTunnel(with: .userInitiated)
            completionHandler?(nil)
          }
        } catch {
          Log.error(error)
          completionHandler?(nil)
        }
      case .getResourceList(let hash):
        guard let adapter = adapter
        else {
          Log.warning("Adapter is nil")
          completionHandler?(nil)

          return
        }

        adapter.getResourcesIfVersionDifferentFrom(hash: hash) { resourceListJSON in
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
    } catch {
      Log.error(error)
      completionHandler?(nil)
    }
  }

  func loadAndSaveToken(from options: [String: NSObject]?) -> Token? {
    let passedToken = options?["token"] as? String

    // Try to load saved token from Keychain, continuing if Keychain is
    // unavailable.
    let keychainToken = {
      do { return try Token.load() } catch { Log.error(error) }

      return nil
    }()

    return Token(passedToken) ?? keychainToken
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
        let (chunk, done) = try tunnelLogArchive.readChunk()

        if done {
          self.logExportState = .idle
        }

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

  // Firezone ID migration. Can be removed once most clients migrate past 1.4.15.
  private func migrateFirezoneId() {
    let filename = "firezone-id"
    let key = "firezoneId"

    // 1. Try to load from file, deleting it
    if let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: BundleHelper.appGroupId),
       let idFromFile = try? String(contentsOf: containerURL.appendingPathComponent(filename)) {
      defaults.set(idFromFile, forKey: key)
      try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(filename))
      return
    }

    // 2. Try to load from dict
    if defaults.string(forKey: key) != nil {
      return
    }

    // 3. Generate and save new one
    defaults.set(UUID().uuidString, forKey: key)
  }
}

// Increase usefulness of TunnelConfiguration now that we're over the IPC barrier
extension TunnelConfiguration {
  func save() {
    let key = "configurationCache"

    let dict: [String: Any] = [
      "apiURL": apiURL,
      "logFilter": logFilter,
      "accountSlug": accountSlug,
      "internetResourceEnabled": internetResourceEnabled
    ]

    UserDefaults.standard.set(dict, forKey: key)
  }

  static func tryLoad() -> TunnelConfiguration? {
    let key = "configurationCache"

    guard let dict = UserDefaults.standard.dictionary(forKey: key)
    else {
      return nil
    }

    guard let apiURL = dict["apiURL"] as? String,
          let logFilter = dict["logFilter"] as? String,
          let accountSlug = dict["accountSlug"] as? String,
          let internetResourceEnabled = dict["internetResourceEnabled"] as? Bool
    else {
      return nil
    }

    return TunnelConfiguration(
      apiURL: apiURL,
      accountSlug: accountSlug,
      logFilter: logFilter,
      internetResourceEnabled: internetResourceEnabled
    )
  }
}
