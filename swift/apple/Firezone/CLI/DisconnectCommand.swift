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

    @MainActor
    func run() async throws {
      Log.useCLIOutput()

      let vpnManager = try await VPNProfile.load()
      let session = try VPNProfile.session(for: vpnManager)

      guard await IPCClient.stopIfRunning(session: session) else {
        Log.info("Tunnel was not running")
        return
      }

      Log.info("Tunnel stopped")
    }
  }
}
