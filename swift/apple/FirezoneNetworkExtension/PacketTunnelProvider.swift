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
  case apiURLIsInvalid
  case logFilterIsInvalid
  case accountSlugIsInvalid
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
  private var configuration: Configuration

  override init() {
    // Initialize Telemetry as early as possible
    Telemetry.start()

    self.configuration = Configuration(
      userDict: ConfigurationManager.shared.userDict,
      managedDict: ConfigurationManager.shared.managedDict
    )

    super.init()
  }

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    super.startTunnel(options: options, completionHandler: completionHandler)
    Log.log("\(#function)")

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
      guard let id = configuration.firezoneId
      else {
        throw PacketTunnelProviderError.firezoneIdIsInvalid
      }

      // Now we should have a token, so continue connecting
      let apiURL = legacyConfiguration?["apiURL"] ?? configuration.apiURL ?? Configuration.defaultApiURL

      // Reconfigure our Telemetry environment now that we know the API URL
      Telemetry.setEnvironmentOrClose(apiURL)

      let logFilter = legacyConfiguration?["logFilter"] ?? configuration.logFilter ?? Configuration.defaultLogFilter

      guard let accountSlug = legacyConfiguration?["accountSlug"] ?? configuration.accountSlug
      else {
        throw PacketTunnelProviderError.accountSlugIsInvalid
      }
      Telemetry.accountSlug = accountSlug

      let enabled = legacyConfiguration?["internetResourceEnabled"]
      let internetResourceEnabled =
        enabled != nil ? enabled == "true" : (configuration.internetResourceEnabled ?? false)

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
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  override func handleAppMessage(_ message: Data, completionHandler: ((Data?) -> Void)? = nil) {
    do {
      let providerMessage = try PropertyListDecoder().decode(ProviderMessage.self, from: message)

      switch providerMessage {

      case .getConfiguration(let hash):
        let configurationPayload = configuration.toDataIfChanged(hash: hash)
        completionHandler?(configurationPayload)

      case .setAuthURL(let authURL):
        configuration.authURL = authURL
        ConfigurationManager.shared.setAuthURL(authURL)
        completionHandler?(nil)

      case .setApiURL(let apiURL):
        configuration.apiURL = apiURL
        ConfigurationManager.shared.setApiURL(apiURL)
        completionHandler?(nil)

      case .setActorName(let actorName):
        configuration.actorName = actorName
        ConfigurationManager.shared.setActorName(actorName)
        completionHandler?(nil)

      case .setAccountSlug(let accountSlug):
        configuration.accountSlug = accountSlug
        ConfigurationManager.shared.setAccountSlug(accountSlug)
        completionHandler?(nil)

      case .setLogFilter(let logFilter):
        configuration.logFilter = logFilter
        ConfigurationManager.shared.setLogFilter(logFilter)
        completionHandler?(nil)

      case .setInternetResourceEnabled(let enabled):
        configuration.internetResourceEnabled = enabled
        ConfigurationManager.shared.setInternetResourceEnabled(enabled)
        adapter?.setInternetResourceEnabled(enabled)
        completionHandler?(nil)

      case .setConnectOnStart(let connectOnStart):
        configuration.connectOnStart = connectOnStart
        ConfigurationManager.shared.setConnectOnStart(connectOnStart)
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
}
