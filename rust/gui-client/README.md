# gui-client

This crate houses a GUI client for Linux and Windows.

## Setup (Ubuntu)

To compile natively for x86_64 Linux:

1. [Install rustup](https://rustup.rs/)
1. Install [pnpm](https://pnpm.io/installation)
1. `sudo apt-get install build-essential curl file pkg-config libgtk-3-dev libsoup-3.0-dev libayatana-appindicator3-dev librsvg2-dev libssl-dev libwebkit2gtk-4.1-dev libxdo-dev wget`

## Setup (Windows)

To compile natively for x86_64 Windows, install the following (winget commands shown):

1. PowerShell 7 — `winget install Microsoft.PowerShell`
1. Visual Studio C++ build tools (MSVC compiler + Windows SDK) —
   `winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`
1. rustup — `winget install Rustlang.Rustup`
1. mise — `winget install jdx.mise`
1. An editor of your choice (see [Recommended IDE Setup](#recommended-ide-setup))

`node` and `pnpm` are pinned in [`rust/.tool-versions`](../.tool-versions) and provided
by mise — you don't install them separately. After installing mise, activate it in
PowerShell 7 and install the toolchain from `rust/`:

```powershell
# Activate mise for the current session (add to $PROFILE to persist)
mise activate pwsh | Out-String | Invoke-Expression

# Install the pinned tools (node, pnpm, cargo-tauri, etc.)
mise install
```

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
# The release exe and deb package are up in the workspace.
stat ../target/release/firezone
stat ../target/release/bundle/deb/*.deb

# Windows:
# The release exe and MSI installer should be up in the workspace.
# The exe can run without being installed
stat ../target/release/Firezone.exe
stat ../target/release/bundle/msi/Firezone_0.0.0_x64_en-US.msi
```

## Signing the Windows MSI in GitHub CI

The MSI is signed in GitHub CI using the `firezone/firezone` repository's
secrets. This was originally set up using these guides for inspiration:

- https://melatonin.dev/blog/how-to-code-sign-windows-installers-with-an-ev-cert-on-github-actions/
- https://support.globalsign.com/code-signing/code-signing-using-azure-key-vault

Renewing / issuing a new code signing certificate and associated Azure entities is outside the scope of this section. Use the guides above if this needs to be done.

Instead, you'll most likely simply need to rotate the Azure `CodeSigning` Application's client secret.

To do so, login to [the Azure portal](https://portal.azure.com) using your `@firezoneprod.onmicrosoft.com` account.
Try to access it via the following [deep-link](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/51da0daa-39dd-4890-9018-e02609efc9c8).
If that doesn't work:

- Go to the `Microsoft Entra ID` service
- Click on `App Registrations`
- Make sure the tab `All applications` is selected
- Find and navigate to the `CodeSigning` app registration
- Client on `client credentials`
- Click `New client secret`
- Note down the secret value. This should be entered into the GitHub repository's secrets as `AZURE_CLIENT_SECRET`.

## Running (Windows)

A live dev session needs **two** processes running at once, each in its own
PowerShell 7 terminal. Make sure mise is activated in each (`mise activate pwsh | Out-String | Invoke-Expression`).

1. **Tunnel service** — run from an **elevated (Administrator)** terminal. It manages
   the system tunnel and serves the privileged IPC pipe:

   ```powershell
   mise run tunnel
   ```

   This runs `firezone-client-tunnel run-interactive`, which in a debug build serves
   the Tunnel IPC pipe without pinning it to `LocalSystem`, so the unprivileged GUI
   below can connect.

2. **GUI client** — from a normal (non-elevated) terminal. Connects to the Tunnel
   service above, skipping the pipe-owner check so it accepts the non-`LocalSystem` pipe:

   ```powershell
   mise run tauri-dev
   # equivalent to: cargo tauri dev -- -- --skip-tunnel-pipe-owner-check

   # You can call debug subcommands on the exe this way too, e.g.
   cargo tauri dev -- -- debug hostname

   # The exe is up in the workspace
   stat ../target/debug/Firezone.exe
   ```

   `tauri dev` starts the Vite dev server itself (via `beforeDevCommand`) and points the
   webview at it (`devUrl`), so you get hot-reload and client-side routing works. No
   separate frontend build is needed for dev.

The app's config and logs will be stored at
`C:\Users\$USER\AppData\Local\dev.firezone.client`.

> Note: `pnpm dev` does **not** work for this flow. `dev.bat` hard-codes `tauri dev`
> and forwards no arguments, so it can't pass `--skip-tunnel-pipe-owner-check`, and it
> doesn't start an elevated Tunnel service.

### What this workflow can't test

Running the GUI against a debug-build `run-interactive` Tunnel deliberately bypasses the named-pipe
ownership check, so it does **not** exercise the production pipe-ownership security
model (GUI ⇄ `LocalSystem` Tunnel service). It also doesn't cover MSI packaging, the
bundled Windows service, sparse-package registration, or the installed app identity.

To test installation end-to-end you need a real signed release MSI, which **cannot** be
produced locally: the installer is signed with AzureSignTool against HSM-backed keys
that are only available to CI. Use the GitHub CI pipeline to build a signed release MSI
(see [Signing the Windows MSI in GitHub CI](#signing-the-windows-msi-in-github-ci)).
`pnpm build` can still produce an *unsigned* MSI locally to sanity-check the build itself.

## Platform support

Ubuntu 22.04 and newer is supported.

Tauri says it should work on Windows 10, Version 1803 and up. Older versions may
work if you
[manually install WebView2](https://tauri.app/v1/guides/getting-started/prerequisites#2-webview2)

`x86_64` architecture is supported for Windows. `aarch64` and `x86_64` are supported for Linux.

## Threat model

See [Security](docs/security.md)

## Testing

See [Intended behavior](docs/intended_behavior.md)
