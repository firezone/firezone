(TODO: Change "client-tunnel" to "headless-client")

# Process split

This is meant for Linux, but it will be similar on Windows.
It is probably similar to the existing Mac / iOS / Android process split.

## Split boundary

### Tunnel process

Anything that requires CAP_NET_ADMIN or root privilege must happen inside the privileged tunnel process:

- DNS control
- Creating the tunnel interface
- Adding / removing IP routes

Some things don't need privileges, but it's more convenient to run them on the tunnel side to keep the IPC interface narrow:

- DNS stub resolver
- `get_system_default_resolvers`
- Listening for DNS / network changes

Anything that can work with normal user privileges should run in the non-privileged GUI process

### GUI process

- All GUI code, since GUIs in Linux generally don't work when running as root
- Storing tokens in the secure keyring, since the desktop environment should be able to encrypt these with the user's password, which is more secure than keeping them in a file or securing them by TPM alone.

## Decisions

- The CLI Client will not be split for now, it keep the same CLI interface but may be refactored. `firezone-client-tunnel` will be an evolution of the CLI client, and they will share most code.
- The CLI and GUI client packages will have a `conflicts` tag, at least for now.
- Eventually, Clients and Gateways will be allowed to run on the same host, so avoid conflicts there
- Binary names may change in the future.
- The GUI stores tokens from interactive auth in a secure keyring provided by the desktop environment. (e.g. gnome-keyring) I assume the tunnel running as root with no desktop env, doesn't have access to that kind of security, since it starts without a password.
- The GUI and privileged tunnel will live in separate binaries in case we need to set capabilities on the tunnel binary. This will also reduce the amount of code mapped into executable address space of the privileged tunnel process.

## Files

1. `$HOME/.config/autostart` - A link that auto-starts the GUI when the user logs in, created by `firezone-gui --register-auto-start`
1. `/etc/dev.firezone.client/token` - A service account token, owned by root, with permissions 600. (rw- --- ---) Written by a human admin or an MDM on their behalf.
1. `/usr/bin/firezone-client-tunnel` - A daemon that runs the tunnel, listens for commands from the GUI over IPC, and has elevated privilege. This is a systemd service on Linux and a Windows service on Windows. This will evolve from the current Linux CLI Client.
1. `/usr/bin/firezone-gui` - An unprivileged GUI program that keeps an icon in the system tray / notification center and is similar to `firezonectl`
1. `/usr/lib/systemd/system/firezone-client.service` - The systemd service unit to auto-start the privileged client tunnel. Installed from the deb.

The binaries are separated because:

- If `firezone-client-tunnel` does not run as root, it may need `CAP_NET_ADMIN` set on the binary itself using `setcap`. We must not set that on the GUI binary.
- Keeping the GUI code out of `firezone-client-tunnel` reduces the amount of code mapped into executable address space in the privileged tunnel process. It may not make a big difference, but all other things being equal, a smaller amount of code should be easier to secure.

Other than those reasons, the GUI and privileged tunnel could spawn from the same binary.

## Servers

`/usr/lib/systemd/system/firezone-client.service` starts `firezone-client-tunnel --no-ipc`. Only service account tokens can be used. The only interaction is through SIGHUP or restarting the tunnel.

## Docker

Same as a server, but Docker runs the process directly instead of using systemd.

## Interactive CLI

Same as a server, but a human runs the process instead of systemd.

## Desktop

Same as a server, but without the `--no-ipc` flag. `firezone-gui` attempts to connect to the tunnel process. If there is a service account token, the IPC connection fails, and `firezone-gui` shows an error. If the IPC connection succeeds, `firezone-gui` can perform interactive auth or reload the token from the secure keyring to share it with `firezone-client-tunnel`.

`firezone-gui --register-auto-start` puts a link in `$HOME/.config/autostart` to auto-start the program when the user logs in to their desktop.

## Tokens

`firezone-client-tunnel` tries to get a token in this order:

- (The token must not be sent through CLI args)
- If the `FIREZONE_TOKEN` env var is set, we copy that to memory and call `std::env::remove_var` so it doesn't stay in the environment longer than it needs to. (Per <https://security.stackexchange.com/questions/197784/is-it-unsafe-to-use-environmental-variables-for-secret-data>)
- If there's a (service account) token in `/etc/dev.firezone.client/token`, and it's only readable by root, it uses that. (If anyone else can read it, it throws an error asking the user to fix the permissions and regenerate the token)
- If the `--no-ipc` flag is passed, it fails here.
- It starts an IPC server and waits for the GUI to send it a token from interactive auth.

`firezone-client-tunnel` never writes a token. `firezone-gui` uses a secure keyring to store interactive tokens. Interactive tokens should be secured by the user's password, so they're protected against "evil maid" attacks. Service account tokens must be written by a human administrator or MDM.

If `firezone-client-tunnel` finds a token in its env or in the FS, it does not listen for IPC connections, even if the token turns out to be invalid.

## Security concerns

Given a group `firezone` and users `firezone-user` (Belonging to a Firezone Actor) and `other-user` (Belonging to another person):

- What if an attacker has root? (That is outside scope, we can't protect from that.)
- What if malware is running as `firezone-user`? (Then it can command the tunnel to sign out, and possibly steal tokens depending on how the desktop keyring works.)
- What if `firezone-user` signs in to Firezone, then `other-user` signs in to Linux and uses Resources under `firezone-user`'s name? (We can't help that, the tunnel is system-wide. Per-app permissions may come after GA.)
- How does the UI know that it's connected to the real tunnel? (The tunnel claims a privileged D-Bus address or listens on a socket that no other service would be allowed to listen on)
- What if `other-user` tries to sign out the tunnel by sending IPC commands? (The tunnel should be able to check the GID of incoming IPC connections and refuse the command, same as Docker does)
- How does the tunnel know that it's getting IPC commands from a real UI binary? (It doesn't. Permissions belong to users, not to binaries.)
- What if an "evil maid" reads the hard drive of a system while it's in a hotel room? (Service account tokens would be compromised, but hopefully interactive GUI logins would be secured by the desktop's keyring)
