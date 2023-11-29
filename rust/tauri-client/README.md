# tauri-client

This crate houses a Windows GUI client based on Tauri.
It will likely be renamed to `windows-client` before the PR is opened.

## Building

Given this Git repo is in the dir "firezone":

```
# First-time setup - Install Tauri's dev server / hot-reload tool
cargo install cargo-tauri

# Navigate to this dir. This is not the Rust project's root, but it's the root for the whole Tauri project.
cd firezone/rust/tauri-client

# Builds a release exe
cargo tauri build

# The release exe should be up in the workspace
stat ../target/release/firezone-windows-client.exe
```

## Running

For development:

```
cd firezone/rust/tauri-client

# Tauri has some hot-reloading features. If the Rust code changes it will even recompile and restart the program for you.
cargo tauri dev

# You can call debug subcommands from this directory too
# e.g. this is equivalent to `cargo run -- debug`
cargo tauri dev -- -- debug

# Debug connlib GUI integration
cargo tauri dev -- -- debug-connlib
```

## Recommended IDE Setup

(From Tauri's default README)

- [VS Code](https://code.visualstudio.com/) + [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)
