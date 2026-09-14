//
//  StatusCommand.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation

extension FirezoneCLI {
  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "status",
      abstract: "Report the current status."
    )

    @OptionGroup var global: GlobalOptions

    @MainActor
    func run() async throws {
      Log.useCLIOutput(debug: global.debug)

      try await Self.report()
    }

    @MainActor
    static func report() async throws {
      let vpnManager = try await VPNProfile.load()
      let session = try VPNProfile.session(for: vpnManager)

      switch try await IPCClient.status(session: session) {
      case .disconnected:
        print("Not connected.")
      case .connecting:
        print("Connecting...")
      case .connected(let accountSlug, let actorName):
        // The portal does not always name the actor, and warns when it doesn't.
        let account = accountSlug.flatMap { $0.isEmpty ? nil : $0 }
        let user = actorName.flatMap { $0.isEmpty ? nil : $0 }

        switch (account, user) {
        case (let account?, let user?): print("Signed in to \(account) as \(user).")
        case (let account?, nil): print("Signed in to \(account).")
        case (nil, let user?): print("Signed in as \(user).")
        case (nil, nil): print("Signed in.")
        }
      }
    }
  }
}
