//
//  FirezoneCLI.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation
import NetworkExtension

@main
struct FirezoneCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "firezone-cli",
    abstract: "Firezone headless Client",
    version: Self.versionString
  )

  @Option(name: .shortAndLong, help: ArgumentHelp("API URL.", visibility: .hidden))
  var apiUrl: String?

  @Flag(name: .long, help: "Activate Internet Resource.")
  var activateInternetResource = false

  @Option(name: .long, help: "Account slug.")
  var accountSlug: String?

  @Option(name: .long, help: ArgumentHelp("Auth base URL.", visibility: .hidden))
  var authBaseUrl: String?

  @Flag(name: .long, help: "Sign out and remove stored token.")
  var signOut = false

  private static var versionString: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    return "\(version) (\(build))"
  }

  @MainActor
  mutating func run() async throws {
    if signOut {
      try await performSignOut()
      return
    }

    let apiURL =
      self.apiUrl
      ?? ProcessInfo.processInfo.environment["FIREZONE_API_URL"]
      ?? Configuration.defaultApiURL

    let internetResourceEnabled =
      self.activateInternetResource
      || ProcessInfo.processInfo.environment["FIREZONE_ACTIVATE_INTERNET_RESOURCE"] == "1"

    Log.info("API URL: \(apiURL)")
    Log.info("Internet resource: \(internetResourceEnabled)")

    let accountSlug =
      self.accountSlug
      ?? ProcessInfo.processInfo.environment["FIREZONE_ACCOUNT_SLUG"]
      ?? Configuration.defaultAccountSlug

    let authBaseURL =
      self.authBaseUrl
      ?? ProcessInfo.processInfo.environment["FIREZONE_AUTH_BASE_URL"]
      ?? Configuration.defaultAuthURL

    #if SYSTEM_EXTENSION
      try await installSystemExtensionIfNeeded()
    #endif

    let session = try await setupVPN()

    Log.info("Account slug: \(accountSlug.isEmpty ? "(empty)" : accountSlug)")

    let logFilter =
      ProcessInfo.processInfo.environment["FIREZONE_LOG_FILTER"]
      ?? Configuration.defaultLogFilter

    let configuration = TunnelConfiguration(
      apiURL: apiURL,
      accountSlug: accountSlug,
      logFilter: logFilter,
      internetResourceEnabled: internetResourceEnabled
    )

    // Start tunnel: with explicit token if env var is set, otherwise let NE try keychain
    if let envToken = ProcessInfo.processInfo.environment["FIREZONE_TOKEN"],
      let token = Token(envToken)
    {
      try IPCClient.start(session: session, token: token.description, configuration: configuration)
    } else {
      try IPCClient.start(session: session, configuration: configuration)
    }

    Log.info("Tunnel started")

    try await monitorTunnel(
      session: session,
      configuration: configuration,
      authBaseURL: authBaseURL,
      accountSlug: accountSlug
    )
  }

  // MARK: - VPN Setup

  @MainActor
  private func setupVPN() async throws -> NETunnelProviderSession {
    let factory = NETunnelProviderManagerFactory()
    let vpnManager: VPNConfigurationManager
    if let existing = try await VPNConfigurationManager.load(using: factory) {
      vpnManager = existing
    } else {
      Log.info("Creating VPN configuration...")
      vpnManager = try await VPNConfigurationManager(manager: factory.createManager())
    }

    try await vpnManager.enable()

    guard let session = vpnManager.session() else {
      throw ValidationError("Failed to get VPN session")
    }

    return session
  }

  // MARK: - Tunnel Monitoring

  @MainActor
  private func monitorTunnel(
    session: NETunnelProviderSession,
    configuration: TunnelConfiguration,
    authBaseURL: String,
    accountSlug: String
  ) async throws {
    let (signalStream, signalContinuation) = AsyncStream.makeStream(of: SignalAction.self)
    let tunnelState = TunnelState()

    // Check if the session is already connected (e.g. from a previous run)
    if session.status == .connected {
      Log.info("Tunnel connected")
    }

    // Subscribe to VPN status updates
    Task {
      for await status in IPCClient.vpnStatusUpdates(session: session) {
        switch status {
        case .connected:
          Log.info("Tunnel connected")
        case .disconnected:
          if tunnelState.isRestarting {
            Log.info("Tunnel disconnected (restarting)")
          } else {
            let error = await Self.fetchLastDisconnectErrorAsync(session: session)
            if let error, !tunnelState.hasPromptedForToken, Self.isTokenNotFoundError(error) {
              Log.info("Token not found in keychain: \(error)")
              signalContinuation.yield(.promptForToken)
            } else {
              Self.logDisconnectError(error)
              signalContinuation.yield(.shutdown)
            }
          }
        case .connecting:
          Log.info("Tunnel connecting...")
        case .reasserting:
          Log.info("Tunnel reasserting...")
        case .disconnecting:
          Log.info("Tunnel disconnecting...")
        case .invalid:
          Log.warning("Tunnel status invalid")
        @unknown default:
          Log.warning("Unknown tunnel status: \(status.rawValue)")
        }
      }
    }

    // Connection timeout
    var timeoutTask = Task {
      try? await Task.sleep(for: .seconds(30))
      guard !Task.isCancelled else { return }
      if session.status != .connected {
        Log.error("Timed out waiting for tunnel to connect")
        signalContinuation.yield(.shutdown)
      }
    }

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGHUP, SIG_IGN)

    sigintSource.setEventHandler { signalContinuation.yield(.shutdown) }
    sigtermSource.setEventHandler { signalContinuation.yield(.shutdown) }
    sighupSource.setEventHandler { signalContinuation.yield(.restart) }

    sigintSource.resume()
    sigtermSource.resume()
    sighupSource.resume()

    for await action in signalStream {
      switch action {
      case .shutdown:
        Log.info("Shutting down...")
        session.stopTunnel()
        return
      case .restart:
        Log.info("Restarting tunnel...")
        tunnelState.isRestarting = true
        session.stopTunnel()
        try IPCClient.start(session: session, configuration: configuration)
        tunnelState.isRestarting = false
        Log.info("Tunnel restarted")
      case .promptForToken:
        timeoutTask.cancel()
        tunnelState.hasPromptedForToken = true
        let token = try promptForSignIn(authBaseURL: authBaseURL, accountSlug: accountSlug)
        try IPCClient.start(
          session: session, token: token.description, configuration: configuration)
        Log.info("Tunnel started with token")
        // Restart timeout for the new connection attempt
        timeoutTask = Task {
          try? await Task.sleep(for: .seconds(30))
          guard !Task.isCancelled else { return }
          if session.status != .connected {
            Log.error("Timed out waiting for tunnel to connect")
            signalContinuation.yield(.shutdown)
          }
        }
      }
    }
  }

  // MARK: - Sign In / Sign Out

  private func promptForSignIn(authBaseURL: String, accountSlug: String) throws -> Token {
    guard var components = URLComponents(string: authBaseURL) else {
      throw ValidationError("Invalid auth base URL: \(authBaseURL)")
    }

    if !accountSlug.isEmpty {
      components.path += components.path.hasSuffix("/") ? accountSlug : "/\(accountSlug)"
    }

    var queryItems = components.queryItems ?? []
    queryItems.append(URLQueryItem(name: "as", value: "headless-client"))
    components.queryItems = queryItems

    guard let authURL = components.url else {
      throw ValidationError("Failed to construct auth URL")
    }

    print(
      """

      ==========================================================================
      Firezone Headless Client - Browser Authentication
      ==========================================================================

      To sign in to Firezone, please follow these steps:

      1. Open the following URL in your web browser:

         \(authURL)

      2. Complete the sign-in process in your browser
      3. Copy the token displayed in the browser
      4. Return to this terminal and paste the token below

      ==========================================================================

      """)
    print("Enter the token from your browser: ", terminator: "")
    fflush(stdout)

    // Restore default SIGINT handling so Ctrl+C works during the prompt
    signal(SIGINT, SIG_DFL)
    defer { signal(SIGINT, SIG_IGN) }

    guard let tokenString = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
      !tokenString.isEmpty
    else {
      throw ValidationError("No token provided")
    }

    guard tokenString.count >= 64 else {
      throw ValidationError("Token appears to be invalid (too short)")
    }

    guard let token = Token(tokenString) else {
      throw ValidationError("Invalid token")
    }

    return token
  }

  @MainActor
  private func performSignOut() async throws {
    let factory = NETunnelProviderManagerFactory()
    guard let vpnManager = try await VPNConfigurationManager.load(using: factory) else {
      throw ValidationError("No VPN configuration found")
    }

    guard let session = vpnManager.session() else {
      throw ValidationError("Failed to get VPN session")
    }

    try await IPCClient.signOut(session: session)
    Log.info("Signed out successfully")
  }

  // MARK: - Error Handling

  private static func fetchLastDisconnectErrorAsync(
    session: NETunnelProviderSession
  ) async -> (any Error)? {
    await withCheckedContinuation { continuation in
      session.fetchLastDisconnectError { error in
        continuation.resume(returning: error)
      }
    }
  }

  private static func isTokenNotFoundError(_ error: (any Error)?) -> Bool {
    guard let nsError = error as NSError? else { return false }
    let expected = PacketTunnelProviderError.tokenNotFoundInKeychain as NSError
    return nsError.domain == expected.domain && nsError.code == expected.code
  }

  /// Log the disconnect reason from the NE.
  private static func logDisconnectError(_ error: (any Error)?) {
    if let nsError = error as NSError?,
      nsError.domain == ConnlibError.errorDomain,
      nsError.code == 0,
      let reason = nsError.userInfo["reason"] as? String
    {
      Log.error("Authentication failed: \(reason)")
    } else if let error {
      Log.error("Tunnel disconnected: \(error)")
    } else {
      Log.info("Tunnel disconnected externally, shutting down...")
    }
  }

  #if SYSTEM_EXTENSION
    @MainActor
    private func installSystemExtensionIfNeeded() async throws {
      let manager = SystemExtensionManager()
      let status = try await manager.check()

      switch status {
      case .installed:
        Log.info("System extension is up to date")
      case .needsInstall, .needsReplacement:
        Log.info("Installing system extension...")
        _ = try await manager.tryInstall()
        Log.info("System extension installed")
      }
    }
  #endif
}

// MARK: - Signal handling

private enum SignalAction {
  case shutdown
  case restart
  case promptForToken
}

@MainActor
private final class TunnelState {
  var isRestarting = false
  var hasPromptedForToken = false
}
