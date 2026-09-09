//
//  ResourcesCommand.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation

extension FirezoneCLI {
  struct Resources: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "resources",
      abstract: "Inspect the Resources this Client can reach.",
      subcommands: [List.self],
      defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the Resources this Client can reach. This is the default."
      )

      @MainActor
      func run() async throws {
        Log.useCLIOutput()

        let vpnManager = try await VPNProfile.load()
        let session = try VPNProfile.session(for: vpnManager)

        guard let state = await VPNProfile.state(from: session) else {
          throw CLIError("Not connected.")
        }

        var rows: [(String, String, String)] = [("NAME", "ADDRESS", "STATUS")]

        // A `nil` list is the portal not having sent one yet, which has nothing to
        // print either way.
        rows += (state.resources ?? []).map { ($0.name, $0.address ?? "", $0.status.rawValue) }

        let nameWidth = rows.map { $0.0.count }.max() ?? 0
        let addressWidth = rows.map { $0.1.count }.max() ?? 0

        for (name, address, status) in rows {
          let paddedName = name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
          let paddedAddress = address.padding(toLength: addressWidth, withPad: " ", startingAt: 0)

          print("\(paddedName)  \(paddedAddress)  \(status)")
        }
      }
    }
  }
}
