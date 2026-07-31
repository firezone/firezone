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
    await runHeadlessClient(FirezoneCLI.self)
  }
#endif

FirezoneApp.main()
