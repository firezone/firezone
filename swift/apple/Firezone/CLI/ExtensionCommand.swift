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
/// We are the app's own binary, so an activation request resolves against the same
/// `Firezone.app/Contents/Library/SystemExtensions` the app would use and can replace
/// an extension the user has already approved. What we cannot do is get a first
/// install approved, since that is a human answering a prompt in System Settings.
enum SystemExtension {
  static let restartAdvice =
    "System extension update is waiting on a restart. Restart your Mac to finish it."

  @MainActor
  static func requireInstalled() async throws {
    switch try await SystemExtensionManager(unattended: true).check() {
    case .installed:
      say("System extension is up to date")
    case .needsInstall:
      throw CLIError(
        "System extension is not installed. Launch Firezone.app to install it.")
    case .needsReboot:
      throw CLIError(restartAdvice)
    case .needsReplacement:
      #if DEBUG
        // Every build stamps a new CURRENT_PROJECT_VERSION, so a freshly built CLI
        // always disagrees with whatever the system still has running. Replacing it
        // would swap out the extension the app just installed on every connect.
        Log.warning("System extension is a different version, continuing anyway")
      #else
        try await replace()
      #endif
    }
  }

  /// Swaps an already-approved extension for the version we ship with.
  ///
  /// macOS does this without prompting, so a mismatch is ours to fix rather than
  /// something to send the user to the app for.
  @MainActor
  private static func replace() async throws {
    say("System extension is a different version, replacing it...")

    let status: SystemExtensionStatus
    do {
      status = try await SystemExtensionManager(unattended: true).tryInstall()
    } catch SystemExtensionError.needsUserApproval {
      throw CLIError(
        "System extension replacement needs approval. Launch Firezone.app to approve it.")
    }

    switch status {
    case .installed:
      say("System extension replaced")
    case .needsReboot:
      throw CLIError(restartAdvice)
    case .needsInstall, .needsReplacement:
      throw CLIError(
        "System extension is still a different version. Launch Firezone.app to update it.")
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

      @OptionGroup var global: GlobalOptions

      @MainActor
      func run() async throws {
        Log.useCLIOutput(debug: global.debug)

        switch try await SystemExtensionManager(unattended: true).check() {
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
