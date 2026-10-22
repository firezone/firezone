//
//  main.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

#if os(macOS) && DEBUG
  import FirezoneKit
#endif

#if os(macOS)
  import ArgumentParser

  /// Runs an async command the way `@main` would. Binding the concrete type here is what
  /// picks the asynchronous `main()`; calling it on the protocol resolves to the
  /// synchronous one inherited from `ParsableCommand`.
  ///
  /// Returns `Never` deliberately: `main()` only exits on the way out of an error, and
  /// returning normally would carry on into the app and open its window.
  func runHeadlessClient<Command: AsyncParsableCommand>(_ command: Command.Type) async -> Never {
    await command.main()
    command.exit()
  }

  // The headless client is this same binary, reached through the symlink beside it at
  // Contents/MacOS/firezone-cli, which the wrapper script Contents/Resources/bin/firezone
  // starts at its real path. Run that way it keeps the app's bundle identity, and so can
  // see the VPN configuration and system extension that belong to the app. A separate
  // bundle could not: NETunnelProviderManager only hands an app the configurations that
  // app itself created. The comparison is case-sensitive on purpose: the app's own executable is
  // `Firezone`.
  let invokedAs = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
  if invokedAs == "firezone" || invokedAs == "firezone-cli" {
    // Reached through a symlink anywhere but Contents/MacOS, macOS gives us no bundle
    // at all, and with it no identity, no VPN configuration and no system extension.
    // Say so, rather than failing later on something that reads as unrelated.
    guard Bundle.main.bundleIdentifier != nil else {
      FileHandle.standardError.write(
        Data(
          """
          Run firezone through the wrapper script inside Firezone.app, for example
          /Applications/Firezone.app/Contents/Resources/bin/firezone.

          A symlink to the binary does not work, because it leaves the client without
          the app's identity. To have firezone on your PATH, add that directory instead:

            echo /Applications/Firezone.app/Contents/Resources/bin | sudo tee /etc/paths.d/firezone

          """.utf8))
      exit(1)
    }

    if invokedAs == "firezone-cli" {
      FileHandle.standardError.write(
        Data(
          """
          warning: firezone-cli is deprecated and will be removed in a future release; use firezone instead

          """.utf8))
    }

    await runHeadlessClient(FirezoneCLI.self)
  }
#endif

#if os(macOS) && DEBUG
  // A screenshot run wants exactly one window on the screen, and which one is
  // an argument. Each choice is its own app (see FirezoneApp.swift), picked
  // here because an app's scene list is fixed once its `main` runs.
  switch FirezoneKit.AppView.WindowDefinition.mockFromCommandLine() {
  case .main:
    UITestMainApp.main()
  case .settings:
    UITestSettingsApp.main()
  case nil:
    break
  }
#endif

FirezoneApp.main()
