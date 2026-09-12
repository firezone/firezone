//
//  CLIInstaller.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Foundation

  /// The command that puts the CLI on the PATH for installs that did not come from the `.pkg`.
  ///
  /// The sandbox stops us from doing this ourselves, and from handing Terminal a script that
  /// would: everything we write is quarantined, and Gatekeeper refuses to open a quarantined
  /// script. The user runs the command instead, which also puts the `sudo` prompt in front of
  /// the person who can answer it.
  enum CLIInstaller {
    static var installCommand: String {
      // The wrapper, not the binary beside it: the client only has the app's bundle
      // identity when started at its real path.
      let firezone = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/firezone")
        .path
        .replacingOccurrences(of: "'", with: "'\\''")

      return "sudo mkdir -p /usr/local/bin && sudo ln -sf '\(firezone)' /usr/local/bin/firezone"
    }
  }
#endif
