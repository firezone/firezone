//
//  InternetResourceCommand.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation
import NetworkExtension

extension FirezoneCLI {
  struct InternetResource: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "internet-resource",
      abstract: "Turn the Internet Resource on or off.",
      subcommands: [Enable.self, Disable.self]
    )

    struct Enable: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Route traffic through the Internet Resource."
      )

      @OptionGroup var global: GlobalOptions

      @MainActor
      func run() async throws {
        try await InternetResource.apply(enabled: true, debug: global.debug)
      }
    }

    struct Disable: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Stop routing traffic through the Internet Resource."
      )

      @OptionGroup var global: GlobalOptions

      @MainActor
      func run() async throws {
        try await InternetResource.apply(enabled: false, debug: global.debug)
      }
    }

    /// The profile is shared with the app, so the setting is stored there as well as
    /// pushed to a running tunnel: storing alone would not reach a live session, and
    /// pushing alone would be forgotten at the next start.
    @MainActor
    fileprivate static func apply(enabled: Bool, debug: Bool) async throws {
      Log.useCLIOutput(debug: debug)

      let vpnManager = try await VPNProfile.load()
      try await vpnManager.save(overrides: ProviderOverrides(internetResourceEnabled: enabled))

      if let session = vpnManager.session(),
        [.connected, .connecting, .reasserting].contains(session.status)
      {
        try await IPCClient.setInternetResourceEnabled(session: session, enabled)
      }

      say("Internet Resource \(enabled ? "enabled" : "disabled")")
    }
  }
}
