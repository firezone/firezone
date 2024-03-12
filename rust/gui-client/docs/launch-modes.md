# Linux launch modes

(Without thinking of systemd yet)

1. No GUI allowed
2. GUI spawns its own tunnel subprocess
3. GUI and tunnel start up separately, GUI connects to the tunnel

# How many binaries?

2 downloads, each containing 1 binary on disk.

1. `firezone-linux-client` only supports Mode 1.
2. `firezone-gui-client` supports all modes.

# Flags

(These might actually be subcommands, but I kept the leading hyphens for now.)

`firezone-linux-client` only accepts `--headless`, for the purpose of flag compatibility with `firezone-gui-client`.
It bails out if it sees any other flag, since all other flags relate to GUI behavior.

The flags must be compatible between both binaries, since they may be installed as `firezone-client`.

1. `--headless` means Mode 1. `firezone-gui-client` pretends to be `firezone-linux-client`, refusing any GUI connections.
2. `--standalone-gui` means Mode 2. `firezone-gui-client` becomes a GUI process, then calls `sudo` to launch its own tunnel subprocess. Closing the GUI closes the tunnel.
3. `--gui-only` means Mode 3. `firezone-gui-client` becomes a GUI process, and tries to connect to a tunnel process elsewhere in the system.
4. `--tunnel-only` means Mode 3. `firezone-gui-client` becomes a tunnel process, raises the tunnel if it has a token, and waits for a connection from a GUI process elsewhere in the system.
5. `--auto-gui` means auto-detect Mode 2 or Mode 3. If the systemd service for the tunnel appears to be installed, or if a tunnel is running, `firezone-gui-client` enters Mode 3. (Connect to existing tunnel) Otherwise, it enters Mode 2. (Spawn a tunnel)
6. No flags means `firezone-linux-client` enters Mode 1, its only possible mode, and `firezone-gui-client` acts as if it got `--auto-gui`. This means `--auto-gui` is redundant, but it could be useful if the default changes later or something.

For Mode 2, `firezone-gui-client` internally launches itself as a subprocess with `--tunnel-of-standalone-gui` which is meant for machine use. This is similar to `--tunnel-only` but it waits for the GUI to connect, refuses connections from any other process, and tries to automatically close if it detects that the GUI stopped suddenly without asking the tunnel to stop gracefully first.

If `firezone-gui-client` observes its exe name is `firezone-linux-client`, it pretends to be `firezone-linux-client` and rejects any GUI-related flags, in the style of Busybox multi-call binaries.

# What about systemd and desktop entries?

Desktop entries (i.e. desktop shortcuts and "Start Menu" entries) will call `firezone-gui-client --auto-gui`. Desktop entries do not launch `firezone-linux-client`.

Systemd launches `firezone-linux-client --headless` or `firezone-gui-client --tunnel-only`.

# CLI / GUI conflict

What if both packages are installed on the system?

We could put `Conflicts` directives in the packages and just say we don't support it. That might be best for now.

Then the GUI client can have a symlink `firezone-linux-client` that acts the same as the CLI-only client would, so having the GUI installed is equivalent to also having the CLI installed and having the conflict resolved already.

Both packages would enable their own systemd service by default. We can name this `firezone-client.service`, since there should never be two Clients, this makes sure there can't be two Client service units.
