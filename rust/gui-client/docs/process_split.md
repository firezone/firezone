# Process split

This is meant for Linux, but it will probably be similar on Windows.
It is probably similar to the existing Mac / iOS / Android process split.

## Split boundary

Anything that requires CAP_NET_ADMIN or root privilege will happen inside the privileged tunnel process, which uses systemd auto-start. This acts the same as the current Linux CLI Client, but also acts as an IPC server.

Tunnel process:

- DNS control
- Creating the tunnel interface
- Adding / removing IP routes

Anything that can work with normal user privileges should run in the non-privileged GUI process

GUI process:

- All Tauri code
- `get_system_default_resolvers`
- Listening for DNS / network changes

Ambiguous:

- The DNS stub resolver doesn't actually need privileges to do its work. But since it gets packets from the tunnel interface, and it's already inside connlib, and moving it would require extra IPC round-trips, it will stay inside the privileged tunnel process.

## Decisions

- The CLI Client will not be split for now, it keep the same CLI interface but may be refactored.
- The CLI and GUI client packages will have a `conflicts` tag, at least for now.
- Eventually, Clients and Gateways will be allowed to run on the same host, so avoid conflicts there
- If the service account token exists, we are in service mode and won't accept connections from a GUI client, even if the token is invalid.
- The GUI stores tokens from interactive auth in a secure keyring provided by the desktop environment. (e.g. gnome-keyring) I assume the tunnel running as root with no desktop env, doesn't have access to that kind of security, since it starts without a password.
- The GUI and privileged tunnel will live in separate binaries in case we need to set capabilities on the tunnel binary. This will also reduce the amount of code mapped into executable address space of the privileged tunnel process.

## Binaries

I gave them new names to clarify.

1. `firezone-client-tunnel` - A daemon that runs the tunnel, listens for commands from the GUI over IPC, and has elevated privilege. This is a systemd service on Linux and a Windows service on Windows.
2. `firezone` - The same daemon binary, but running as a standalone CLI / systemd service instead of listening for GUI commands
3. `firezone-gui` - An unprivileged GUI program that keeps an icon in the system tray / notification center and is similar to `firezonectl`

## Servers

`firezone` (or `firezone-client-tunnel` with special CLI flags) runs all the time as a systemd service. It does not listen for GUI commands and only uses service tokens.

## Docker

`firezone-client-tunnel` runs all the time and does not take interactive commands.

## Desktop

`firezone-client-tunnel` runs all the time as a systemd service. It tries to find a service account token and use that. If there is no service account token, it waits for a GUI to connect over IPC.

`firezone-gui` performs auth using deep links and sends the token to `firezone-client-tunnel`.

## Security concerns

Given a group `firezone` and users `firezone-user` (Belonging to a Firezone Actor) and `other-user` (Belonging to another person):

- What if an attacker has root? (That is outside scope, we can't protect from that.)
- What if malware is running as `firezone-user`? (Then it can command the tunnel to sign out, and possibly steal tokens depending on how the desktop keyring works.)
- What if `firezone-user` signs in to Firezone, then `other-user` signs in to Linux and uses Resources under `firezone-user`'s name? (We can't help that, the tunnel is system-wide. Per-app permissions may come after GA.)
- How does the UI know that it's connected to the real tunnel? (The tunnel claims a privileged D-Bus address or listens on a socket that no other service would be allowed to listen on)
- What if `other-user` tries to sign out the tunnel by sending IPC commands? (The tunnel should be able to check the GID of incoming IPC connections and refuse the command, same as Docker does)
- How does the tunnel know that it's getting IPC commands from a real UI binary? (It doesn't. Permissions belong to users, not to binaries.)
- What if an "evil maid" reads the hard drive of a system while it's in a hotel room? (Service account tokens would be compromised, but hopefully interactive GUI logins would be secured by the desktop's keyring)
