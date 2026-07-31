//
//  FirezoneCLI.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation
import NetworkExtension

@main
struct FirezoneCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "firezone-cli",
    abstract: "Firezone headless Client",
    version: versionString,
    subcommands: [Connect.self, SignOut.self, Extension.self],
    defaultSubcommand: Connect.self
  )

  static var versionString: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    return "\(version) (\(build))"
  }
}

/// Something went wrong at runtime, as opposed to `ValidationError`, which is for a
/// command line we couldn't make sense of. Keeps the exit code off EX_USAGE and stops
/// us printing usage at someone whose arguments were fine.
struct CLIError: Error, LocalizedError {
  let errorDescription: String?

  init(_ message: String) {
    errorDescription = message
  }
}

/// Shared plumbing for the commands that talk to the VPN profile.
enum VPNProfile {
  @MainActor
  static func session(
    for vpnManager: VPNConfigurationManager
  ) throws -> any TunnelSessionProtocol {
    guard let session = vpnManager.session() else {
      throw CLIError("Failed to get VPN session")
    }

    return session
  }
}
