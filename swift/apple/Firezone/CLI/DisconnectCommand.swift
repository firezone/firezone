//
//  DisconnectCommand.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation
import NetworkExtension

extension FirezoneCLI {
  struct Disconnect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "disconnect",
      abstract: "Disconnect, keeping the stored token."
    )

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
      Log.useCLIOutput(debug: global.debug)

      let vpnManager = try await VPNProfile.load()
      let session = try VPNProfile.session(for: vpnManager)

      _ = await IPCClient.stopIfRunning(session: session)
    }
  }
}
