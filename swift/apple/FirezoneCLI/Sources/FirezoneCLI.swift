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

  @Option(name: .long, help: ArgumentHelp("API URL.", visibility: .hidden))
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
    Log.useCLIOutput()

    if signOut {
      try await performSignOut()
      return
    }

    let apiURL = Self.setting(apiUrl, "FIREZONE_API_URL", ConfigurationDefaults.apiURL)
    let accountSlug = Self.setting(
      self.accountSlug, "FIREZONE_ACCOUNT_SLUG", ConfigurationDefaults.accountSlug)
    let authBaseURL = Self.setting(
      authBaseUrl, "FIREZONE_AUTH_BASE_URL", ConfigurationDefaults.authURL)
    // No flag for this one yet; the environment variable is the only override.
    let logFilter =
      ProcessInfo.processInfo.environment["FIREZONE_LOG_FILTER"] ?? ConfigurationDefaults.logFilter
    let internetResourceEnabled =
      activateInternetResource
      || ProcessInfo.processInfo.environment["FIREZONE_ACTIVATE_INTERNET_RESOURCE"] == "1"

    Log.info("API URL: \(apiURL)")
    Log.info("Account slug: \(accountSlug.isEmpty ? "(empty)" : accountSlug)")
    Log.info("Internet resource: \(internetResourceEnabled)")

    try await verifySystemExtension()

    let session = try await startTunnel(
      overrides: ProviderOverrides(
        apiURL: apiURL,
        accountSlug: accountSlug,
        logFilter: logFilter,
        internetResourceEnabled: internetResourceEnabled
      )
    )

    let supervisor = TunnelSupervisor(session: session) {
      try await SignInPrompt.requestToken(authBaseURL: authBaseURL, accountSlug: accountSlug)
    }

    // A prompt may still be blocked on stdin with echo off when we stop.
    defer { SignInPrompt.restoreTerminal() }
    try await supervisor.run()
  }

  /// Command-line flag, then environment variable, then the shared default.
  private static func setting(_ flag: String?, _ variable: String, _ fallback: String) -> String {
    flag ?? ProcessInfo.processInfo.environment[variable] ?? fallback
  }

  // MARK: - Tunnel

  @MainActor
  private func startTunnel(overrides: ProviderOverrides) async throws -> any TunnelSessionProtocol {
    let factory = NETunnelProviderManagerFactory()
    let vpnManager: VPNConfigurationManager
    if let existing = try await VPNConfigurationManager.load(using: factory) {
      vpnManager = existing
    } else {
      Log.info("Creating VPN configuration...")
      vpnManager = try await VPNConfigurationManager(manager: factory.createManager())
    }

    // The extension reads providerConfiguration at start, so save before starting.
    try await vpnManager.save(overrides: overrides)
    try await vpnManager.enable()

    guard let session = vpnManager.session() else {
      throw ValidationError("Failed to get VPN session")
    }

    if let token = ProcessInfo.processInfo.environment["FIREZONE_TOKEN"].flatMap(Token.init) {
      try IPCClient.start(session: session, token: token.description)
    } else {
      // No token supplied, so the extension falls back to the one in the Keychain.
      try IPCClient.start(session: session)
    }

    Log.info("Tunnel started")

    return session
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

  @MainActor
  private func verifySystemExtension() async throws {
    switch try await SystemExtensionManager().check() {
    case .installed:
      Log.info("System extension is up to date")
    case .needsInstall:
      throw ValidationError(
        "System extension is not installed. Launch Firezone.app first to install it.")
    case .needsReplacement:
      throw ValidationError(
        "System extension version does not match this CLI. Launch Firezone.app to update it.")
    }
  }
}
