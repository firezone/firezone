# firezone-client-tunnel

A privileged tunnel process that can communicate with the Linux GUI Client (and eventually Windows)

## Files

- `/etc/dev.firezone.client/token` - The service account token, provided by the human administrator. Must be owned by root and have 600 permissions (r/w by owner, nobody else can read) If present, the tunnel will ignore any GUI Client and run as a headless Client. If absent, the tunnel will wait for commands from a GUI Client
- `/usr/bin/firezone-tunnel` - The tunnel binary. This must run as root so it can modify the system's DNS settings. If DNS is not needed, it only needs CAP_NET_ADMIN.
- `/usr/lib/systemd/system/firezone-tunnel.service` - A systemd service unit, installed by the deb package.
- `/var/lib/dev.firezone.client/config/firezone-id` - The device ID, unique across an organization. The tunnel will generate this if it's not present.
