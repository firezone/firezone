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
      let state = await VPNProfile.state(from: session)

      // The provider only answers the poll while it is running, which is as close to
      // "signed in" as anything reachable from here gets.
      guard let state else {
        print("Not signed in.")
        return
      }

      // The portal does not always name the actor, and warns when it doesn't.
      let account = state.accountSlug.flatMap { $0.isEmpty ? nil : $0 }
      let user = state.actorName.flatMap { $0.isEmpty ? nil : $0 }

      switch (account, user) {
      case let (account?, user?): print("Signed in to \(account) as \(user).")
      case let (account?, nil): print("Signed in to \(account).")
      case let (nil, user?): print("Signed in as \(user).")
      case (nil, nil): print("Signed in.")
      }
    }
  }
}
