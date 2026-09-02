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

      // Connecting from a terminal means the menu bar app should stay closed. The helper
      // that keeps it alive watches for this, and would otherwise open the app the moment
      // we stop, since we share its bundle identifier. The app marks itself again the
      // next time someone launches it.
      SharedAccess.clearAppRunning()

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
      let authBaseURLOverride = Self.setting(authBaseUrl, "FIREZONE_AUTH_BASE_URL")

      Log.info("API URL: \(apiURL ?? "(unchanged)")")
      Log.info("Account slug: \(accountSlug ?? "(unchanged)")")
      Log.info("Internet resource: \(internetResourceEnabled.map(String.init) ?? "(unchanged)")")

      try await SystemExtension.requireInstalled()

      let tunnel = try await startTunnel(
        overrides: ProviderOverrides(
          apiURL: apiURL,
          accountSlug: accountSlug,
          logFilter: logFilter,
          internetResourceEnabled: internetResourceEnabled
        )
      )

      // Fall back to what the app is configured with, so a self-hosted deployment
      // doesn't point someone at the public portal to fetch a token.
      let supervisor = TunnelSupervisor(
        session: tunnel.session,
        noTokenAdvice: SignIn.instructions(
          authBaseURL: authBaseURLOverride ?? tunnel.signIn.authURL,
          accountSlug: accountSlug ?? tunnel.signIn.accountSlug
        )
      )

      try await supervisor.run()
    }

    /// Command-line flag, then environment variable, then nothing.
    private static func setting(_ flag: String?, _ variable: String) -> String? {
      flag ?? ProcessInfo.processInfo.environment[variable]
    }

    @MainActor
    private func startTunnel(
      overrides: ProviderOverrides
    ) async throws -> (session: any TunnelSessionProtocol, signIn: SignInSettings) {
      let factory = NETunnelProviderManagerFactory()
      let vpnManager: VPNConfigurationManager
      if let existing = try await VPNConfigurationManager.load(using: factory) {
        vpnManager = existing
      } else {
        Log.info("Creating VPN configuration...")
        vpnManager = try await VPNConfigurationManager.create(using: factory)
      }

      // The extension reads providerConfiguration at start, so save before starting.
      try await vpnManager.save(overrides: overrides)
      try await vpnManager.enable()

      let signIn = try vpnManager.signInSettings()
      let session = try VPNProfile.session(for: vpnManager)

      // Piped in beats the environment, and either beats whatever the Keychain has,
      // which is what the extension falls back to when handed nothing.
      let supplied =
        SignIn.pipedToken()
        ?? ProcessInfo.processInfo.environment["FIREZONE_TOKEN"].flatMap(Token.init)

      if let supplied {
        try IPCClient.start(
          session: session,
          token: supplied.description,
          identityReference: nil
        )
      } else {
        try IPCClient.start(session: session)
      }

      Log.info("Tunnel started")

      return (session, signIn)
    }
  }
}
