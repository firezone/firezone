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

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
      Log.useCLIOutput(debug: global.debug)

      let vpnManager = try await VPNProfile.load()

      try await IPCClient.signOut(session: VPNProfile.session(for: vpnManager))
    }
  }
}
