//
//  CLIInstaller.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Foundation

  /// Puts the headless client on the PATH for installs that did not come from the `.pkg`.
  ///
  /// We are sandboxed, so we can neither write `/usr/local/bin` nor ask for the privileges to
  /// do so. Instead we write a script into our own container and hand it to Terminal, which is
  /// not sandboxed and can prompt for `sudo`. The script does what
  /// `scripts/build/macos-pkg-scripts/postinstall` does for the `.pkg`; keep the two in step.
  enum CLIInstaller {
    static func writeInstallScript() throws -> URL {
      let fileManager = FileManager.default
      var scriptURL = fileManager
        .temporaryDirectory
        .appendingPathComponent("install-firezone-cli.command")

      try script().write(to: scriptURL, atomically: true, encoding: .utf8)
      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

      // Everything a sandboxed app writes is quarantined, and Gatekeeper reports a
      // quarantined unsigned script as damaged rather than as blocked.
      var withoutQuarantine = URLResourceValues()
      withoutQuarantine.quarantineProperties = nil
      try scriptURL.setResourceValues(withoutQuarantine)

      return scriptURL
    }

    private static func script() -> String {
      let bundlePath = Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")

      return """
        #!/bin/bash

        set -euo pipefail

        # The wrapper, not the binary beside it: the client only has the app's bundle
        # identity when started at its real path.
        firezone='\(bundlePath)/Contents/Resources/firezone'

        echo "This symlinks"
        echo "  $firezone"
        echo "to /usr/local/bin/firezone and writes shell completions alongside it."
        echo "Both need administrator privileges."
        echo

        sudo mkdir -p /usr/local/bin
        sudo ln -sf "$firezone" /usr/local/bin/firezone

        install_completion() {
            local shell="$1"
            local path="$2"

            sudo mkdir -p "$(dirname "$path")"
            "$firezone" --generate-completion-script "$shell" | sudo tee "$path" >/dev/null
        }

        # Each of these is where the shell picks completions up on its own. Best-effort,
        # because putting the client on the PATH is what this is for and a shell nobody
        # uses must not fail it.
        install_completion zsh /usr/local/share/zsh/site-functions/_firezone || true
        install_completion bash /usr/local/etc/bash_completion.d/firezone || true
        install_completion fish /usr/local/share/fish/vendor_completions.d/firezone.fish || true

        echo
        echo "Done. Open a new terminal and run 'firezone --help'."
        """
    }
  }
#endif
