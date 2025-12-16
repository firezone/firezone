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
  /// Task for consuming commands from Adapter. Uses CancellableTask for RAII cleanup.
  private var commandConsumerTask: CancellableTask?

  enum LogExportState {
    case inProgress(TunnelLogArchive)
    case idle
  }

  private var getLogFolderSizeTask: Task<Void, Never>?

  private var logExportState: LogExportState = .idle
  private var tunnelConfiguration: TunnelConfiguration?
  private let defaults = UserDefaults.standard

  override init() {
    // Initialize Telemetry as early as possible
    Telemetry.start()

    super.init()

    // Log version information immediately on startup
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
    Log.info(
      "NetworkExtension starting - Version: \(version), Build: \(build), Bundle ID: \(bundleId)")

    migrateFirezoneId()
    self.tunnelConfiguration = TunnelConfiguration.tryLoad()
  }

  deinit {
    getLogFolderSizeTask?.cancel()
  }

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping @Sendable (Error?) -> Void
  ) {
    // Dummy start to attach a utun for cleanup later
    if options?["cycleStart"] as? Bool == true {
      Log.info("Cycle start requested - extension awakened and temporarily starting tunnel")
      return completionHandler(nil)
    }

    // Log version on actual tunnel start
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    Log.info("Starting tunnel - Version: \(version), Build: \(build)")

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
        return completionHandler(PacketTunnelProviderError.tokenNotFoundInKeychain)
      }

      // Try to save the token back to the Keychain but continue if we can't
      handleTokenSave(token)

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
      Task { @Sendable in await Telemetry.setAccountSlug(accountSlug) }

      let enabled = legacyConfiguration?["internetResourceEnabled"]
      let internetResourceEnabled =
        enabled != nil ? enabled == "true" : (tunnelConfiguration?.internetResourceEnabled ?? false)

      // Create command channel for Adapter -> Provider communication
      let (commandSender, commandReceiver): (Sender<ProviderCommand>, Receiver<ProviderCommand>) =
        Channel.create()

      // Create the adapter with command sender
      let adapter = Adapter(
        apiURL: apiURL,
        token: token,
        deviceId: id,
        logFilter: logFilter,
        accountSlug: accountSlug,
        internetResourceEnabled: internetResourceEnabled,
        providerCommandSender: commandSender
      )

      self.adapter = adapter

      // Start command consumer loop.
      // ProviderCommandHandler wraps the non-Sendable PacketTunnelProvider for safe cross-task access.
      // This is safe because handleProviderCommand only calls NEPacketTunnelProvider methods
      // which handle their own synchronisation.
      let handler = ProviderCommandHandler(provider: self)
      commandConsumerTask = CancellableTask {
        for await command in commandReceiver.stream {
          handler.handle(command)
        }
        Log.log("Provider command consumer finished")
      }

      // Start the adapter asynchronously
      Task { @Sendable in
        do {
          try await adapter.start()
          completionHandler(nil)
        } catch {
          Log.error(error)
          completionHandler(error)
        }
      }

    } catch {
      Log.error(error)
      completionHandler(error)
    }
  }

  override func wake() {
    let adapter = self.adapter
    Task { @Sendable in
      await adapter?.reset(reason: "awoke from sleep")
    }
  }

  // This can be called by the system, or initiated by connlib.
  // When called by the system, we call Adapter.stop() from here.
  // When initiated by connlib, we've already called stop() there.
  override func stopTunnel(
    with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void
  ) {
    Log.log("stopTunnel: Reason: \(reason)")

    // Cancel command consumer - CancellableTask handles cancellation on deinit
    commandConsumerTask = nil

    // handles both connlib-initiated and user-initiated stops
    let adapter = self.adapter
    Task { @Sendable in
      await adapter?.stop()
      completionHandler()
    }
  }

  // It would be helpful to be able to encapsulate Errors here. To do that
  // we need to update ProviderMessage to encode/decode Result to and from Data.
  // TODO: Move to a more abstract IPC protocol
  override func handleAppMessage(
    _ message: Data, completionHandler: (@Sendable (Data?) -> Void)? = nil
  ) {
    do {
      let providerMessage = try PropertyListDecoder().decode(ProviderMessage.self, from: message)

      switch providerMessage {

      case .setConfiguration(let tunnelConfiguration):
        tunnelConfiguration.save()
        self.tunnelConfiguration = tunnelConfiguration

        let adapter = self.adapter
        Task { @Sendable in
          await adapter?.setInternetResourceEnabled(tunnelConfiguration.internetResourceEnabled)
        }
        completionHandler?(nil)

      case .signOut:
        do { try Token.delete() } catch { Log.error(error) }
        completionHandler?(nil)
      case .getResourceList(let hash):
        guard let adapter else {
          Log.warning("Adapter is nil")
          completionHandler?(nil)
          return
        }

        // Use hash comparison to only return resources if they've changed
        Task { @Sendable in
          let resourceData = await adapter.getResourcesIfVersionDifferentFrom(hash: hash)
          completionHandler?(resourceData)
        }
      case .clearLogs:
        clearLogs(completionHandler)
      case .getLogFolderSize:
        getLogFolderSize(completionHandler)
      case .exportLogs:
        exportLogs(completionHandler!)
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

  func clearLogs(_ completionHandler: (@Sendable (Data?) -> Void)? = nil) {
    do {
      try Log.clear(in: SharedAccess.logFolderURL)
    } catch {
      Log.error(error)
    }

    completionHandler?(nil)
  }

  func getLogFolderSize(_ completionHandler: (@Sendable (Data?) -> Void)? = nil) {
    guard let logFolderURL = SharedAccess.logFolderURL
    else {
      completionHandler?(nil)

      return
    }

    let task = Task { @Sendable in
      let size = await Log.size(of: logFolderURL)
      let data = withUnsafeBytes(of: size) { Data($0) }

      // Call completion handler with data if not cancelled
      guard !Task.isCancelled else { return }
      completionHandler?(data)
    }
    getLogFolderSizeTask = task
  }

  func exportLogs(_ completionHandler: @escaping @Sendable (Data?) -> Void) {
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
        let cacheFolderURL = SharedAccess.cacheFolderURL,
        let connlibLogFolderURL = SharedAccess.connlibLogFolderURL
      else {
        completionHandler(nil)

        return
      }

      let tunnelLogArchive = TunnelLogArchive(source: logFolderURL)

      let latestSymlink = connlibLogFolderURL.appendingPathComponent("latest")
      let tempSymlink = cacheFolderURL.appendingPathComponent(
        "latest")

      do {
        // Move the `latest` symlink out of the way before creating the archive.
        // Apple's implementation of zip appears to not be able to handle symlinks well
        let _ = try? FileManager.default.moveItem(at: latestSymlink, to: tempSymlink)
        defer {
          let _ = try? FileManager.default.moveItem(at: tempSymlink, to: latestSymlink)
        }

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

  // Firezone ID migration. Can be removed once most clients migrate past 1.4.15.
  private func migrateFirezoneId() {
    let filename = "firezone-id"
    let key = "firezoneId"

    // 1. Try to load from file, deleting it
    if let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: BundleHelper.appGroupId),
      let idFromFile = try? String(contentsOf: containerURL.appendingPathComponent(filename))
    {
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

  #if os(macOS)
    private func handleTokenSave(_ token: Token) {
      do {
        try token.save()
      } catch let error as KeychainError {
        // macOS 13 and below have a bug that raises an error when a root proc (such as our system extension) tries
        // to add an item to the system keychain. We can safely ignore this.
        if #unavailable(macOS 14.0), case .appleSecError("SecItemAdd", 100001) = error {
          // ignore
        } else {
          Log.error(error)
        }
      } catch {
        Log.error(error)
      }
    }
  #endif

  #if os(iOS)
    private func handleTokenSave(_ token: Token) {
      do { try token.save() } catch { Log.error(error) }
    }
  #endif

  // MARK: - Provider command handling

  /// Handle commands from the Adapter via channel.
  fileprivate func handleProviderCommand(_ command: ProviderCommand) {
    switch command {
    case .cancelWithError(let sendableError):
      if let sendableError {
        let error: Error =
          sendableError.isAuthenticationError
          ? FirezoneKit.ConnlibError.sessionExpired(sendableError.message)
          : NSError(
            domain: "Firezone", code: 1,
            userInfo: [NSLocalizedDescriptionKey: sendableError.message])
        cancelTunnelWithError(error)
      } else {
        cancelTunnelWithError(nil)
      }

    case .setReasserting(let value):
      reasserting = value

    case .getReasserting(let responseSender):
      responseSender.send(reasserting)

    case .applyNetworkSettings(let settings, let responseSender):
      let neSettings = settings.buildNetworkSettings()
      setTunnelNetworkSettings(neSettings) { error in
        responseSender.send(error?.localizedDescription)
      }
    }
  }
}

/// Sendable wrapper for handling provider commands from a concurrent task.
///
/// This wraps a weak reference to PacketTunnelProvider to allow safe command handling
/// from a detached task. Marked @unchecked Sendable because PacketTunnelProvider
/// is not Sendable (framework limitation), but the methods called handle their own
/// synchronisation.
private final class ProviderCommandHandler: @unchecked Sendable {
  private weak var provider: PacketTunnelProvider?

  init(provider: PacketTunnelProvider) {
    self.provider = provider
  }

  func handle(_ command: ProviderCommand) {
    provider?.handleProviderCommand(command)
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
      "internetResourceEnabled": internetResourceEnabled,
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
