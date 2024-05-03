# Intended Behavior

A less exhaustive version of [Manual Testing](manual_testing.md)

## Smoke test checklist (Ubuntu)

Best performed on a clean VM

1. Run `scripts/firezone-client-gui-install.sh`
1. Expect "Reboot to finish..." message
1. Expect `grep firezone-client /etc/group` to show the group
1. Expect `systemctl status firezone-client-ipc.service` to show "enabled" and "running"
1. Run the Firezone GUI
1. Expect an error saying that you are not a member of the group `firezone-client`
1. Reboot
1. Expect `groups` to include "firezone-client"
1. Run the Firezone GUI
1. Expect the "Welcome to Firezone." screen
1. Open the Settings window and change to staging if needed
1. Expect `stat /run/user/1000/dev.firezone.client/data/deep_link.sock /run/dev.firezone.client/ipc.sock` to show both sockets existing
1. Click "Sign in"
1. Expect a browser to open
1. Sign in
1. Expect Firefox to show "Allow this site to open the link with Firezone?" modal
1. Check "Always..." and click "Open link"
1. Expect a keyring dialog to pop up
1. Enter 'password' for testing purposes
1. Expect "Connected to Firezone" notification
1. Browse to `https://ifconfig.net`
1. Expect to see the gateway's IP and location
1. Quit Firezone
1. Refresh the page
1. Expect to see your own IP and location
1. Reboot
1. Run the Firezone GUI
1. Expect a keyring dialog to pop up
1. Enter 'password' to unlock the stored token
1. Expect "Connected to Firezone" notification
1. Check the IP again
1. Export the logs
1. Expect `zipinfo` to show

## Settings tab

- Pressing Enter on a text field immediately saves and applies the settings
- Log level changes take effect on the next app start
- Auth base URL and API URL changes take effect on the next sign-in

Refs:
- https://github.com/firezone/firezone/pull/3868
