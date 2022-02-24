---
layout: default
title: Troubleshoot
nav_order: 5
parent: Administer
description: >
 Start with these steps to troubleshoot your Firezone
 installation. A good first bet is to check the Firezone logs.
---
---

For any problems that arise, a good first bet is to check the Firezone logs.

To view Firezone logs, run `sudo firezone-ctl tail`.

## Debugging Connectivity Issues

Most connectivity issues with Firezone are caused by other `iptables` or
`nftables` rules which interfere with Firezone's operation. If you have rules
active, you'll need to ensure these don't conflict with the Firezone rules.

### Internet Connectivity Drops when Tunnel is Active

If your Internet connectivity drop whenever you activate your WireGuard
connection, you should make sure that the `FORWARD` chain allows packets
from your WireGuard clients to the destinations you want to allow through
Firezone.

If you're using `ufw`, this can be done by making sure the default routing
policy is `allow`:

```text
sudo ufw default allow routed
```

A typical `ufw` Firezone status might thus look like this:

```text
ubuntu@fz:~$ sudo ufw status verbose
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), allow (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere
80/tcp                     ALLOW IN    Anywhere
443/tcp                    ALLOW IN    Anywhere
51820/udp                  ALLOW IN    Anywhere
22/tcp (v6)                ALLOW IN    Anywhere (v6)
80/tcp (v6)                ALLOW IN    Anywhere (v6)
443/tcp (v6)               ALLOW IN    Anywhere (v6)
51820/udp (v6)             ALLOW IN    Anywhere (v6)
```

## Need additional help?

If you're looking for help installing, configuring, or using Firezone, we're
happy to help.

* [Discussion Forums](https://discourse.firez.one/): ask questions, report bugs,
and suggest features
* [Public Slack Group](https://join.slack.com/t/firezone-users/shared_invite/zt-111043zus-j1lP_jP5ohv52FhAayzT6w):
join discussions, meet other users, and meet the contributors
* [Email Us](mailto:team@firez.one): we're always happy to chat
