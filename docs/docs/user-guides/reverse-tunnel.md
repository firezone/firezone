---
layout: default
title: Node to Node Connections (Reverse Tunnel)
nav_order: 7
parent: User Guides
description: >
  Establish node to node connections through the Firezone
  server.A typical use case for this configuration is to enable 
  an administrator to access a server, container, or machine
  that is normally behind a NAT or firewall.
---
---

This guide will walk through using Firezone as a relay to connect
two hosts. A typical use case for this configuration is to enable an
administrator to access a server, container, or machine that is normally
behind a NAT or firewall.

## General Case - Node to Node

This example demonstrates a simple scenario where a connection is established
between Peer A and Peer B.

![node-to-node](https://user-images.githubusercontent.com/52545545/155856835-2ad1f686-d894-43d1-8862-e3a8fcccee5c.png)

In the settings for each device, ensure the following parameters are set to the
values listed below. You can edit device settings by clicking the `Edit` button
on the `settings/[device_id]/edit` page.
See [link to edit device article] for additional details on editing device settings.

Note `PersistentKeepalive` can also be set in on the
`/settings/defaults` page for all devices.

Peer A

- `AllowedIPs = 10.3.2.2/32`: This is the IP or range of IPs of Peer B
- `PersistentKeepalive = 25` If the peer is behind a NAT, this ensures the peer
is able to keep the connection alive and continue to receive packets from the
WireGuard interface. Usually a value of `25` is sufficient, but you may need to
decrease this value depending on your environment.

Peer B

- `AllowedIPs = 10.3.2.3/32`: This is the IP or range of IPs of Peer A
- `PersistentKeepalive = 25`

## Admin Case - 1 to Many Nodes

This example demonstrates a scenario where Peer A can communicate
bi-directionally with Peers B through D. A real scenario involving this setup
could be an administrator or engineer accessing multiple resources
(servers, containers, or machines) in different networks.

![node-to-multiple-nodes](https://user-images.githubusercontent.com/52545545/155856838-03e968d9-bc1e-46ce-a32f-9f53f3566526.png)

In the WireGuard configuration files, ensure the following parameters are set
to the values listed below. Note `PersistentKeepalive` can be set on the
`/settings/defaults` page, but the `AllowedIPs` of a particular device will
require you to edit the WireGuard config file directly.

Peer A (Administrator Node)

- `AllowedIPs = 10.3.2.3/32, 10.3.2.4/32, 10.3.2.5/32`: This is the IP of peers
B through D. Optionally you could set a range of IPs as long as it includes the
IPs of Peers B through D.
- `PersistentKeepalive = 25` If the peer is behind a NAT, this ensures the peer
is able to keep the connection alive and continue to receive packets from the
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
