//
//  FirezoneCLI.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import Foundation
import FirezoneKit
import NetworkExtension
import SystemExtensions

@main
struct FirezoneCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "firezone",
    abstract: "Firezone headless Client",
    version: Self.versionString,
    subcommands: [SignIn.self, SignOut.self]
  )

  @Option(name: .shortAndLong, help: "Log directory path.")
  var logDir: String?

  @Option(name: .shortAndLong, help: "Max partition time for log files.")
  var maxPartitionTime: String?

  @Option(name: .shortAndLong, help: ArgumentHelp("API URL.", visibility: .hidden))
  var apiUrl: String?

  @Option(name: .long, help: "Friendly name for this device.")
  var firezoneName: String?

  @Option(name: .shortAndLong, help: "Device identifier (auto-generated if not set).")
  var firezoneId: String?

  @Flag(name: .long, help: "Activate Internet Resource.")
  var activateInternetResource = false

  @Flag(name: .long, help: "Disable telemetry.")
  var noTelemetry = false

  @Flag(name: .long, help: ArgumentHelp("Validate config and exit.", visibility: .hidden))
  var check = false

  @Flag(name: .long, help: ArgumentHelp("Exit after tunnel connects.", visibility: .hidden))
  var exit = false

  private static var versionString: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    return "\(version) (\(build))"
  }

  mutating func run() async throws {
    let apiURL =
      self.apiUrl
      ?? ProcessInfo.processInfo.environment["FIREZONE_API_URL"]
      ?? "wss://api.firezone.dev/"

    let firezoneName =
      self.firezoneName
      ?? ProcessInfo.processInfo.environment["FIREZONE_NAME"]

    let firezoneId =
      self.firezoneId
      ?? ProcessInfo.processInfo.environment["FIREZONE_ID"]
      ?? Self.getOrCreateDeviceId()

    let internetResourceEnabled =
      self.activateInternetResource
      || ProcessInfo.processInfo.environment["FIREZONE_ACTIVATE_INTERNET_RESOURCE"] == "1"

    let noTelemetry =
      self.noTelemetry
      || ProcessInfo.processInfo.environment["FIREZONE_NO_TELEMETRY"] == "1"

    // Load token: env var first, then Keychain
    let token: Token
    if let envToken = ProcessInfo.processInfo.environment["FIREZONE_TOKEN"],
      let t = Token(envToken)
    {
      token = t
    } else if let t = try Token.load() {
      token = t
    } else {
      throw ValidationError(
        "No token found. Set FIREZONE_TOKEN or run 'firezone sign-in' first."
      )
    }

    if check {
      Log.info("Configuration valid")
      return
    }

    // Check/install system extension
    try await installSystemExtensionIfNeeded()

    // Load or create VPN configuration
    let vpnManager: VPNConfigurationManager
    if let existing = try await VPNConfigurationManager.load() {
      vpnManager = existing
    } else {
      Log.info("Creating VPN configuration...")
      vpnManager = try await VPNConfigurationManager()
    }

    try await vpnManager.enable()

    guard let session = vpnManager.session() else {
      throw CleanExit.message("Failed to get VPN session")
    }

    let accountSlug =
      ProcessInfo.processInfo.environment["FIREZONE_ACCOUNT_SLUG"] ?? ""

    let configuration = TunnelConfiguration(
      apiURL: apiURL,
      accountSlug: accountSlug,
      logFilter: "info",
      internetResourceEnabled: internetResourceEnabled
    )

    try IPCClient.start(session: session, token: token.description, configuration: configuration)
    Log.info("Tunnel started")

    // Subscribe to VPN status updates
    IPCClient.subscribeToVPNStatusUpdates(session: session) { status in
      switch status {
      case .connected:
        Log.info("Tunnel connected")
        if self.exit {
          Foundation.exit(0)
        }
      case .disconnected:
        Log.info("Tunnel disconnected")
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

    // Set up signal handlers
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGHUP, SIG_IGN)

    sigintSource.setEventHandler {
      Log.info("Caught SIGINT, shutting down...")
      session.stopTunnel()
      Foundation.exit(0)
    }

    sigtermSource.setEventHandler {
      Log.info("Caught SIGTERM, shutting down...")
      session.stopTunnel()
      Foundation.exit(0)
    }

    sighupSource.setEventHandler {
      Log.info("Caught SIGHUP, restarting tunnel...")
      session.stopTunnel()
      do {
        try IPCClient.start(
          session: session, token: token.description, configuration: configuration)
        Log.info("Tunnel restarted")
      } catch {
        Log.error(error)
        Foundation.exit(1)
      }
    }

    sigintSource.resume()
    sigtermSource.resume()
    sighupSource.resume()

    // Keep process alive
    dispatchMain()
  }

  private static func getOrCreateDeviceId() -> String {
    let key = "firezoneId"
    if let savedId = UserDefaults.standard.string(forKey: key) {
      return savedId
    }
    let newId = UUID().uuidString
    UserDefaults.standard.set(newId, forKey: key)
    return newId
  }

  private func installSystemExtensionIfNeeded() async throws {
    let manager = SystemExtensionManager()

    let status = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<SystemExtensionStatus, Error>) in
      manager.sendRequest(
        requestType: .check,
        identifier: VPNConfigurationManager.bundleIdentifier,
        continuation: continuation
      )
    }

    switch status {
    case .installed:
      Log.info("System extension is up to date")
    case .needsInstall, .needsReplacement:
      Log.info("Installing system extension...")
      let _ = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<SystemExtensionStatus, Error>) in
        manager.sendRequest(
          requestType: .install,
          identifier: VPNConfigurationManager.bundleIdentifier,
          continuation: continuation
        )
      }
      Log.info("System extension installed")
    }
  }
}

// MARK: - Subcommands

struct SignIn: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sign-in",
    abstract: "Sign in via browser-based authentication."
  )

  @Option(name: .long, help: "Auth base URL.")
  var authBaseUrl: String?

  @Option(name: .long, help: "Account slug.")
  var accountSlug: String?

  mutating func run() async throws {
    let authBaseURL =
      self.authBaseUrl
      ?? ProcessInfo.processInfo.environment["FIREZONE_AUTH_BASE_URL"]
      ?? "https://app.firezone.dev"

    let accountSlug =
      self.accountSlug
      ?? ProcessInfo.processInfo.environment["FIREZONE_ACCOUNT_SLUG"]

    guard var components = URLComponents(string: authBaseURL) else {
      throw ValidationError("Invalid auth base URL: \(authBaseURL)")
    }

    if let slug = accountSlug, !slug.isEmpty {
      components.path = (components.path as NSString).appendingPathComponent(slug)
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

    try token.save()
    print("Token saved successfully. You can now run 'firezone' to connect.")
  }
}

struct SignOut: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sign-out",
    abstract: "Sign out by removing the stored token."
  )

  @Flag(name: .shortAndLong, help: "Skip confirmation prompt.")
  var force = false

  mutating func run() async throws {
    if !force {
      print("Are you sure you want to sign out? [y/N] ", terminator: "")
      fflush(stdout)
      guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
        ["y", "yes"].contains(answer.lowercased())
      else {
        print("Cancelled.")
        return
      }
    }

    try Token.delete()
    print("Token removed successfully.")
  }
}
