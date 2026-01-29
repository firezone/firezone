How to run manual tests of `firezone-gui-client`

Using [Given-when-then syntax](https://en.wikipedia.org/wiki/Given-When-Then)

# GUI states

The client may be running or not running.

Only one instance of the client may run at a time per system. If two users are logged in at once, starting a 2nd instance results in undefined behavior.

If the client is running, the GUI may be in a "signed out", "signed in", or "signing in" state.

If the client stops running while signed in, then the token may be stored in Windows' credential manager on disk.

# Device ID

- [ ] Given the AppData dir for the client doesn't exist, when you run the client, then the client will generate a UUIDv4 (random) and store it in AppData
- [ ] Given the UUID is stored in AppData, when you run the client, then it will load the UUID
- [ ] Given the client is running, when a session starts, then the UUID will be used as the device ID

# DLL

- [ ] Given wintun.dll does not exist in the same directory as the exe, when you run the exe, then it will create wintun.dll
- [ ] Given wintun.dll has extra bytes appended to the end, when you run the exe, then it will re-write wintun.dll
- [ ] Given wintun.dll does not have the expected SHA256, when you run the exe, then it will re-write wintun.dll
- [ ] Given wintun.dll has the expected SHA256, when you run the exe, then it will not re-write wintun.dll

# Launching

- [ ] Given the client is not running, when you open a deep link, then the client will not start
- [ ] Given the client is not running, when you run the exe with normal privileges, then the client will unpack wintun.dll next to the exe if needed, try to start a bogus probe tunnel, and re-launch itself with elevated privilege
- [ ] Given the client is not running, when you run the exe as admin, then the client will unpack wintun.dll next to the exe if needed, try to start a bogus probe tunnel, and keep running
- [ ] Given the client is running, when you open a deep link as part of sign-in, then the client will sign in without a second UAC prompt

# Permissions

## Linux Permissions

- [ ] The Tunnel service with `run --interactive` can NOT run as a normal user
- [ ] The Tunnel service with `run --interactive` can run with `sudo`
- [ ] The GUI can run as a normal user
- [ ] The GUI can NOT run with `sudo`

## Windows Permissions

- [ ] The Tunnel service with `run --interactive` can NOT run as a normal user
- [ ] The Tunnel service with `run --interactive` can run as admin
- [ ] The GUI can run as a normal user
- [ ] The GUI can run as admin

# Auth flow

- [ ] Given the client is running, when you right-click the system tray icon, then a menu will open ([#2712](https://github.com/firezone/firezone/issues/2712))
- [ ] Given the client is signed out, when you click "Sign In", then the auth base URL will open in the user's default web browser ([#2711](https://github.com/firezone/firezone/issues/2711))
- [ ] Given the client is running, when you authenticate in the browser, then the browser will deep-link back to the app, and the GUI, including tray menu, will change to signed-in state, without asking for admin privileges ([#2711](https://github.com/firezone/firezone/issues/2711))
- [ ] Given the client is signed in, when you open the tray menu, then the resources will be listed ([#2712](https://github.com/firezone/firezone/issues/2712))
- [ ] Given the client is signed in, when you click on a resource's "pasteable" (CIDR or DNS), then the client will copy it to the clipboard. ([#2712](https://github.com/firezone/firezone/issues/2712))
- [ ] Given the client is not running but has run once, when you authenticate in the browser, then deep-link authentication will fail because the keys won't match ([#2802](https://github.com/firezone/firezone/issues/2802))
- [ ] Given the client is signed in, when you click "Sign Out", then the GUI will change to signed-out state, and the token will be wiped from the disk, and the client will continue running ([#2809](https://github.com/firezone/firezone/issues/2809))
- [ ] Given the client is signed in, when you click "Disconnect and Quit", then the client will stop running, and the token will stay on disk in Window's credential manager. ([#2809](https://github.com/firezone/firezone/issues/2809))
- [ ] Given the client was signed in when it stopped, when you start the client again, then the GUI will be in the signed-in state, and the user's name will be shown in the tray menu. ([#2712](https://github.com/firezone/firezone/issues/2712))
- [ ] Given the client is signed out, when you sign in, then sign out, then sign in again, then the 2nd sign-in will work

# Advanced settings

- [ ] Given the advanced settings file in AppData does not exist, when the client starts, then the "Advanced Settings" tab will have default settings ([#2807](https://github.com/firezone/firezone/issues/2807))
- [ ] Given the client is signed out, when the user clicks "Apply", then the client will save the settings to disk ([#2714](https://github.com/firezone/firezone/issues/2714))
- [ ] Given the client is signed in, when the user clicks "Apply", then the client will show a dialog explaining that they will be signed out, and asking for confirmation ([#2668](https://github.com/firezone/firezone/issues/2668))
- [ ] Given the client is signed in, when the user confirms that they want to apply new settings, then the client will clear their token, and change to signed-out state, and save the settings to disk ([#2668](https://github.com/firezone/firezone/issues/2668))

# Diagnostic logs

- [ ] Given the client was built in release mode, when you first start the client, then it will use the release mode default settings
- [ ] Given the client app is signed out, when you change the log filter in the Advanced Settings tab, then the log filter for both the GUI and connlib will change immediately
- [ ] Given the Diagnostic Logs tabs is not displayed, when you open the Diagnostic Logs tab, then the log directory size is computed in a worker task (not blocking the GUI) and displayed
- [ ] Given the client app is computing the log directory size, when you click "Clear Logs", then the computation will be canceled.
- [ ] Given the log tab is displayed, when a 1-minute timer ticks, then the log directory size will be re-computed.
- [ ] Given the log tab is displayed, when you switch to another tab or close the window, then any ongoing computation will be canceled.
- [ ] Given the log tab is computing log directory size, when the 1-minute refresh timer ticks, then the computation will time out and show an error e.g. "timed out while computing size"

# Error logging

1. Given the log filter has been set to an invalid filter, when you start Firezone, then it will show an error dialog and use the default log filter instead.
1. Given `--crash` is passed, when Firezone crashes, then the error will be written to the log file.
1. Given `--error` is passed, when Firezone errors, then the error will be written to the log file.
1. Given `--panic` is passed, when Firezone panics, then the error will be written to the log file.
1. Given `--crash smoke-test` is passed, when Firezone crashes, then the error will be written to stderr.
1. Given `--error smoke-test` is passed, when Firezone crashes, then the error will be written to stderr.
1. Given `--panic smoke-test` is passed, when Firezone panics, then the error will be written to stderr.

# Resetting state

This is a list of all the on-disk state that you need to delete / reset to test a first-time install / first-time run of the Firezone GUI client.

## Windows

- Dir `%LOCALAPPDATA%/dev.firezone.client/` (Config, logs, webview cache, wintun.dll etc.)
- Dir `%PROGRAMDATA%/dev.firezone.client/` (Device ID file)
- Dir `%PROGRAMFILES%/Firezone/` (Exe and un-installer)
- Registry key `Computer\HKEY_CURRENT_USER\Software\Classes\firezone-fd0020211111` (Deep link association)
- Registry key `Computer\HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{e9245bc1-b8c1-44ca-ab1d-c6aad4f13b9c}` (IP address and DNS server for our tunnel interface)
- Windows Credential Manager, "Windows Credentials", "Generic Credentials", `dev.firezone.client/token`

## Linux

- Dir `$HOME/.local/share/applications` (.desktop file for deep links. This dir may not even exist by default on distros like Debian)

# Token storage

([#2740](https://github.com/firezone/firezone/issues/2740))

- [ ] Given the client is signed out, or was signed out before it stopped, when you open the Windows credential manager, then the token will be deleted or empty
- [ ] Given the client is signed in, or was signed in before it stopped, when you open the Windows credential manager, then the token will be present

# Tunneling

If you can't test with resources that respond to ping, curl is fine too.

1. The tunnel can route public-routable IPs, e.g. 1.1.1.1, for public resources
1. All resources accessed by domain will get a CGNAT network address, e.g. 100.64.96.19, even public resources
1. When the client is signed in, all DNS requests go to Firezone first, so that it can route public resources
1. Given `*.test-ipv6.com` is a resource, and the tunnel is up, when you load `test-ipv6.com` in a web browser, then it will show the gateway's IPv6 address and score 10/10

## Signed out

Given the client is signed out or not running, when you ping...

1. [ ] a public resource by IP (e.g. 1.1.1.1), it will respond through a physical interface
2. [ ] a protected resource by IP (e.g. 10.0.14.19), it will not respond
3. [ ] a non-resource by IP (e.g. a.b.c.d), it will respond through a physical interface
4. [ ] a public resource by domain (e.g. example.com), the system's DNS will resolve it, and it will respond through a physical interface
5. [ ] a protected resource by domain (e.g. gitlab.company.com), the system's DNS will fail to resolve it
6. [ ] a non-resource by domain (e.g. example.com), the system's DNS will resolve it, and it will respond through a physical interface

## Signed in

Given the client is signed in, when you ping...

1. [ ] a public resource by IP (e.g. 1.1.1.1), it will respond through the tunnel
2. [ ] a protected resource by IP (e.g. 100.64.96.19), it will respond through the tunnel
3. [ ] a non-resource by IP (e.g. a.b.c.d), it will respond through a physical interface
4. [ ] a public resource by domain (e.g. example.com), Firezone's DNS will make an IP for it, and it will respond through the tunnel
5. [ ] a protected resource by domain (e.g. gitlab.company.com), Firezone's DNS will make an IP for it, and it will respond through the tunnel
6. [ ] a non-resource by domain (e.g. example.com), Firezone's DNS will fall back on the system's DNS, which will find the domain's publicly-routable IP, and it will respond through a physical interface

# Network changes

Moved to [`network_roaming.md`](network_roaming.md)

# No Internet

1. Given Firezone is signed in and not running, when you disconnect from the Internet and start Firezone, then Firezone will wait for Internet and show the same icon as when it's signed out.
1. Given Firezone is waiting for Internet, when you click "Retry sign-in", then Firezone will retry sign-in immediately.
1. Given Firezone is waiting for Internet, when you gain Internet, then Firezone will automatically sign in.
1. Given Firezone is waiting for Internet, when you click "Cancel sign-in", then Firezone will sign out.
