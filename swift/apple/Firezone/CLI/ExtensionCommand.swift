//
//  ExtensionCommand.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation

/// Shared system extension handling for the commands that need it.
///
/// The CLI can only report on the extension. macOS resolves an activation request
/// against the requesting bundle's `Contents/Library/SystemExtensions`, and the
/// extension lives in `Firezone.app` rather than in here, so only the app can
/// install it.
///
/// The App Store build has no system extension at all: its tunnel is an app extension
/// that ships inside the app, so there is nothing to install or report on.
enum SystemExtension {
  @MainActor
  static func requireInstalled() async throws {
    guard BundleHelper.tunnelProviderKind == .systemExtension else { return }

    switch try await SystemExtensionManager().check() {
    case .installed:
      Log.info("System extension is up to date")
    case .needsInstall:
      throw CLIError(
        "System extension is not installed. Launch Firezone.app to install it.")
    case .needsReboot:
      throw CLIError(
        "System extension update is waiting on a restart. Restart your Mac to finish it.")
    case .needsReplacement:
      #if DEBUG
        // Every build stamps a new CURRENT_PROJECT_VERSION, and only the app can
        // activate the extension it just built, so a freshly built CLI always
        // disagrees with whatever the system still has running. Refusing to start
        // would mean relaunching the app after every build.
        Log.warning("System extension is a different version, continuing anyway")
      #else
        throw CLIError(
          "System extension is a different version. Launch Firezone.app to update it.")
      #endif
    }
  }
}

extension FirezoneCLI {
  struct Extension: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "extension",
      abstract: "Inspect the system extension.",
      subcommands: [Status.self]
    )

    struct Status: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether the system extension is installed and current.",
        discussion: "Exits non-zero unless the installed extension matches this build."
      )

      @MainActor
      func run() async throws {
        Log.useCLIOutput()

        guard BundleHelper.tunnelProviderKind == .systemExtension else {
          print("bundled with the app")

          return
        }

        switch try await SystemExtensionManager().check() {
        case .installed:
          print("installed")
        case .needsInstall:
          print("not installed")
          throw ExitCode(1)
        case .needsReplacement:
          print("different version installed")
          throw ExitCode(1)
        case .needsReboot:
          print("restart required to finish update")
          throw ExitCode(1)
        }
      }
    }
  }
}
