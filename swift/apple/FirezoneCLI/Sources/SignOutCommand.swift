//
//  SignOutCommand.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation
import NetworkExtension

extension FirezoneCLI {
  struct SignOut: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "sign-out",
      abstract: "Sign out and remove the stored token."
    )

    @MainActor
    func run() async throws {
      Log.useCLIOutput()

      let factory = NETunnelProviderManagerFactory()
      guard let vpnManager = try await VPNConfigurationManager.load(using: factory) else {
        throw ValidationError("No VPN configuration found")
      }

      try await IPCClient.signOut(session: VPNProfile.session(for: vpnManager))
      Log.info("Signed out successfully")
    }
  }
}
