# gui-client

This crate houses a GUI client for Linux and Windows.

## Setup (Ubuntu)

To compile natively for x86_64 Linux:

1. [Install rustup](https://rustup.rs/)
1. Install [pnpm](https://pnpm.io/installation)
1. `sudo apt-get install build-essential curl file libayatana-appindicator3-dev librsvg2-dev libssl-dev libwebkit2gtk-4.1-dev libxdo-dev wget`

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

## Installing on CentOS 9

These instructions will move to the knowledge base once the first release supporting CentOS 9 is cut.

### Install system tray

GNOME Shell 40 in CentOS 9 does not have a system tray by default. Use these steps to install it.

For other desktops like xfce4 or KDE, the system tray may already work properly.

1. `sudo dnf install epel-release` (Needed to get GNOME extensions)
2. `sudo dnf install gnome-shell-extension-appindicator`
3. Log out and back in to restart GNOME
4. `gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com` (This will tab-complete.)

### Install Firezone

1. Download the RPM
2. `sudo dnf install systemd-resolved` (Installing it explicitly prevents it from being auto-removed if Firezone is removed)
3. `sudo dnf install ./firezone-client-gui-*.rpm`
4. `sudo usermod -aG firezone-client $USER`
5. `sudo systemctl enable firezone-client-ipc.service` (See https://www.freedesktop.org/software/systemd/man/latest/systemd.preset.html, "It is not recommended to ship preset files within the respective software packages implementing the units". The Fedora family of distros also seem to have their own policy that installing a service should not auto-start or enable it.)
6. Reboot to finish adding yourself to the group. Logging out and back in is not enough. This also starts the new services for us.
7. `sudo cp /etc/resolv.conf /etc/resolv.conf.before-firezone` Back up your resolv.conf file. If anything goes wrong with your DNS, you can copy this back into place.
8. `sudo ln --force --symbolic /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf` This puts `systemd-resolved`, and therefore Firezone, in control of the system's DNS. `systemd-resolved` does not do this automatically, since it's under `/etc`.
9. Run `firezone-client-gui` from the app menu.

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

Ubuntu 22.04 and newer is supported.

Tauri says it should work on Windows 10, Version 1803 and up. Older versions may
work if you
[manually install WebView2](https://tauri.app/v1/guides/getting-started/prerequisites#2-webview2)

`x86_64` architecture is supported for Windows. `aarch64` and `x86_64` are supported for Linux.

## Threat model

See [Security](docs/security.md)

## Testing

See [Intended behavior](docs/intended_behavior.md)
