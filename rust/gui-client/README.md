# gui-client

This crate houses a GUI client for Linux and Windows.

## Setup (Ubuntu)

To compile natively for x86_64 Linux:

1. [Install rustup](https://rustup.rs/)
1. Install [pnpm](https://pnpm.io/installation)
1. `sudo apt-get install at-spi2-core gcc libwebkit2gtk-4.0-dev libssl-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev pkg-config xvfb`

## Setup (Windows)

To compile natively for x86_64 Windows:

1. [Install rustup](https://rustup.rs/)
1. Install [pnpm](https://pnpm.io/installation)

### Recommended IDE Setup

(From Tauri's default README)

- [VS Code](https://code.visualstudio.com/)
- [Tauri](https://marketplace.visualstudio.com/items?itemName=tauri-apps.tauri-vscode)
- [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)

## Building

Builds are best started from the frontend tool `pnpm`. This ensures typescript
and css is compiled properly before bundling the application.

See the [`package.json`](./package.json) script for more details as to what's
going on under the hood.

```bash
# Builds a release exe
pnpm build

# Linux:
# The release exe, AppImage with bundled WebView, and deb package are up in the workspace.
stat ../target/release/firezone
stat ../target/release/bundle/appimage/*.AppImage
stat ../target/release/bundle/deb/*.deb

# Windows:
# The release exe and MSI installer should be up in the workspace.
# The exe can run without being installed
stat ../target/release/Firezone.exe
stat ../target/release/bundle/msi/Firezone_0.0.0_x64_en-US.msi
```

## Running

From this dir:

```powershell
# This will start the frontend tools in watch mode and then run `tauri dev`
pnpm dev

# You can call debug subcommands on the exe from this directory too
# e.g. this is equivalent to `cargo run -- debug hostname`
cargo tauri dev -- -- debug hostname

# The exe is up in the workspace
stat ../target/debug/Firezone.exe
```

The app's config and logs will be stored at
`C:\Users\$USER\AppData\Local\dev.firezone.client`.

## Platform support

Ubuntu 20.04 and newer is supported.

Tauri says it should work on Windows 10, Version 1803 and up. Older versions may
work if you
[manually install WebView2](https://tauri.app/v1/guides/getting-started/prerequisites#2-webview2)

`x86_64` architecture is supported at this time. See
[this issue](https://github.com/firezone/firezone/issues/2992) for `aarch64`
support.

## Threat model

See [Security](docs/security.md)

## Testing

See [Intended behavior](docs/intended_behavior.md)
