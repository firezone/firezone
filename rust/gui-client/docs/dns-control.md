# Conclusion

- Keep the `/etc/resolv.conf` method for containers and minimal Debian installs
- Keep `systemd-resolved` for Ubuntu desktops, likely a popular target
- If anyone asks nicely, `nmcli` is easy, and if NetworkManager is too big a package, there may be other options.

# Methods

1. Rewrite `/etc/resolv.conf` in-place. Works well on disposable 'cattle' systems like Alpine containers. Has many edge cases.
2. Cooperate with `systemd-resolved`. Works well on Ubuntu servers and desktops.
3. Cooperate with `NetworkManager` using `nmcli`. Works well on desktop Debian.
4. Run as a plugin for `NetworkManager`. Not implemented yet, seems complicated, but probably robust and user-friendly for NM users.
5. Cooperate with `netplan`. Not yet researched.
6. Cooperate with [`resolvconf`](https://wiki.debian.org/NetworkConfiguration#The_resolvconf_program) by editing `/etc/network/interfaces.d/`. Not yet researched.
7. Cooperate with `ifupdown`, not yet researched, might not control DNS.

# Distros

## Containers

Always edit `/etc/resolv.conf`.

- Alpine 3.19, inside container - [Official policy](https://wiki.alpinelinux.org/wiki/Configure_Networking#Configuring_DNS) is to rewrite `/etc/resolv.conf`. `networkmanager`, `resolvconf`, and `ifupdown` available in package manager but untested. Systemd not supported.
- Debian 12, inside container - Nothing installed, just edit `/etc/resolv.conf`.
- Ubuntu 22.02, inside container - Nothing installed, just edit `/etc/resolv.conf`.

## Debian

Allow user to opt in to editing `/etc/resolv.conf`, or ask them to install `systemd-resolved`.

- Debian 12.5, CLI only - Editing `/etc/resolv.conf` [allowed if nothing is installed to coordinate it](https://wiki.debian.org/NetworkConfiguration#The_resolv.conf_configuration_file) `ifupdown` installed. Many other options available from `apt`.
- Debian 12.5 with KDE - Cooperating with `nmcli` works well.

## Ubuntu

Always use `systemd-resolved`.

- Ubuntu Server 20.04, CLI only - `systemd-resolved` installed. Netplan also available.
- Ubuntu Server 22.04, CLI only - `systemd-resolved` installed. Netplan also available.

## Other

Not supported at this time.

- Fedora Cloud 39 - Couldn't figure out how to log in yet
