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
      abstract: "Bring the tunnel up.",
      discussion: """
        Returns once the tunnel is up and leaves it running, since the tunnel lives in \
        the system extension rather than in this process. Use `disconnect` to stop it.
        """
    )

    @Option(name: .long, help: ArgumentHelp("API URL.", visibility: .hidden))
    var apiUrl: String?

    @Option(name: .long, help: ArgumentHelp("Auth base URL.", visibility: .hidden))
    var authBaseUrl: String?

    @Flag(name: .long, help: "Stay in the foreground and stop the tunnel on exit.")
    var foreground = false

    @MainActor
    mutating func run() async throws {
      Log.useCLIOutput()

      if foreground {
        // Supervising ties the tunnel's lifetime to ours, so the menu bar app should stay
        // closed for as long as we run. The helper that keeps it alive watches for this,
        // and would otherwise open the app the moment we stop, since we share its bundle
        // identifier. The app marks itself again the next time someone launches it. A
        // one-shot connect is over in seconds, so it leaves the sentinel alone.
        SharedAccess.clearAppRunning()
      }

      // Only what was actually asked for. The VPN profile is shared with the app, so
      // anything left unset here keeps the value the app stored.
      let apiURL = Self.setting(apiUrl, "FIREZONE_API_URL")
      let logFilter = Self.setting(nil, "FIREZONE_LOG_FILTER")

      // Only used to build the sign-in URL, never written to the profile.
      let authBaseURLOverride = Self.setting(authBaseUrl, "FIREZONE_AUTH_BASE_URL")

      try await SystemExtension.requireInstalled()

      let tunnel = try await startTunnel(
        overrides: ProviderOverrides(apiURL: apiURL, logFilter: logFilter)
      )

      // Fall back to what the app is configured with, so a self-hosted deployment
      // doesn't point someone at the public portal to fetch a token.
      let watcher = TunnelWatcher(
        session: tunnel.session,
        noTokenAdvice: SignIn.instructions(
          authBaseURL: authBaseURLOverride ?? tunnel.signIn.authURL,
          accountSlug: tunnel.signIn.accountSlug
        )
      )

      guard foreground else {
        try await watcher.waitUntilConnected()
        return
      }

      try await TunnelSupervisor(watcher: watcher).run()
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
