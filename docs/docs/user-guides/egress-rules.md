---
title: Egress Rules
sidebar_position: 3
---

Firezone supports egress filtering controls to explicitly DROP or ACCEPT packets
via the kernel's netfilter system. By default, all traffic is allowed.

The Allowlist and Denylist support both IPv4 and IPv6 CIDRs and IP addresses.
Rules apply to all devices by default. User-scoped rules apply only to devices
belonging to that particular user.

![firewall_rules](https://user-images.githubusercontent.com/69542737/177398544-89df7f6b-9296-4c11-ba6a-e95c72f853b7.png)
