//
//  ConnectCommand.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation
import NetworkExtension

extension FirezoneCLI {
  struct Connect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "connect",
      abstract: "Bring the tunnel up and stay running. This is the default."
    )

    @Option(name: .long, help: ArgumentHelp("API URL.", visibility: .hidden))
    var apiUrl: String?

    @Flag(name: .long, help: "Activate Internet Resource.")
    var activateInternetResource = false

    @Option(name: .long, help: "Account slug.")
    var accountSlug: String?

    @Option(name: .long, help: ArgumentHelp("Auth base URL.", visibility: .hidden))
    var authBaseUrl: String?

    @MainActor
    mutating func run() async throws {
      Log.useCLIOutput()

      // Only what was actually asked for. The VPN profile is shared with the app, so
      // anything left unset here keeps the value the app stored.
      let apiURL = Self.setting(apiUrl, "FIREZONE_API_URL")
      let accountSlug = Self.setting(self.accountSlug, "FIREZONE_ACCOUNT_SLUG")
      let logFilter = Self.setting(nil, "FIREZONE_LOG_FILTER")
      let wantsInternetResource =
        activateInternetResource
        || ProcessInfo.processInfo.environment["FIREZONE_ACTIVATE_INTERNET_RESOURCE"] == "1"
      // swiftlint:disable:next discouraged_optional_boolean - nil leaves the stored value
      let internetResourceEnabled: Bool? = wantsInternetResource ? true : nil

      // Only used to build the sign-in URL, never written to the profile.
      let authBaseURL =
        Self.setting(authBaseUrl, "FIREZONE_AUTH_BASE_URL") ?? ConfigurationDefaults.authURL

      Log.info("API URL: \(apiURL ?? "(unchanged)")")
      Log.info("Account slug: \(accountSlug ?? "(unchanged)")")
      Log.info("Internet resource: \(internetResourceEnabled.map(String.init) ?? "(unchanged)")")

      try await SystemExtension.requireInstalled()

      let session = try await startTunnel(
        overrides: ProviderOverrides(
          apiURL: apiURL,
          accountSlug: accountSlug,
          logFilter: logFilter,
          internetResourceEnabled: internetResourceEnabled
        )
      )

      // Without a slug the URL lands on the account picker, same as before.
      let signInSlug = accountSlug ?? ConfigurationDefaults.accountSlug
      let supervisor = TunnelSupervisor(session: session) {
        try await SignInPrompt.requestToken(authBaseURL: authBaseURL, accountSlug: signInSlug)
      }

      // A prompt may still be blocked on stdin with echo off when we stop.
      defer { SignInPrompt.restoreTerminal() }
      try await supervisor.run()
    }

    /// Command-line flag, then environment variable, then nothing.
    private static func setting(_ flag: String?, _ variable: String) -> String? {
      flag ?? ProcessInfo.processInfo.environment[variable]
    }

    @MainActor
    private func startTunnel(
      overrides: ProviderOverrides
    ) async throws -> any TunnelSessionProtocol {
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

      let session = try VPNProfile.session(for: vpnManager)

      if let token = ProcessInfo.processInfo.environment["FIREZONE_TOKEN"].flatMap(Token.init) {
        try IPCClient.start(session: session, token: token.description)
      } else {
        // No token supplied, so the extension falls back to the one in the Keychain.
        try IPCClient.start(session: session)
      }

      Log.info("Tunnel started")

      return session
    }
  }
}
