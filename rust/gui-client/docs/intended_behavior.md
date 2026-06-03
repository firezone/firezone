# Intended Behavior

This document describes the intended behavior of the `firezone-gui-client` and how to test it manually.

## Platform support

Linux and Windows are officially supported.
The GUI crate also _compiles_ on macOS so that the UI can be worked on there, but macOS is **not** officially supported and the Tunnel service does not run on it.

## Architecture

The desktop client runs as two processes:

- The **GUI** (this crate), which runs unprivileged as the logged-in user.
  It draws the tray menu and Settings window, drives sign-in, and talks to the Tunnel service over IPC.
- The **Tunnel service** (`firezone-client-tunnel`), installed by the installer and run as root / `SYSTEM`.
  It owns the TUN device, connlib, DNS control, the persisted device ID, the advanced settings and MDM (managed) policy, and (on Windows) `wintun.dll`.

IPC is a Unix domain socket on Linux and a named pipe on Windows.
Because all privileged work lives in the Tunnel service, the GUI never needs to elevate itself.

## Smoke test checklist (Ubuntu)

Keep this synchronized with the Linux GUI docs in firezone/website at `src/app/kb/client-apps/linux-gui-client`

Best performed on a clean VM

1. Run `scripts/firezone-client-gui-install.sh`
1. Expect "Reboot to finish..." message
1. Run the Firezone GUI
1. Expect an error saying that you are not a member of the group `firezone-client`
1. Reboot
1. Expect `groups` to include "firezone-client"
1. Run the Firezone GUI
1. Expect the "Welcome to Firezone." screen
1. Open the Settings window and change to staging if needed
1. Click "Sign in"
1. Expect a browser to open
1. Sign in
1. Expect Firefox to show "Allow this site to open the link with Firezone?" modal
1. Check "Always..." and click "Open link"
1. Expect a keyring dialog to pop up
1. Enter 'password' for testing purposes
1. Expect "Firezone connected" notification
1. Browse to `https://ifconfig.net`
1. Expect to see the gateway's IP and location
1. Quit Firezone
1. Refresh the page
1. Expect to see your own IP and location
1. Reboot
1. Run the Firezone GUI
1. Expect a keyring dialog to pop up
1. Enter 'password' to unlock the stored token
1. Expect "Firezone connected" notification
1. Check the IP again, expect the gateway's IP
1. Sign out of Firezone without quitting
1. Check the IP again, expect your own IP (Checks for regressions in https://github.com/firezone/firezone/pull/5828)
1. Export the logs
1. Expect the zip file to start with `firezone_logs_`
1. Expect `zipinfo` to show a single directory in the root of the zip, to prevent a tarbomb
1. Expect two subdirectories in the zip, "connlib", and "app", with 3 and 2 files respectively, totalling 5 files

## Smoke test checklist (Windows)

Keep this synchronized with the Windows GUI docs in firezone/website at `src/app/kb/client-apps/windows-gui-client`

x86_64 only, see issue #2992. Best performed on a clean VM.

1. Run the MSI installer and ensure "Launch Firezone" is checked at the end
1. Expect the "Welcome to Firezone." screen
1. Right-click on the Windows taskbar and configure it to show the Firezone icon
1. Open the Settings window and change to staging if needed
1. Click "Sign in"
1. Expect a browser to open
1. Sign in
1. Expect the browser to show "This site is trying to open Firezone." modal
1. Check "Always allow..." and click "Open"
1. Expect "Firezone connected" notification
1. Browse to `https://ifconfig.net`
1. Expect to see the gateway's IP and location
1. Quit Firezone
1. Refresh the page
1. Expect to see your own IP and location
1. Reboot
1. Browse to `https://ifconfig.net` (For issue #4899)
1. Expect to see your own IP and location
1. Run the Firezone GUI
1. Expect "Firezone connected" notification
1. Check the IP again, expect the gateway's IP
1. Sign out of Firezone without quitting
1. Check the IP again, expect your own IP (Checks for regressions in https://github.com/firezone/firezone/pull/5828)
1. Export the logs
1. Expect the zip file to start with `firezone_logs_`
1. Expect the zip to contain a single directory in the root of the zip, to prevent a tarbomb
1. Expect two subdirectories in the zip, "connlib", and "app", with 2 files each, totalling 4 files

## Upgrade checklist (Linux)

1. Close the Firezone GUI
1. Run `scripts/firezone-client-gui-install.sh $NEW_DEB`
1. Run the Firezone GUI

## Upgrade checklist (Windows)

1. Close the Firezone GUI
1. Run the new MSI
1. Run the Firezone GUI

## Un-install checklist (Linux)

1. Close the Firezone GUI
1. Run `sudo apt-get remove firezone-client-gui`

## Un-install checklist (Windows)

1. Quit the Firezone GUI
1. Go to "Add or Remove Programs"
1. Search for Firezone and click "Uninstall"

## GUI states

Only one instance of the GUI runs at a time.

- [ ] Given the GUI is already running in your session, when you launch it again, then the second launch hands off to the running instance over the GUI IPC pipe and exits, leaving the first instance running
- [ ] Given the GUI is running in another user's session (e.g. reached via Fast User Switching), when you launch the GUI in your own session, then it shows "Firezone is already running in another logon session. Sign out of that session first, then try again." and exits

The GUI is always in one of these states:

- **Signed out** — the tray shows "Sign In".
- **Signing in** — the tray shows the current sub-state: "Waiting for browser...", "Connecting to Firezone Portal...", or "Raising tunnel...".
  A "Cancel sign-in" item is available.
- **Signed in** — the tray lists the account and resources.

## Device ID

The device ID is generated and persisted by the Tunnel service.

- [ ] Given no device ID file exists, when the Tunnel service first runs, then it generates a random ID (the SHA-256 of a fresh UUIDv4, hex-encoded) and writes it to `firezone-id.json` in the Tunnel service config dir (`%PROGRAMDATA%\dev.firezone.client\` on Windows, `/var/lib/dev.firezone.client/config/` on Linux)
- [ ] Given the file exists, when the service runs, then it loads that ID
- [ ] Given the service is running, when a session starts, then this ID is used as the device ID

Older installs may still carry a bare UUID; those are accepted as-is.

## wintun.dll (Windows)

Wintun is managed by the Tunnel service, not the GUI.

- [ ] Given `wintun.dll` is missing, when the service brings up the TUN device, then it writes the embedded copy to `%LOCALAPPDATA%\dev.firezone.client\data\wintun.dll`
- [ ] Given the on-disk DLL has extra bytes appended, or does not match the embedded copy's SHA-256, then the service rewrites it
- [ ] Given the on-disk DLL matches the embedded SHA-256, then the service reuses it

The hash check only avoids redundant writes and updates the DLL when needed; it is not a security boundary.

## Permissions

### Linux

- [ ] The Tunnel service with `run-debug` can NOT run as a normal user
- [ ] The Tunnel service with `run-debug` can run with `sudo`
- [ ] The GUI runs as a normal user who is a member of the `firezone-client` group
- [ ] The GUI refuses to run as root

### Windows

- [ ] The Tunnel service with `run-debug` can NOT run as a normal user
- [ ] The Tunnel service with `run-debug` can run as admin
- [ ] The GUI can run as a normal user
- [ ] The GUI can run as admin

### Directory permissions

The Tunnel service runs as root / `SYSTEM` and locks down the directories it owns, so an unprivileged user cannot read or tamper with the device ID, the advanced settings, or other service config.
The GUI's own directories (settings, logs, session data) are owned by the user who runs it.

On Linux:

- [ ] Given the Tunnel service has run once, when you inspect `/var/lib/dev.firezone.client/config/`, then it is `rwxrwx---` (`0o770`), owned by `root:firezone-client`
- [ ] Given the device ID file exists, when you inspect `/var/lib/dev.firezone.client/config/firezone-id.json`, then it is `rw-r-----` (`0o640`), owned by `root:firezone-client`
- [ ] Given advanced settings have been saved, when you inspect `/var/lib/dev.firezone.client/config/advanced_settings.json`, then it is `rw-------` (`0o600`), owned by `root` (the GUI receives the values over IPC, so the file needs no group access)
- [ ] Given a user who is not in the `firezone-client` group, when they try to read the device ID file, then access is denied
- [ ] Given the GUI has run, when you inspect its config, log, and session dirs under `$HOME`, then they are owned by that user

On Windows:

- [ ] Given the Tunnel service has run once, when you inspect the DACL of `%PROGRAMDATA%\dev.firezone.client\config\` and its `firezone-id.json` / `advanced_settings.json`, then it is protected (non-inherited) and grants Full Access only to `SYSTEM` and `Administrators`, with no access for standard users

## Package identity (Windows)

On Windows the GUI runs as a normal, unprivileged user but still has to talk to the privileged Tunnel service.
Both that channel and the GUI's own deep-link pipe are authorized by **Windows package identity** rather than by administrator rights: each named pipe only accepts a process that carries Firezone's sparse-MSIX package identity (`Firezone.Client.GUI`).
A standard user can therefore drive the tunnel, while any other process running as that same user — even an elevated one — is refused by the kernel.

The MSI installer stages and provisions the sparse MSIX for the whole machine.
Provisioning alone does not register the package for a given user, and identity is only attached when a process starts, so each user picks it up the first time they actually run Firezone:

- On a normal interactive (elevated) install, the installing user is registered automatically, so their first launch already carries identity.
- For any other case — a different user on the same machine, or a silent / MDM / SYSTEM install where the per-user step is skipped — the GUI registers the package for the current user on first launch (no administrator rights needed, since it is already provisioned), then shows "Firezone finished first-time setup. Please start Firezone again." and exits.
  The next launch carries identity.

- [ ] Given a normal interactive install, when the installing user launches Firezone for the first time, then it carries package identity immediately and shows no "first-time setup" dialog
- [ ] Given Firezone was installed by another user, or installed silently / via MDM, when a not-yet-registered user launches it for the first time, then it shows "Firezone finished first-time setup. Please start Firezone again." and exits, with no UAC / admin prompt
- [ ] Given that user has seen the dialog once, when they launch Firezone again, then it starts normally and connects to the Tunnel service, and the dialog does not reappear
- [ ] Given any standard (non-administrator) user with identity attached, when they use Firezone, then signing in and raising the tunnel never trigger a UAC / admin prompt
- [ ] Given a process that is not Firezone — even one running elevated as the same user — when it tries to open the Tunnel or GUI pipe, then the kernel denies access

Refs:

- https://github.com/firezone/firezone/pull/13274
- https://github.com/firezone/firezone/pull/13275
- https://github.com/firezone/firezone/pull/13433
- https://github.com/firezone/firezone/pull/13459

## Auth flow

- [ ] Given the client is running, when you right-click the tray icon, then a menu opens
- [ ] Given the client is signed out, when you click "Sign In", then the auth URL opens in the default web browser
- [ ] Given the client is running, when you authenticate in the browser, then the browser deep-links back and the GUI (including the tray menu) switches to the signed-in state, without any elevation / UAC prompt
- [ ] Given the client is signed in, when you open the tray menu, then the resources are listed
- [ ] Given the client is signed in, when you click a resource's CIDR or DNS name, then it is copied to the clipboard
- [ ] Given the client is signed in, when you click "Sign out", then the GUI returns to the signed-out state, the token is deleted from the keyring, and the GUI keeps running
- [ ] Given the client is signed in, when you click "Disconnect and quit Firezone", then the GUI stops and the token stays in the keyring
- [ ] Given the client was signed in when it stopped, when you start it again, then the GUI returns to the signed-in state and shows the actor name
- [ ] Given the client is signed out, when you sign in, sign out, then sign in again, then the second sign-in works

The signed-in tray menu also offers favoriting resources and an "Admin Portal..." item (which can be hidden by MDM policy).

## Settings

Settings are split across an **Advanced** page (Auth Base URL, API URL, Log Filter), a **General** page (start minimized, start on login, connect on start, account slug), and optional **MDM / managed** values that lock the corresponding fields.

The **advanced settings and MDM (managed) policy are owned by the Tunnel service**, not the GUI.
The GUI reads both from the service over IPC when it first connects, and sends edited advanced settings back over IPC; it never reads or writes them from disk or the registry directly.
General settings stay GUI-owned, in the user's profile.

- Clicking "Apply" sends the advanced settings to the Tunnel service, which validates them, persists them, and reloads its log filter; the GUI then reloads its own log filter and shows a "Settings saved" notification.
  A rejected change (e.g. an unparsable log filter) shows "Failed to save settings" and is not persisted.
  Applying does **not** sign the user out.
- Log filter changes take effect immediately. Auth Base URL and API URL changes take effect on the next sign-in.
- A machine-scope MDM policy wins over the stored advanced setting for the same field.
- "Reset to Defaults" restores the built-in defaults.

The service stores `advanced_settings.json` in its own config dir (`/var/lib/dev.firezone.client/config/` on Linux, `%PROGRAMDATA%\dev.firezone.client\config\` on Windows), protected so another process running as the desktop user cannot, for example, rewrite `auth_url` to redirect the next sign-in.

- [ ] Given a user had custom advanced settings before upgrading to this release, when the GUI first connects, then it migrates the old user-side `advanced_settings.json` into the service and deletes the old copy, preserving the user's `auth_url` / `api_url` / `log_filter`
- [ ] Given that migration is rejected by the service, when the GUI next connects, then the old file is kept so the migration is retried

### MDM (Windows)

Managed policies live under the registry key `Software\Policies\Firezone` and are read by the Tunnel service.
As of this release they are read from the **machine** hive (`HKLM`), not the per-user hive (`HKCU`).

- [ ] Given an admin manages Firezone via MDM, when they deploy policy, then they must import the new (Machine-class) ADMX template (`policy-templates/windows/firezone.admx`) and remove the old (User-class) one; the old `HKCU` keys are no longer read
- [ ] Given a machine still has policy under `HKCU\Software\Policies\Firezone` from an older release, when a user first connects after upgrading, then the service copies those values to `HKLM\Software\Policies\Firezone` (only if `HKLM` is not already set) and deletes the `HKCU` key
- [ ] Given that one-time migration has run, when any user connects again, then it does not run a second time (it is gated by `HKLM\Software\Firezone\Migration`)

Refs:

- https://github.com/firezone/firezone/pull/3868
- https://github.com/firezone/firezone/pull/13333

## Diagnostic logs

- [ ] Given the client was built in release mode, when you first start it, then it uses the release-mode default log filter
- [ ] Given you open the Diagnostics page, then it shows the log directory size (file count and MB)
- [ ] Given you click "Export Logs", then it writes a zip whose name starts with `firezone_logs_`, containing a single top-level directory (to prevent a tarbomb) with `connlib` and `app` subdirectories
- [ ] Given you click "Clear Logs", then the GUI logs are deleted and the Tunnel service is asked to clear its own

## Error logging

These hidden debug flags exercise the Controller's error handling.
Run them from a terminal so the output is visible.

1. Given the configured log filter is invalid, when you start Firezone, then it shows an error dialog and falls back to the default log filter.
1. Given `--crash` is passed, when the Controller task runs, then it segfaults on purpose.
1. Given `--error` is passed, when the Controller task runs, then it returns an error on purpose.
1. Given `--panic` is passed, when the Controller task runs, then it panics on purpose.
1. Given the `smoke-test` subcommand is used, then the GUI runs headlessly for CI and logs to stdout/stderr.

## Token storage

The token is stored in the OS keyring under `dev.firezone.client/token` — the Windows Credential Manager on Windows, the D-Bus Secret Service on Linux.

- [ ] Given the client is signed out, or was signed out before it stopped, when you inspect the keyring, then the token entry is absent
- [ ] Given the client is signed in, or was signed in before it stopped, when you inspect the keyring, then the token entry is present

## Network roaming

Given Ethernet and 2 Wi-Fi networks "A" and "B", this test cycle exercises all interesting combos of:

- Connecting and disconnecting Ethernet and Wi-Fi, while the other is connected and disconnected
- Roaming from one Wi-Fi network to another
- Steady-state network connections

Cycle:

1. Steady on A
2. Change to B
3. Disconnect Wi-Fi
4. Steady offline
5. Connect to A
6. Connect Eth
7. Steady on Eth + A
8. Change to B
9. Disconnect Wi-Fi
10. Steady on Eth
11. Disconnect Eth
12. Connect Eth
13. Connect to Wi-Fi A
14. Disconnect Eth

For each step:

- Make the change. (e.g. click on the Wi-Fi network, or connect / disconnect the Ethernet plug)
- Wait for the OS to reflect the change. (e.g. "Connected to Wi-Fi A" pop-up)
- Run `time curl -4 --silent --max-time 30 https://ifconfig.net/ip`.
- Ensure that you see the Gateway's IP and not your Wi-Fi's external IP.
- Note how long it took `curl` to return success or failure.

## Resetting state

This is the on-disk state you need to delete / reset to test a first-time install / first-time run of the Firezone GUI client.

### Windows

- Dir `%LOCALAPPDATA%\dev.firezone.client\` (general settings, logs, webview cache, `wintun.dll`, etc.)
- Dir `%PROGRAMDATA%\dev.firezone.client\` (device ID, advanced settings, and Tunnel service config / logs)
- Dir `%PROGRAMFILES%\Firezone\` (exe and un-installer)
- Registry key `Computer\HKEY_CURRENT_USER\Software\Classes\firezone-fd0020211111` (deep link association)
- Registry key `Computer\HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{e9245bc1-b8c1-44ca-ab1d-c6aad4f13b9c}` (IP address and DNS server for our tunnel interface)
- Registry key `HKEY_LOCAL_MACHINE\Software\Firezone\Migration` (one-time HKCU→HKLM MDM migration sentinel)
- Registry key `HKEY_LOCAL_MACHINE\Software\Policies\Firezone` (MDM policy, if you set any)
- Windows Credential Manager, "Windows Credentials", "Generic Credentials", `dev.firezone.client/token`
- The provisioned sparse MSIX package `Firezone.Client.GUI` and its per-user registrations (normally removed by the uninstaller; to reset by hand, remove it with `Remove-AppxPackage` and `Remove-AppxProvisionedPackage`)

### Linux

- Dir `$HOME/.local/share/applications` (`.desktop` file for deep links. This dir may not even exist by default on distros like Debian)
- Dir `$HOME/.config/dev.firezone.client/` (GUI general settings)
- Dir `$HOME/.local/share/dev.firezone.client/` (session data, e.g. actor name)
- Dir `$HOME/.cache/dev.firezone.client/` (GUI logs)
- Dir `/var/lib/dev.firezone.client/` (device ID, advanced settings, and Tunnel service config)
- Dir `/var/log/dev.firezone.client/` (Tunnel service logs)
- The `dev.firezone.client/token` entry in the Secret Service keyring
