---
layout: default
title: Security Considerations
nav_order: 6
parent: Administer
description: >
  Firezone services uses the following list of ports.
---
---

Shown below is a table of ports used by Firezone services.

<!-- markdownlint-disable MD013 -->

| Service | Default port | Listen address | Description |
| Nginx | `80` `443` | `all` | Public HTTP(S) port for administering Firezone and facilitating authentication. |
| WireGuard | `51820` | `all` | Public WireGuard port used for VPN connections. |
| Postgresql | `15432` | `127.0.0.1` | Local-only port used for bundled Postgresql server |
| Phoenix | `13000` | `127.0.0.1` | Local-only port used by upstream elixir app server. |

<!-- markdownlint-enable MD013 -->

## Reporting Security Issues

To report any security-related bugs, see [our security reporting policy
](https://github.com/firezone/firezone/blob/master/SECURITY.md).
