---
title: Egress Rules
sidebar_position: 3
---

Firezone supports egress filtering controls to explicitly DROP or ACCEPT packets
via the kernel's netfilter system. By default, all traffic is allowed.

The Allowlist and Denylist support both IPv4 and IPv6 CIDRs and IP addresses.
When adding a rule, you may optionally scope it to a user which applies the
rule to all their devices.

![firewall_rules](https://user-images.githubusercontent.com/69542737/177389239-6258b592-56ff-4825-b4be-df09f919c327.png)
