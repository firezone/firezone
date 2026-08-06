//
//  X509Command.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation

extension FirezoneCLI {
  struct X509Details: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "x509",
      abstract: "Print diagnostics for the VPN configuration's X.509 identity and exit."
    )

    @MainActor
    func run() async throws {
      Log.useCLIOutput()

      let factory = NETunnelProviderManagerFactory()
      guard let vpnManager = try await VPNConfigurationManager.load(using: factory) else {
        throw CLIError("No VPN configuration found")
      }

      let persistentReference = try vpnManager.identityReference()
      let details = try await Task.detached(priority: .userInitiated) {
        try X509Identity.details(persistentReference: persistentReference)
      }.value

      print(details.textDescription, terminator: "")
    }
  }
}
