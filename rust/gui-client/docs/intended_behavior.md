# Intended Behavior

This document describes the intended behavior of the `firezone-gui-client` and how to test it manually.
Behavioral expectations use [Given-When-Then](https://en.wikipedia.org/wiki/Given-When-Then) phrasing where it helps.

## Platform support

Linux and Windows are officially supported.
The GUI crate also _compiles_ on macOS so that the UI can be worked on there, but macOS is **not** officially supported and the Tunnel service does not run on it.

## Architecture

The desktop client runs as two processes:

- The **GUI** (this crate), which runs unprivileged as the logged-in user.
  It draws the tray menu and Settings window, drives sign-in, and talks to the Tunnel service over IPC.
- The **Tunnel service** (`firezone-client-tunnel`), installed by the installer and run as root / `SYSTEM`.
  It owns the TUN device, connlib, DNS control, the persisted device ID, and (on Windows) `wintun.dll`.

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
A second launch performs a single-instance handshake with the first over the GUI IPC pipe and then exits.
If the running instance belongs to a different logon session, the second instance shows "Firezone is already running in another logon session..." and exits instead of producing undefined behavior.

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

- Clicking "Apply" saves and applies the settings.
- Applying Advanced settings saves to disk, reloads the log filter for both the GUI and the Tunnel service, and shows a "Settings saved" notification.
  It does **not** sign the user out.
- Log filter changes take effect immediately.
  Auth Base URL and API URL changes take effect on the next sign-in.
- "Reset to Defaults" restores the built-in defaults.

Refs:

- https://github.com/firezone/firezone/pull/3868

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

- Dir `%LOCALAPPDATA%\dev.firezone.client\` (config, logs, webview cache, `wintun.dll`, etc.)
- Dir `%PROGRAMDATA%\dev.firezone.client\` (device ID file)
- Dir `%PROGRAMFILES%\Firezone\` (exe and un-installer)
- Registry key `Computer\HKEY_CURRENT_USER\Software\Classes\firezone-fd0020211111` (deep link association)
- Registry key `Computer\HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{e9245bc1-b8c1-44ca-ab1d-c6aad4f13b9c}` (IP address and DNS server for our tunnel interface)
- Windows Credential Manager, "Windows Credentials", "Generic Credentials", `dev.firezone.client/token`

### Linux

- Dir `$HOME/.local/share/applications` (`.desktop` file for deep links. This dir may not even exist by default on distros like Debian)
- Dir `$HOME/.config/dev.firezone.client/` (GUI settings)
- Dir `$HOME/.local/share/dev.firezone.client/` (session data, e.g. actor name)
- Dir `$HOME/.cache/dev.firezone.client/` (GUI logs)
- Dir `/var/lib/dev.firezone.client/` (device ID and Tunnel service config)
- Dir `/var/log/dev.firezone.client/` (Tunnel service logs)
- The `dev.firezone.client/token` entry in the Secret Service keyring
