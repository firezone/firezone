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
  case providerConfigurationIsInvalid
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

  private var getLogFolderSizeTask: CancellableTask?
  private var logCleanupTask: CancellableTask?

  private var logExportState: LogExportState = .idle
  // swiftlint:disable:next no_userdefaults_standard - NetworkExtension DI entry point uses shared UserDefaults store
  private let defaults = UserDefaults.standard

  override init() {
    // Initialize Telemetry as early as possible.
    // Disable app hang tracking because Network Extensions legitimately block
    // on mach_msg when idle, causing false positive reports.
    Telemetry.start(enableAppHangTracking: false)

    super.init()

    // Log version information immediately on startup
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
    Log.info(
      "NetworkExtension starting - Version: \(version), Build: \(build), Bundle ID: \(bundleId)")

    migrateFirezoneId()
  }

  override func startTunnel(
    // swiftlint:disable:next discouraged_optional_collection - Apple API signature
    options: [String: NSObject]?,
    completionHandler: @escaping @Sendable (Error?) -> Void
  ) {
    // Dummy start to attach a utun for cleanup later
    if options?["cycleStart"] as? Bool == true {
      Log.info("Cycle start requested - extension awakened and temporarily starting tunnel")
      completionHandler(nil)
      return
    }

    // Log version on actual tunnel start
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    Log.info("Starting tunnel - Version: \(version), Build: \(build)")

    // Extract token from options before any async work
    let passedToken = options?["token"] as? String

    // Load token synchronously - Keychain access is thread-safe
    guard let token = loadToken(passedToken: passedToken)
    else {
      completionHandler(PacketTunnelProviderError.tokenNotFoundInKeychain)
      return
    }

    // Try to save the token back to the Keychain but continue if we can't
    handleTokenSave(token)

    // The firezone id should be initialized by now
    guard let rawId = defaults.string(forKey: "firezoneId")
    else {
      completionHandler(PacketTunnelProviderError.firezoneIdIsInvalid)
      return
    }
    let firezoneId = FirezoneId(uuid: rawId)

    let providerConfiguration: [String: String]
    do {
      providerConfiguration = try loadProviderConfiguration()
    } catch {
      completionHandler(PacketTunnelProviderError.providerConfigurationIsInvalid)
      return
    }

    let apiURL =
      providerConfiguration.withMDMOverride(forKey: Configuration.Keys.apiURL)
      ?? ConfigurationDefaults.apiURL
    let logFilter =
      providerConfiguration.withMDMOverride(forKey: Configuration.Keys.logFilter)
      ?? ConfigurationDefaults.logFilter
    let accountSlug =
      providerConfiguration.withMDMOverride(forKey: Configuration.Keys.accountSlug)
      ?? ConfigurationDefaults.accountSlug
    let internetResourceEnabled = Configuration.parseBool(
      providerConfiguration[Configuration.Keys.internetResourceEnabled],
      default: ConfigurationDefaults.internetResourceEnabled
    )

    Telemetry.setEnvironmentOrClose(apiURL)
    Telemetry.setUser(firezoneId: firezoneId.encoded, accountSlug: accountSlug)

    // Create command channel for Adapter -> Provider communication
    let (commandSender, commandReceiver): (Sender<ProviderCommand>, Receiver<ProviderCommand>) =
      Channel.create()

    let adapter = Adapter(
      apiURL: apiURL,
      token: token,
      deviceId: firezoneId.uuid,
      logFilter: logFilter,
      accountSlug: accountSlug,
      internetResourceEnabled: internetResourceEnabled,
      providerCommandSender: commandSender
    )

    // Store adapter reference so it's accessible to wake() and stopTunnel()
    self.adapter = adapter

    // Start command consumer loop
    let handler = PacketTunnelProviderActorBridge(self)
    commandConsumerTask = CancellableTask { @Sendable in
      for await command in commandReceiver.stream {
        handler.handle(command)
      }
      Log.log("Provider command consumer finished")
    }

    // Start the adapter asynchronously. The Task only captures Sendable values:
    // - adapter: actor (Sendable)
    // - completionHandler: @Sendable
    Task { @Sendable in
      do {
        try await adapter.start()
        completionHandler(nil)
      } catch {
        Log.error(error)
        completionHandler(error)
      }
    }
  }

  /// Loads the token from passed value or Keychain.
  private func loadToken(passedToken: String?) -> Token? {
    // Try to load saved token from Keychain, continuing if Keychain is unavailable.
    let keychainToken: Token? = {
      do { return try Token.load() } catch { Log.error(error) }
      return nil
    }()

    return Token(passedToken) ?? keychainToken
  }

  private func loadProviderConfiguration() throws -> [String: String] {
    guard let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol
    else { throw PacketTunnelProviderError.providerConfigurationIsInvalid }

    guard let raw = protocolConfiguration.providerConfiguration else { return [:] }
    guard let typed = raw as? [String: String] else {
      throw PacketTunnelProviderError.providerConfigurationIsInvalid
    }
    return typed
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

    logCleanupTask = nil

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

      case .setInternetResourceEnabled(let enabled):
        let adapter = self.adapter
        Task { @Sendable in
          await adapter?.setInternetResourceEnabled(enabled)
        }
        completionHandler?(nil)

      case .signOut:
        do { try Token.delete() } catch { Log.error(error) }
        completionHandler?(nil)
      case .getState(let hash):
        guard let adapter else {
          Log.warning("Adapter is nil")
          completionHandler?(nil)
          return
        }

        // Use hash comparison to only return resources if they've changed
        Task { @Sendable in
          // Use hash comparison to only return state if it changed
          let connlibState = await adapter.getStateIfVersionDifferentFrom(hash: hash)
          completionHandler?(connlibState)
        }
      case .getEncodedFirezoneId:
        guard let rawId = defaults.string(forKey: "firezoneId") else {
          Log.error(PacketTunnelProviderError.firezoneIdIsInvalid)
          completionHandler?(nil)
          return
        }
        let encodedId = FirezoneId(uuid: rawId).encoded
        completionHandler?(encodedId.data(using: .utf8))
      case .clearLogs:
        clearLogs(completionHandler)
      case .getLogFolderSize:
        getLogFolderSize(completionHandler)
      case .exportLogs:
        guard let handler = completionHandler else {
          Log.warning("exportLogs requires a completion handler")
          return
        }
        exportLogs(handler)
      }
    } catch {
      Log.error(error)
      completionHandler?(nil)
    }
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

    getLogFolderSizeTask = CancellableTask {
      let size = await Log.size(of: logFolderURL)
      let data = withUnsafeBytes(of: size) { Data($0) }

      // Call completion handler with data if not cancelled
      guard !Task.isCancelled else { return }
      completionHandler?(data)
    }
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

      let latestSymlinkNames = ["latest", "connlib.latest"]
      let successfullyMovedSymlinks: [(source: URL, temp: URL)] = latestSymlinkNames.compactMap {
        symlinkName in
        let source = connlibLogFolderURL.appendingPathComponent(symlinkName)
        let temp = cacheFolderURL.appendingPathComponent(symlinkName)

        try? FileManager.default.removeItem(at: temp)

        do {
          try FileManager.default.moveItem(at: source, to: temp)
          return (source, temp)
        } catch {
          return nil
        }
      }

      do {
        // Move any known connlib `latest` symlink out of the way before creating the archive.
        // Apple's implementation of zip appears to not be able to handle symlinks well.
        defer {
          for moved in successfullyMovedSymlinks.reversed() {
            _ = try? FileManager.default.moveItem(at: moved.temp, to: moved.source)
          }
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

  func startLogCleanupTask() {
    let maxSizeMb = logCleanupDefaultMaxSizeMb()
    let intervalNs = UInt64(logCleanupDefaultIntervalSecs()) * 1_000_000_000

    // Run cleanup in background task - both immediately and at the default interval
    logCleanupTask = CancellableTask {
      Self.performLogCleanup(maxSizeMb: maxSizeMb)

      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: intervalNs)
        guard !Task.isCancelled else { break }
        Self.performLogCleanup(maxSizeMb: maxSizeMb)
      }
    }
  }

  private static func performLogCleanup(maxSizeMb: UInt32) {
    guard let connlibDir = SharedAccess.connlibLogFolderURL?.path,
      let tunnelDir = SharedAccess.tunnelLogFolderURL?.path
    else {
      Log.warning("Cannot enforce log size cap: log directories unavailable")
      return
    }

    let deletedBytes = enforceLogSizeCap(logDirs: [connlibDir, tunnelDir], maxSizeMb: maxSizeMb)
    if deletedBytes > 0 {
      let deletedMb = deletedBytes / 1024 / 1024
      Log.info("Cleaned up \(deletedMb) MB of old logs")
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
    defaults.set(FirezoneId.generate().uuid, forKey: key)
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

  /// Handle commands from the Adapter via channel.
  ///
  /// **Must be called on the main thread.** NEPacketTunnelProvider's properties and methods
  /// have undocumented main-thread requirements:
  /// - `reasserting`: Reading/writing from background threads silently returns stale values
  /// - `cancelTunnelWithError(_:)`: May not properly signal the system from background threads
  /// - `setTunnelNetworkSettings(_:completionHandler:)`: Works from any thread but we keep
  ///   it consistent with other calls
  ///
  /// The caller (`PacketTunnelProviderActorBridge.handle`) dispatches to main before calling.
  fileprivate func handleProviderCommand(_ command: ProviderCommand) {
    switch command {
    case .cancelWithError(let sendableError):
      let error: Error =
        sendableError.isAuthenticationError
        ? FirezoneKit.ConnlibError.sessionExpired(sendableError.message)
        : FirezoneKit.ConnlibError.disconnected(sendableError.message)
      cancelTunnelWithError(error)

    case .setReasserting(let value):
      reasserting = value

    case .getReasserting(let responseSender):
      responseSender.send(reasserting)

    case .startLogCleanupTask:
      startLogCleanupTask()

    case .applyNetworkSettings(let payload, let responseSender):
      let neSettings = payload.build()
      setTunnelNetworkSettings(neSettings) { error in
        responseSender.send(error?.localizedDescription)
      }
    }
  }
}

// MARK: - PacketTunnelProviderActorBridge

/// Sendable wrapper for handling provider commands from a concurrent task.
///
/// Marked @unchecked Sendable because PacketTunnelProvider is not Sendable (framework
/// limitation), but the methods called (cancelTunnelWithError, setTunnelNetworkSettings,
/// reasserting) are designed for cross-thread access by NEPacketTunnelProvider.
private final class PacketTunnelProviderActorBridge: @unchecked Sendable {
  private weak var provider: PacketTunnelProvider?

  fileprivate init(_ provider: PacketTunnelProvider) {
    self.provider = provider
  }

  func handle(_ command: ProviderCommand) {
    guard let provider else {
      Log.warning("CommandHandler: provider deallocated, dropping command")
      // Respond to channels to prevent callers from hanging indefinitely
      switch command {
      case .getReasserting(let sender):
        sender.send(false)
      case .applyNetworkSettings(_, let sender):
        sender.send("Provider unavailable")
      case .cancelWithError, .setReasserting, .startLogCleanupTask:
        break  // Fire-and-forget commands, no response needed
      }
      return
    }
    // NEPacketTunnelProvider properties like `reasserting` require main-thread access.
    // Without this, property reads silently fail and channel responses never arrive.
    DispatchQueue.main.async {
      provider.handleProviderCommand(command)
    }
  }
}
