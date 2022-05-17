---
layout: default
title: Reverse Tunnel
nav_order: 7
parent: User Guides
description: >
  Relay traffic from peers through the Firezone server with
  WireGuard. A typical use case for this configuration is to
  establish a reverse tunnel between two or more peers that
  may be behind NAT.
---
---

This guide will walk through using Firezone as a relay to connect
two peers. A typical use case for this configuration is to enable an
administrator to access a server, container, or machine that is normally
behind a NAT or firewall.

## General Case - Node to Node

This example demonstrates a simple scenario where a tunnel is established
between Peer A and Peer B.

![node-to-node](https://user-images.githubusercontent.com/52545545/155856835-2ad1f686-d894-43d1-8862-e3a8fcccee5c.png){:width="600"}

In the settings for each device, ensure the following parameters are set to the
values listed below. You can set device settings when creating the WireGuard config
(see [Add Devices]({%link docs/user-guides/add-devices.md%})).
If you need to update settings on an existing device, you can do so by generating
a new device config.

Note `PersistentKeepalive` can also be set in on the
`/settings/defaults` page for all devices.

Peer A

- `AllowedIPs = 10.3.2.2/32`: This is the IP or range of IPs of Peer B
- `PersistentKeepalive = 25` If the peer is behind a NAT, this ensures the peer
is able to keep the tunnel alive and continue to receive packets from the
WireGuard interface. Usually a value of `25` is sufficient, but you may need to
decrease this value depending on your environment.

Peer B

- `AllowedIPs = 10.3.2.3/32`: This is the IP or range of IPs of Peer A
- `PersistentKeepalive = 25`

## Admin Case - One to Many Nodes

This example demonstrates a scenario where Peer A can communicate
bi-directionally with Peers B through D. This configuration could represent an
administrator or engineer accessing multiple resources
(servers, containers, or machines) in different networks.

![node-to-multiple-nodes](https://user-images.githubusercontent.com/52545545/155856838-03e968d9-bc1e-46ce-a32f-9f53f3566526.png){:width="600"}

In the settings for each device, ensure the following parameters are set to the
values listed below. You can set device settings when creating the WireGuard config
(see [Add Devices]({%link docs/user-guides/add-devices.md%})).
If you need to update settings on an existing device, you can do so by generating
a new device config.

Peer A (Administrator Node)

- `AllowedIPs = 10.3.2.3/32, 10.3.2.4/32, 10.3.2.5/32`: This is the IP of peers
B through D. Optionally you could set a range of IPs as long as it includes the
IPs of Peers B through D.
- `PersistentKeepalive = 25` If the peer is behind a NAT, this ensures the peer
is able to keep the tunnel alive and continue to receive packets from the
WireGuard interface. Usually a value of `25` is sufficient, but you may need to
decrease this value depending on your environment.

Peer B

- `AllowedIPs = 10.3.2.2/32`: This is the IP or range of IPs of Peer A
- `PersistentKeepalive = 25`

Peer C

- `AllowedIPs = 10.3.2.2/32`: This is the IP or range of IPs of Peer A
- `PersistentKeepalive = 25`

Peer D

- `AllowedIPs = 10.3.2.2/32`: This is the IP or range of IPs of Peer A
- `PersistentKeepalive = 25`

\
[Related: Whitelisting via VPN]({%link docs/user-guides/whitelist-vpn.md%}){:.btn.btn-purple}
