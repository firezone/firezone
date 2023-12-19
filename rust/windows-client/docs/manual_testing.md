How to run manual tests of `firezone-windows-client`

Using [Given-when-then syntax](https://en.wikipedia.org/wiki/Given-When-Then)

# GUI states

The client may be running or not running.

Only one instance of the client may run at a time per Windows device. If two users are logged in at once, starting a 2nd instance results in undefined behavior.

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

- [ ] Given a production exe, when you run it normally, then it will ask to escalate to Admin privileges ([#2751](https://github.com/firezone/firezone/issues/2751))
- [ ] Given the client is running, when you authenticate in the browser, then the client will not ask for privileges again ([#2751](https://github.com/firezone/firezone/issues/2751))
- (Running as an unprivileged user is not supported yet) ([#2751](https://github.com/firezone/firezone/issues/2751))

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

# Advanced settings

- [ ] Given the advanced settings file in AppData does not exist, when the client starts, then the "Advanced Settings" tab will have default settings ([#2807](https://github.com/firezone/firezone/issues/2807))
- [ ] Given the client is signed out, when the user clicks "Apply", then the client will save the settings to disk ([#2714](https://github.com/firezone/firezone/issues/2714))
- [ ] Given the client is signed in, when the user clicks "Apply", then the client will show a dialog explaining that they will be signed out, and asking for confirmation ([#2668](https://github.com/firezone/firezone/issues/2668))
- [ ] Given the client is signed in, when the user confirms that they want to apply new settings, then the client will clear their token, and change to signed-out state, and save the settings to disk ([#2668](https://github.com/firezone/firezone/issues/2668))

# Diagnostic logs

- [ ] Given the client was built in release mode, when you first start the client, it will use the release mode default settings
- [ ] Given the client app is signed out, when you change the log filter in the Advanced Settings tab, then the log filter for both the GUI and connlib will change immediately
- [ ] Given the Diagnostic Logs tabs is not displayed, when you open the Diagnostic Logs tab, then the log directory size is computed in a worker task (not blocking the GUI) and displayed
- [ ] Given the client app is computing the log directory size, when you click "Clear Logs", then the computation will be canceled.
- [ ] Given the log tab is displayed, when a 1-minute timer ticks, then the log directory size will be re-computed.
- [ ] Given the log tab is displayed, when you switch to another tab or close the window, then any ongoing computation will be canceled.
- [ ] Given the log tab is computing log directory size, when the 1-minute refresh timer ticks, then the computation will time out and show an error e.g. "timed out while computing size"

# Resetting state

This is a list of all the on-disk state that you need to reset to test a first-time install / first-time run of the Firezone client.

- `AppData/Local/dev.firezone.client/` (Config, logs, webview cache, etc.)
- Registry key `Computer\HKEY_CURRENT_USER\Software\Classes\firezone-fd0020211111` (Deep link association)
- Token, in Windows Credential Manager

# Token storage

([#2740](https://github.com/firezone/firezone/issues/2740))

- [ ] Given the client is signed out, or was signed out before it stopped, when you open the Windows credential manager, then the token will be deleted or empty
- [ ] Given the client is signed in, or was signed in before it stopped, when you open the Windows credential manager, then the token will be present

# Tunneling

TODO
