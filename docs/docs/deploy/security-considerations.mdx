---
title: Security Considerations
sidebar_position: 6
---

**Disclaimer**: Firezone is still beta software. The codebase has not yet
received a formal security audit. For highly sensitive and mission-critical
production deployments, we recommend limiting access to the web interface, as
detailed [below](#production-deployments).

## List of services and ports

Shown below is a table of ports used by Firezone services.

| Service | Default port | Listen address | Description |
| ------ | --------- | ------- | --------- |
| Nginx | `443` | `all` | Public HTTPS port for administering Firezone and facilitating authentication. |
| Nginx | `80` | `all` | Public HTTP port used for ACME. Disabled when ACME is disabled. |
| WireGuard | `51820` | `all` | Public WireGuard port used for VPN sessions. |
| Postgresql | `15432` | `127.0.0.1` | Local-only port used for bundled Postgresql server. |
| Phoenix | `13000` | `127.0.0.1` | Local-only port used by upstream elixir app server. |

## Production deployments

For production and public-facing deployments where a single administrator
will be responsible for generating and distributing device configurations to
end users, we advise you to consider limiting access to Firezone's publicly
exposed web UI (by default ports `443/tcp` and `80/tcp`)
and instead use the WireGuard tunnel itself to manage Firezone.

For example, assuming an administrator has generated a device configuration and
established a tunnel with local WireGuard address `10.3.2.2`, the following `ufw`
configuration would allow the administrator the ability to reach the Firezone web
UI on the default `10.3.2.1` tunnel address for the server's `wg-firezone` interface:

```text
root@demo:~# ufw status verbose
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), allow (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere
51820/udp                  ALLOW IN    Anywhere
Anywhere                   ALLOW IN    10.3.2.2
22/tcp (v6)                ALLOW IN    Anywhere (v6)
51820/udp (v6)             ALLOW IN    Anywhere (v6)
```

This would leave only `22/tcp` exposed for SSH access to manage the server (optional),
and `51820/udp` exposed in order to establish WireGuard tunnels.

:::note
This type of configuration has not been fully tested with SSO
authentication and may it to break or behave unexpectedly.
:::

## Reporting Security Issues

To report any security-related bugs, see [our security bug reporting policy
](https://github.com/firezone/firezone/blob/master/SECURITY.md).
