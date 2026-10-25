//
//  HostCandidatesCommand.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation
import Network
import NetworkExtension

extension FirezoneCLI {
  /// Private API for benchmarking direct links, without any stability guarantees.
  struct HostCandidates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "host-candidates",
      abstract: "Manage additional host candidates.",
      shouldDisplay: false,
      subcommands: [Add.self, Remove.self, List.self, Clear.self]
    )

    struct Add: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Advertise a local IP as an additional host candidate."
      )

      @Argument var ip: String

      @OptionGroup var global: GlobalOptions

      func validate() throws {
        try HostCandidates.validate(ip)
      }

      @MainActor
      func run() async throws {
        try await HostCandidates.update(debug: global.debug) { ips in
          if !ips.contains(ip) { ips.append(ip) }
        }
      }
    }

    struct Remove: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Stop advertising a local IP as an additional host candidate."
      )

      @Argument var ip: String

      @OptionGroup var global: GlobalOptions

      func validate() throws {
        try HostCandidates.validate(ip)
      }

      @MainActor
      func run() async throws {
        try await HostCandidates.update(debug: global.debug) { ips in
          ips.removeAll { $0 == ip }
        }
      }
    }

    struct List: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the additional host candidates."
      )

      @OptionGroup var global: GlobalOptions

      @MainActor
      func run() async throws {
        Log.useCLIOutput(debug: global.debug)

        for ip in try await VPNProfile.load().additionalHostCandidates() {
          print(ip)
        }
      }
    }

    struct Clear: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Remove all additional host candidates."
      )

      @OptionGroup var global: GlobalOptions

      @MainActor
      func run() async throws {
        try await HostCandidates.update(debug: global.debug) { ips in
          ips.removeAll()
        }
      }
    }

    fileprivate static func validate(_ ip: String) throws {
      guard IPv4Address(ip) != nil || IPv6Address(ip) != nil else {
        throw ValidationError("'\(ip)' is not an IP address.")
      }
    }

    /// Stored in the profile and pushed to a running tunnel, like the Internet Resource.
    @MainActor
    fileprivate static func update(
      debug: Bool,
      _ change: (inout [String]) -> Void
    ) async throws {
      Log.useCLIOutput(debug: debug)

      let vpnManager = try await VPNProfile.load()
      var ips = try vpnManager.additionalHostCandidates()
      change(&ips)
      try await vpnManager.save(overrides: ProviderOverrides(additionalHostCandidates: ips))

      if let session = vpnManager.session(),
        [.connected, .connecting, .reasserting].contains(session.status)
      {
        try await IPCClient.setAdditionalHostCandidates(session: session, ips)
      }
    }
  }
}
