//
//  ExtensionCommand.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation

/// Shared system extension handling for the commands that need it.
enum SystemExtension {
  /// Stops the caller unless the installed extension matches this build, pointing at
  /// `extension install` rather than the GUI, which a headless host may not have.
  @MainActor
  static func requireInstalled() async throws {
    switch try await SystemExtensionManager().check() {
    case .installed:
      Log.info("System extension is up to date")
    case .needsInstall:
      throw CLIError("System extension is not installed. Run 'firezone-cli extension install'.")
    case .needsReplacement:
      throw CLIError(
        "System extension is a different version. Run 'firezone-cli extension install'.")
    }
  }
}

extension FirezoneCLI {
  struct Extension: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "extension",
      abstract: "Inspect and install the system extension.",
      subcommands: [Status.self, Install.self]
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

        switch try await SystemExtensionManager().check() {
        case .installed:
          print("installed")
        case .needsInstall:
          print("not installed")
          throw ExitCode(1)
        case .needsReplacement:
          print("different version installed")
          throw ExitCode(1)
        }
      }
    }

    struct Install: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the system extension, or replace a different version.",
        discussion: """
          macOS asks the logged-in user to approve the extension under System Settings > \
          General > Login Items & Extensions > Network Extensions, and this waits for that \
          to happen. Fleets can approve it ahead of time with an MDM system extension policy.
          """
      )

      @MainActor
      func run() async throws {
        Log.useCLIOutput()

        let manager = SystemExtensionManager()

        if try await manager.check() == .installed {
          Log.info("System extension is already up to date")
          return
        }

        Log.info("Requesting installation, waiting for approval if macOS asks for it...")

        switch try await manager.tryInstall() {
        case .installed:
          Log.info("System extension installed")
        case .needsInstall, .needsReplacement:
          throw CLIError("System extension did not finish installing.")
        }
      }
    }
  }
}
