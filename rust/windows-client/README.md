# windows-client

This crate houses a Windows GUI client.

## Building

From this dir:

```
# First-time setup - Install Tauri's dev server / hot-reload tool
cargo install tauri-cli

# Builds a release exe
cargo tauri build

# The release exe, MSI, and NSIS installer should be up in the workspace.
# The exe can run without being installed
stat ../target/release/firezone-windows-client.exe
stat ../target/release/bundle/msi/firezone-windows-client_0.0.0_x64_en-US.msi
stat ../target/release/bundle/nsis/firezone-windows-client_0.0.0_x64-setup.exe
```

## Running

From this dir:

```
# Tauri has some hot-reloading features. If the Rust code changes it will even recompile and restart the program for you.
cargo tauri dev

# You can call debug subcommands on the exe from this directory too
# e.g. this is equivalent to `cargo run -- debug`
cargo tauri dev -- -- debug

# Debug connlib GUI integration
cargo tauri dev -- -- debug-connlib

# The exe is up in the workspace
stat ../target/debug/firezone-windows-client.exe
```

## Recommended IDE Setup

(From Tauri's default README)

- [VS Code](https://code.visualstudio.com/) + [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)
