//
//  main.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

#if os(macOS)
  import ArgumentParser

  /// Runs an async command the way `@main` would. Binding the concrete type here is what
  /// picks the asynchronous `main()`; calling it on the protocol resolves to the
  /// synchronous one inherited from `ParsableCommand`.
  func runHeadlessClient<Command: AsyncParsableCommand>(_ command: Command.Type) async {
    await command.main()
  }

  // The headless client is this same binary, reached through a symlink sitting next to
  // it in Contents/MacOS. Running it that way means it keeps the app's bundle identity,
  // and so can see the VPN configuration and system extension that belong to the app. A
  // separate bundle could not: NETunnelProviderManager only hands an app the
  // configurations that app itself created.
  if URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
    == "firezone-cli"
  {
    // Reached through a symlink from outside the bundle, macOS gives us no bundle at
    // all, and with it no identity, no VPN configuration and no system extension. Say
    // so, rather than failing later on something that reads as unrelated.
    guard Bundle.main.bundleIdentifier != nil else {
      FileHandle.standardError.write(
        Data(
          """
          Run firezone-cli from inside Firezone.app, for example
          /Applications/Firezone.app/Contents/MacOS/firezone-cli.

          Putting that directory on your PATH works. A symlink to it from somewhere
          else does not, because it leaves the client without the app's identity.

          """.utf8))
      exit(1)
    }

    await runHeadlessClient(FirezoneCLI.self)
  }
#endif

FirezoneApp.main()
