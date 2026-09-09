//
//  FirezoneCLI.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation
import NetworkExtension

struct FirezoneCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "firezone",
    abstract: "Firezone CLI",
    version: versionString,
    subcommands: [
      Connect.self,
      Disconnect.self,
      SignOut.self,
      Status.self,
      Resources.self,
      InternetResource.self,
      Extension.self,
    ],
    defaultSubcommand: Status.self
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
  static func load() async throws -> VPNConfigurationManager {
    let factory = NETunnelProviderManagerFactory()
    guard let vpnManager = try await VPNConfigurationManager.load(using: factory) else {
      throw CLIError("No VPN configuration found")
    }

    return vpnManager
  }

  @MainActor
  static func session(
    for vpnManager: VPNConfigurationManager
  ) throws -> any TunnelSessionProtocol {
    guard let session = vpnManager.session() else {
      throw CLIError("Failed to get VPN session")
    }

    return session
  }

  /// What the tunnel knows about the session, or `nil` when it isn't up to answer.
  ///
  /// An empty hash never matches the snapshot's, so the provider always sends the whole
  /// thing rather than reporting it unchanged.
  @MainActor
  static func state(from session: any TunnelSessionProtocol) async -> ConnlibState? {
    do {
      return try await IPCClient.pollUpdates(session: session, currentHash: Data()).state
    } catch {
      Log.debug("Tunnel did not answer the state poll: \(error)")

      return nil
    }
  }
}
