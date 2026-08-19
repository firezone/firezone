# gui-client

This crate houses a GUI client for Linux and Windows.

## Setup (Ubuntu)

To compile natively for x86_64 Linux:

1. [Install rustup](https://rustup.rs/)
1. Install [pnpm](https://pnpm.io/installation)
1. `sudo apt-get install build-essential curl file pkg-config libgtk-3-dev libsoup-3.0-dev libayatana-appindicator3-dev librsvg2-dev libssl-dev libwebkit2gtk-4.1-dev libxdo-dev wget`
1. The `firezone-client` group, which the installer creates in production. The GUI checks
   for membership at startup and the Tunnel service's socket is group-readable only:

   ```bash
   sudo groupadd --system firezone-client
   sudo usermod -aG firezone-client "$USER" # log back in afterwards
   ```

## Setup (Windows)

To compile natively for x86_64 Windows, install the following (winget commands shown):

1. PowerShell 7 — `winget install Microsoft.PowerShell`
1. Visual Studio C++ build tools (MSVC compiler + Windows SDK) —
   `winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"`
1. rustup — `winget install Rustlang.Rustup`
1. mise — `winget install jdx.mise`
1. **Sudo for Windows** (Windows 11 24H2 or later), enabled under Settings > System >
   Advanced and configured to elevate inline (`sudo config --enable normal`). A new
   console does not process ANSI escapes and mangles the Tunnel service's logs.
1. An editor of your choice (see [Recommended IDE Setup](#recommended-ide-setup))

`node` and `pnpm` are pinned in [`rust/.tool-versions`](../.tool-versions) and provided
by mise — you don't install them separately. After installing mise, activate it in
PowerShell 7 and install the toolchain from `rust/`:

```powershell
# Activate mise for the current session
mise activate pwsh | Out-String | Invoke-Expression

# Persist it. `-Force` creates `$PROFILE` and its directory, which do not exist yet.
# A `$PROFILE` under `Documents\WindowsPowerShell\` means you are in 5.1, not 7.
New-Item -ItemType File -Path $PROFILE -Force
Add-Content $PROFILE 'mise activate pwsh | Out-String | Invoke-Expression'

# Tab completions
mise completion powershell | Add-Content $PROFILE

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

Windows release artifacts, including pull-request builds, are signed in GitHub
CI with AzureSignTool and an HSM-backed certificate in Azure Key Vault. GitHub
obtains an Entra token through workload identity federation; there is no client
secret to create or rotate.

The Entra `CodeSigning` application, its GitHub OIDC credential, and the Key
Vault are managed in the
[`firezone/infra`](https://github.com/firezone/infra/tree/main/terraform/workspaces)
production Terraform workspaces. The repository variables consumed by the
workflows are:

- `AZURE_CODESIGNING_CLIENT_ID`
- `AZURE_CODESIGNING_TENANT_ID`
- `AZURE_CODESIGNING_KEY_VAULT_URI`
- `AZURE_CODESIGNING_CERTIFICATE_NAME`

Renewing or replacing the non-exportable code-signing certificate remains a
manual Azure Key Vault operation. Do not replace the federated credential in
the portal; update and apply the production Terraform configuration instead.

## Running (Windows)

A live dev session needs **two** processes running at once, each in its own
PowerShell 7 terminal. Make sure mise is activated in each (`mise activate pwsh | Out-String | Invoke-Expression`).

1. **Tunnel service** — run from a normal terminal. It manages the system tunnel and
   serves the privileged IPC pipe; the task elevates only the service binary, so expect
   a UAC prompt:

   ```powershell
   mise run tunnel
   ```

   This runs `firezone-client-tunnel run-interactive --skip-peer-verification`, which in a
   debug build serves the Tunnel IPC pipe without pinning it to `LocalSystem`, so the
   unprivileged, non-installed GUI below can connect. Drop the flag to exercise the
   pipe-owner check against an installed GUI.

2. **GUI client** — from a normal (non-elevated) terminal. Connects to the Tunnel
   service above, skipping the pipe-owner check so it accepts the non-`LocalSystem` pipe:

   ```powershell
   mise run dev
   # equivalent to: cargo tauri dev -- -- --skip-peer-verification

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
> and forwards no arguments, so it can't pass `--skip-peer-verification`, and it
> doesn't start an elevated Tunnel service.

### What this workflow can't test

Running the GUI against a debug-build `run-interactive --skip-peer-verification` Tunnel deliberately
bypasses the named-pipe ownership check, so it does **not** exercise the production pipe-ownership
security model (GUI ⇄ `LocalSystem` Tunnel service). It also doesn't cover MSI packaging, the
bundled Windows service, sparse-package registration, or the installed app identity.

To test installation end-to-end you need a real signed release MSI, which **cannot** be
produced locally: the installer is signed with AzureSignTool against HSM-backed keys
that are only available to CI. Use the GitHub CI pipeline to build a signed release MSI
(see [Signing the Windows MSI in GitHub CI](#signing-the-windows-msi-in-github-ci)).
`pnpm build` can still produce an _unsigned_ MSI locally to sanity-check the build itself.

## Platform support

Ubuntu 22.04 and newer is supported.

Tauri says it should work on Windows 10, Version 1803 and up. Older versions may
work if you
[manually install WebView2](https://tauri.app/v1/guides/getting-started/prerequisites#2-webview2)

`x86_64` architecture is supported for Windows. `aarch64` and `x86_64` are supported for Linux.

## X.509 device identity

The Client can authenticate its portal connection with an MDM-provisioned X.509
certificate over mutual TLS. Whether a certificate is used is decided per device
by what the platform keystore holds: when the Tunnel service finds a currently
valid certificate whose subject CN is `dev.firezone.device-trust` and whose
extended key usage permits TLS client authentication, it connects to the
portal's mTLS endpoint and presents it. Otherwise it connects as it always has.

Private-key bytes are never exported. Every handshake signature is delegated
back to the keystore that holds the key.

The **X.509 Identity** settings page shows what the keystore holds: certificate
validity, client-auth EKU, private-key access, signing algorithm and
fingerprint. It reads through the privileged Tunnel service, so it reports the
same identity the connection would use.

## Threat model

See [Security](docs/security.md)

## Testing

See [Intended behavior](docs/intended_behavior.md)
