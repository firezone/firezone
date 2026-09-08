//
//  StatusCommand.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation
import NetworkExtension

extension FirezoneCLI {
  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "status",
      abstract: "Report the sign-in, tunnel and Internet Resource state."
    )

    @MainActor
    func run() async throws {
      Log.useCLIOutput()

      let vpnManager = try await VPNProfile.load()
      let session = try VPNProfile.session(for: vpnManager)
      let state = await VPNProfile.state(from: session)
      let internetResourceEnabled = try vpnManager.internetResourceEnabled()

      // The provider only answers the poll while it is running, which is as close to
      // "signed in" as anything reachable from here gets.
      var rows: [(String, String)] = [("Signed in", state == nil ? "no" : "yes")]

      if let accountSlug = state?.accountSlug, !accountSlug.isEmpty {
        rows.append(("Account", accountSlug))
      }

      rows.append(("Tunnel", Self.describe(session.status)))
      rows.append(("Internet Resource", internetResourceEnabled ? "enabled" : "disabled"))

      let width = rows.map { $0.0.count }.max() ?? 0

      for (label, value) in rows {
        let paddedLabel = label.padding(toLength: width, withPad: " ", startingAt: 0)

        print("\(paddedLabel)  \(value)")
      }
    }

    private static func describe(_ status: NEVPNStatus) -> String {
      switch status {
      case .invalid: return "invalid"
      case .disconnected: return "disconnected"
      case .connecting: return "connecting"
      case .connected: return "connected"
      case .reasserting: return "reasserting"
      case .disconnecting: return "disconnecting"
      @unknown default: return "unknown"
      }
    }
  }
}
