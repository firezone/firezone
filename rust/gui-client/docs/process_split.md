# Process split

This is meant for Linux, but it will probably be very similar on Windows.

## TODO

- Do we need to support CLI and GUI Clients being installed on the same system? The tunnel binary would conflict if they both try to install it. Splitting it into 3 packages would complicate downloads.
- Clients and Gateways can't run in the same system, right? How would DNS work if they did?
- If there is a service account token, but it's invalid, should the tunnel wait for the GUI to connect, or fail? Will the tunnel know whether a GUI is even installed?

## Binaries

I gave them new names to clarify.

1. `firezoned` - A daemon that runs the tunnel and has elevated privilege
2. `firezonectl` - A CLI program that runs unprivileged and exits once each operation is complete, like `systemctl` or `nmcli`
3. `firezone-gui` - An unprivileged GUI program that keeps an icon in the system tray / notification center and is similar to `firezonectl`

## Docker

`firezoned` runs all the time. You can do `docker exec` to run `firezonectl` within the container.

## Desktop

`firezoned` is started as a systemd service. It tries to find a service account token and use that. If there is no service account token, it waits for a GUI to connect over IPC.

`firezone-gui` performs auth using deep links and sends the token to `firezoned`.

## Security concerns

Given a group `firezone` and users `firezone-user` (Belonging to a Firezone Actor) and `other-user` (Belonging to another person):

- What if an attacker has root? (That is outside scope, we can't protect from that.)
- What if malware is running as `firezone-user`? (Then it can command the tunnel to sign out, and possibly steal tokens depending on how the desktop keyring works.)
- What if `firezone-user` signs in to Firezone, then `other-user` signs in to Linux and uses Resources under `firezone-user`'s name? (We can't help that, the tunnel is system-wide. Per-app permissions may come after GA.)
- How does the UI know that it's connected to the real tunnel? (The tunnel claims a privileged D-Bus address or listens on a socket that no other service would be allowed to listen on)
- What if `other-user` tries to sign out the tunnel using `firezonectl`? (The tunnel should be able to check the GID of incoming IPC connections and refuse the command, same as Docker does)
- How does the tunnel know that it's getting IPC commands from a real UI binary? (It doesn't. Permissions belong to users, not to binaries.)
- What if an "evil maid" reads the hard drive of a system while it's in a hotel room? (Service account tokens would be compromised, but hopefully interactive GUI logins would be secured by the desktop's keyring)
