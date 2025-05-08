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
  case tokenNotFoundInKeychain
}

class PacketTunnelProvider: NEPacketTunnelProvider {
  private var adapter: Adapter?
  private var appConfiguration: UserDefaults

  enum LogExportState {
    case inProgress(TunnelLogArchive)
    case idle
  }

  private var logExportState: LogExportState = .idle

  override init() {
    // Initialize Telemetry as early as possible
    Telemetry.start()

    guard let userDefaults = UserDefaults(suiteName: BundleHelper.appGroupId)
    else {
      fatalError("Could not initialize app configuration")
    }

    self.appConfiguration = userDefaults

    super.init()
  }

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    super.startTunnel(options: options, completionHandler: completionHandler)
    Log.log("\(#function)")

    do {
      // If we don't have a token, we can't continue.
      guard let token = loadAndSaveToken(from: options)
      else {
        throw PacketTunnelProviderError.tokenNotFoundInKeychain
      }

      // Try to save the token back to the Keychain but continue if we can't
      do { try token.save() } catch { Log.error(error) }

      // Use and persist the provided ID or try loading it from disk,
      // generating a new one if both of those are nil.
      let id = loadAndSaveFirezoneId(from: options)

      // Now we should have a token, so continue connecting
      guard let apiURL = appConfiguration.url(forKey: Store.Keys.apiURL)
      else {
        throw PacketTunnelProviderError.apiURLIsInvalid
      }

      // Reconfigure our Telemetry environment now that we know the API URL
      Telemetry.setEnvironmentOrClose(apiURL)

      guard let logFilter = appConfiguration.string(forKey: Store.Keys.logFilter)
      else {
        throw PacketTunnelProviderError.logFilterIsInvalid
      }

      // Hydrate telemetry account slug
      guard let accountSlug = appConfiguration.string(forKey: Store.Keys.accountSlug)
      else {
        throw PacketTunnelProviderError.accountSlugIsInvalid
      }

      Telemetry.accountSlug = accountSlug

      // Load current internetResourceEnabledState
      let internetResourceEnabled = appConfiguration.bool(forKey: Store.Keys.accountSlug)

      let adapter = Adapter(
        apiURL: apiURL,
        token: token,
        id: id,
        logFilter: logFilter,
        internetResourceEnabled: internetResourceEnabled,
        packetTunnelProvider: self
      )

      try adapter.start()

      self.adapter = adapter

      // Tell the system the tunnel is up, moving the tunnel manager status to
      // `connected`.
      completionHandler(nil)

    } catch let error as PacketTunnelProviderError {

      // These are expected, no need to log them
      completionHandler(error)

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
  override func handleAppMessage(_ message: Data, completionHandler: ((Data?) -> Void)? = nil) {
    guard let providerMessage = try? PropertyListDecoder().decode(ProviderMessage.self, from: message) else { return }

    switch providerMessage {
    case .internetResourceEnabled(let value):
      adapter?.setInternetResourceEnabled(value)
    case .signOut:
      do {
        try Token.delete()
      } catch {
        Log.error(error)
      }
    case .getResourceList(let value):
      adapter?.getResourcesIfVersionDifferentFrom(hash: value) { resourceListJSON in
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

  func loadAndSaveFirezoneId(from options: [String: NSObject]?) -> String {
    let passedId = options?["id"] as? String
    let persistedId = FirezoneId.load(.post140)

    let id = passedId ?? persistedId ?? UUID().uuidString

    FirezoneId.save(id)

    // Hydrate the telemetry userId with our firezone id
    Telemetry.firezoneId = id

    return id
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
