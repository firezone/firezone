# Intended Behavior

A less exhaustive version of [Manual Testing](manual_testing.md)

## Smoke test checklist (Ubuntu)

Keep this synchronized with the Linux GUI docs in `/website/src/app/kb/client-apps/linux-gui-client`

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
1. Expect `zipinfo` to show a single directory in the root of the zip, to prevent zip bombing
1. Expect two subdirectories in the zip, "connlib", and "app", with 3 and 2 files respectively, totalling 5 files

## Smoke test checklist (Windows)

Keep this synchronized with the Windows GUI docs in `/website/src/app/kb/client-apps/windows-gui-client`

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
1. Expect the zip to contain a single directory in the root of the zip, to prevent zip bombing
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

## Settings tab

- Pressing Enter on a text field immediately saves and applies the settings
- Log level changes take effect on the next app start
- Auth base URL and API URL changes take effect on the next sign-in

Refs:

- https://github.com/firezone/firezone/pull/3868
